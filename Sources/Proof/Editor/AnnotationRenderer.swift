import AppKit
import CoreImage

/// Where things go in the output: the cropped image, inside any background padding.
struct RenderLayout {
    /// Whole output in points.
    let outputSize: CGSize
    /// The visible part of the image, in output points.
    let imageFrame: CGRect
    /// The crop, in image points.
    let visible: CGRect

    /// Image points → output points.
    func toOutput(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - visible.minX + imageFrame.minX, y: p.y - visible.minY + imageFrame.minY)
    }

    /// Output points → image points.
    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - imageFrame.minX + visible.minX, y: p.y - imageFrame.minY + visible.minY)
    }
}

/// Draws a document: background, image, effects and annotations. The canvas and every export
/// go through `draw`, so what is on screen is what gets saved. All drawing is in a context whose
/// origin is top-left with y going down, in output points.
final class AnnotationRenderer {
    let image: CGImage
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var effectCache: [String: CGImage] = [:]

    init(image: CGImage) {
        self.image = image
    }

    static func layout(_ document: AnnotationDocument) -> RenderLayout {
        let visible = document.visibleRect
        let bg = document.background
        guard bg.enabled else {
            return RenderLayout(outputSize: visible.size, imageFrame: CGRect(origin: .zero, size: visible.size), visible: visible)
        }
        var size = CGSize(width: visible.width + bg.padding * 2, height: visible.height + bg.padding * 2)
        if let ratio = bg.aspect.ratio {
            if size.width / size.height < ratio { size.width = size.height * ratio } else { size.height = size.width / ratio }
        }
        let frame = CGRect(x: ((size.width - visible.width) / 2).rounded(), y: ((size.height - visible.height) / 2).rounded(),
                           width: visible.width, height: visible.height)
        return RenderLayout(outputSize: CGSize(width: size.width.rounded(), height: size.height.rounded()), imageFrame: frame, visible: visible)
    }

    /// The finished image at the document's pixel scale.
    func render(_ document: AnnotationDocument) -> CGImage? {
        let layout = Self.layout(document)
        let scale = document.scale
        let width = Int((layout.outputSize.width * scale).rounded()), height = Int((layout.outputSize.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(document, in: context)
        return context.makeImage()
    }

    /// Draws everything except annotations listed in `hiding` (the one being edited as text).
    func draw(_ document: AnnotationDocument, in context: CGContext, hiding: Set<UUID> = [], showFullImage: Bool = false) {
        var document = document
        if showFullImage {
            document.crop = nil
            document.background.enabled = false
        }
        let layout = Self.layout(document)
        let bg = document.background

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }

        if bg.enabled {
            drawBackground(bg, size: layout.outputSize, in: context)
        }

        // The screenshot, rounded and shadowed when on a background.
        let imageClip: CGPath = bg.enabled
            ? CGPath(roundedRect: layout.imageFrame, cornerWidth: min(bg.cornerRadius, layout.imageFrame.width / 2),
                     cornerHeight: min(bg.cornerRadius, layout.imageFrame.height / 2), transform: nil)
            : CGPath(rect: layout.imageFrame, transform: nil)
        if bg.enabled && bg.shadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            context.addPath(imageClip)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(imageClip)
        context.clip()
        // Image space from here on.
        context.translateBy(x: layout.imageFrame.minX - layout.visible.minX, y: layout.imageFrame.minY - layout.visible.minY)
        Self.drawImage(image, in: CGRect(origin: .zero, size: document.imageSize), context: context)

        // Effects read the original pixels, so they go first, still clipped to the image.
        for annotation in document.annotations where (annotation.tool == .pixelate || annotation.tool == .blur) && !hiding.contains(annotation.id) {
            drawEffect(annotation, document: document, in: context)
        }
        let spotlights = document.annotations.filter { $0.tool == .spotlight && !hiding.contains($0.id) }
        if !spotlights.isEmpty {
            let path = CGMutablePath()
            path.addRect(layout.visible.insetBy(dx: -1, dy: -1))
            for s in spotlights {
                let r = s.rect
                path.addRoundedRect(in: r, cornerWidth: min(8, r.width / 2), cornerHeight: min(8, r.height / 2))
            }
            context.addPath(path)
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.fillPath(using: .evenOdd)
        }
        context.restoreGState()

        // Annotations may spill onto the background, so they're not clipped.
        context.saveGState()
        context.translateBy(x: layout.imageFrame.minX - layout.visible.minX, y: layout.imageFrame.minY - layout.visible.minY)
        if !bg.enabled {
            context.addRect(layout.visible)
            context.clip()
        }
        for annotation in document.annotations where !hiding.contains(annotation.id) {
            drawShape(annotation, in: context)
        }
        context.restoreGState()
    }

    // MARK: Pieces

    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private func drawBackground(_ bg: BackgroundSettings, size: CGSize, in context: CGContext) {
        let colors = BackgroundSettings.presets[min(max(bg.preset, 0), BackgroundSettings.presets.count - 1)].1
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let gradient = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func drawEffect(_ annotation: Annotation, document: AnnotationDocument, in context: CGContext) {
        let rect = annotation.rect.intersection(CGRect(origin: .zero, size: document.imageSize))
        guard rect.width >= 1, rect.height >= 1 else { return }
        let key = "\(annotation.tool.rawValue) \(rect.integral)"
        let effect: CGImage
        if let cached = effectCache[key] {
            effect = cached
        } else {
            guard let made = makeEffect(annotation.tool, rect: rect, document: document) else { return }
            if effectCache.count > 64 { effectCache.removeAll() }
            effectCache[key] = made
            effect = made
        }
        Self.drawImage(effect, in: rect, context: context)
    }

    private func makeEffect(_ tool: EditorTool, rect: CGRect, document: AnnotationDocument) -> CGImage? {
        let scale = CGFloat(image.width) / document.imageSize.width
        // Core Image's origin is bottom-left.
        let pixelRect = CGRect(x: rect.minX * scale, y: CGFloat(image.height) - rect.maxY * scale,
                               width: rect.width * scale, height: rect.height * scale).integral
        let input = CIImage(cgImage: image)
        let output: CIImage?
        switch tool {
        case .pixelate:
            let block = max(8 * scale, min(pixelRect.width, pixelRect.height) / 10)
            let filter = CIFilter(name: "CIPixellate")
            filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            filter?.setValue(block, forKey: kCIInputScaleKey)
            filter?.setValue(CIVector(x: pixelRect.minX, y: pixelRect.minY), forKey: kCIInputCenterKey)
            output = filter?.outputImage
        default:
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            filter?.setValue(10 * scale, forKey: kCIInputRadiusKey)
            output = filter?.outputImage
        }
        guard let output else { return nil }
        return ciContext.createCGImage(output.cropped(to: pixelRect), from: pixelRect)
    }

    private func applyShadow(_ style: AnnotationStyle, _ context: CGContext) {
        guard style.shadow else { return }
        context.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    }

    /// A filled circle with the annotation's number, centred on its start point.
    private func drawBadge(_ a: Annotation, in context: CGContext) {
        context.saveGState()
        applyShadow(a.style, context)
        context.fillEllipse(in: a.badgeRect)
        context.restoreGState()
        let label = NSAttributedString(string: "\(a.number)", attributes: [
            .font: NSFont.systemFont(ofSize: a.counterDiameter * 0.55, weight: .bold),
            .foregroundColor: a.style.color.isLight ? NSColor.black : NSColor.white,
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2))
    }

    private func drawShape(_ a: Annotation, in context: CGContext) {
        let color = a.style.color.cgColor
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(a.style.lineWidth)
        context.setStrokeColor(color)
        context.setFillColor(color)

        switch a.tool {
        case .rectangle:
            applyShadow(a.style, context)
            let r = a.rect
            context.addPath(CGPath(roundedRect: r, cornerWidth: min(4, r.width / 2), cornerHeight: min(4, r.height / 2), transform: nil))
            context.strokePath()
        case .filledRectangle:
            applyShadow(a.style, context)
            let r = a.rect
            context.addPath(CGPath(roundedRect: r, cornerWidth: min(4, r.width / 2), cornerHeight: min(4, r.height / 2), transform: nil))
            context.fillPath()
        case .ellipse:
            applyShadow(a.style, context)
            context.strokeEllipse(in: a.rect)
        case .line:
            applyShadow(a.style, context)
            context.move(to: a.start)
            context.addLine(to: a.end)
            context.strokePath()
        case .arrow:
            applyShadow(a.style, context)
            context.addPath(Self.arrowPath(from: a.start, to: a.end, width: a.style.lineWidth, style: a.style.arrowStyle))
            context.fillPath()
        case .pencil:
            applyShadow(a.style, context)
            context.addPath(Self.smoothPath(a.points))
            context.strokePath()
        case .highlighter:
            context.setBlendMode(.multiply)
            context.setStrokeColor(a.style.color.nsColor.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(max(14, a.style.lineWidth * 4))
            context.setLineCap(.square)
            context.addPath(Self.smoothPath(a.points))
            context.strokePath()
        case .counter:
            drawBadge(a, in: context)
        case .numberedArrow:
            context.saveGState()
            applyShadow(a.style, context)
            context.addPath(Self.arrowPath(from: a.start, to: a.end, width: a.style.lineWidth, style: a.style.arrowStyle))
            context.fillPath()
            context.restoreGState()
            drawBadge(a, in: context)
        case .text:
            drawText(a, in: context)
        case .select, .crop, .pixelate, .blur, .spotlight:
            break
        }
    }

    private func drawText(_ a: Annotation, in context: CGContext) {
        guard !a.text.isEmpty else { return }
        let font = Self.font(for: a.style)
        let origin = a.start
        let size = Self.textSize(for: a)
        switch a.style.textStyle {
        case .plain:
            applyShadow(a.style, context)
            NSAttributedString(string: a.text, attributes: [.font: font, .foregroundColor: a.style.color.nsColor])
                .draw(at: CGPoint(x: origin.x + Self.textInset.width, y: origin.y + Self.textInset.height))
        case .filled:
            context.saveGState()
            applyShadow(a.style, context)
            let box = CGRect(origin: origin, size: size)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
            context.restoreGState()
            NSAttributedString(string: a.text, attributes: [.font: font, .foregroundColor: a.style.color.isLight ? NSColor.black : NSColor.white])
                .draw(at: CGPoint(x: origin.x + Self.textInset.width, y: origin.y + Self.textInset.height))
        case .outlined:
            let at = CGPoint(x: origin.x + Self.textInset.width, y: origin.y + Self.textInset.height)
            // Outline first (stroke only), then the fill on top, so the letters keep their shape.
            context.saveGState()
            applyShadow(a.style, context)
            NSAttributedString(string: a.text, attributes: [.font: font, .strokeColor: NSColor.white, .strokeWidth: 18]).draw(at: at)
            context.restoreGState()
            NSAttributedString(string: a.text, attributes: [.font: font, .foregroundColor: a.style.color.nsColor]).draw(at: at)
        }
    }

    // MARK: Geometry

    static let textInset = CGSize(width: 8, height: 4)

    static func font(for style: AnnotationStyle) -> NSFont {
        NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
    }

    static func textSize(for a: Annotation) -> CGSize {
        let text = a.text.isEmpty ? " " : a.text
        let size = NSAttributedString(string: text, attributes: [.font: font(for: a.style)])
            .boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        return CGSize(width: ceil(size.width) + textInset.width * 2, height: ceil(size.height) + textInset.height * 2)
    }

    static func arrowHeadLength(_ width: CGFloat) -> CGFloat { max(14, width * 4) }

    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat, style: ArrowStyle) -> CGPath {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        let path = CGMutablePath()
        guard length > 0.5 else { return path }
        let ux = dx / length, uy = dy / length          // along the arrow
        let px = -uy, py = ux                            // across it
        let head = min(arrowHeadLength(width), length * 0.6)
        let halfHead = head * 0.5
        let base = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
        func at(_ p: CGPoint, _ across: CGFloat) -> CGPoint { CGPoint(x: p.x + px * across, y: p.y + py * across) }

        switch style {
        case .classic:
            let half = width / 2
            // The shaft stops a little inside the head so the joint is hidden.
            let shaftEnd = CGPoint(x: base.x + ux * head * 0.3, y: base.y + uy * head * 0.3)
            path.move(to: at(start, half))
            path.addLine(to: at(shaftEnd, half))
            path.addLine(to: at(shaftEnd, -half))
            path.addLine(to: at(start, -half))
            path.closeSubpath()
            path.move(to: end)
            path.addLine(to: at(base, halfHead))
            path.addLine(to: at(base, -halfHead))
            path.closeSubpath()
        case .tapered:
            let tail = max(1, width * 0.25), neck = width * 0.9
            path.move(to: at(start, tail))
            path.addLine(to: at(base, neck))
            path.addLine(to: at(base, halfHead * 1.1))
            path.addLine(to: end)
            path.addLine(to: at(base, -halfHead * 1.1))
            path.addLine(to: at(base, -neck))
            path.addLine(to: at(start, -tail))
            path.closeSubpath()
        }
        return path
    }

    /// Quadratic curves through the midpoints of a freehand stroke, so it isn't jagged.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points.count == 2 ? points[1] : CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

extension RGBA {
    /// Light colours get dark text on top of them.
    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.7 }
}
