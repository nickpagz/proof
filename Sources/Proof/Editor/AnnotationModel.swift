import AppKit

/// Every drawing tool in the editor. `select` and `crop` edit; the rest create annotations.
enum EditorTool: String, CaseIterable, Identifiable, Codable {
    case select, rectangle, filledRectangle, ellipse, line, arrow, text, pixelate, blur, spotlight
    case counter, numberedArrow, pencil, highlighter, crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .spotlight: return "Spotlight"
        case .counter: return "Counter"
        case .numberedArrow: return "Numbered Arrow"
        case .pencil: return "Pencil"
        case .highlighter: return "Highlighter"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .pixelate: return "checkerboard.rectangle"
        case .blur: return "drop.halffull"
        case .spotlight: return "flashlight.on.fill"
        case .counter: return "1.circle"
        case .numberedArrow: return "arrow.up.right.circle"
        case .pencil: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .crop: return "crop"
        }
    }

    /// Single-key shortcuts, as in most editors.
    var key: Character? {
        switch self {
        case .select: return "v"
        case .rectangle: return "r"
        case .filledRectangle: return "f"
        case .ellipse: return "o"
        case .line: return "l"
        case .arrow: return "a"
        case .text: return "t"
        case .pixelate: return "x"
        case .blur: return "b"
        case .spotlight: return "s"
        case .counter: return "n"
        case .numberedArrow: return "m"
        case .pencil: return "p"
        case .highlighter: return "h"
        case .crop: return "c"
        }
    }

    /// Tools that take a colour and a stroke width from the style bar.
    var usesColor: Bool {
        switch self {
        case .select, .pixelate, .blur, .spotlight, .crop: return false
        default: return true
        }
    }

    var usesLineWidth: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .numberedArrow, .pencil, .highlighter: return true
        default: return false
        }
    }
}

enum ArrowStyle: String, CaseIterable, Codable, Identifiable {
    /// A straight line with a filled head.
    case classic
    /// One filled shape that widens toward the head.
    case tapered
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum TextStyle: String, CaseIterable, Codable, Identifiable {
    /// Coloured text.
    case plain
    /// White text on a rounded box of the colour.
    case filled
    /// Coloured text with a white outline, readable on any background.
    case outlined
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// sRGB colour that survives Codable.
struct RGBA: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }

    static let red = RGBA(r: 0.96, g: 0.26, b: 0.21)
    static let orange = RGBA(r: 1.0, g: 0.58, b: 0.0)
    static let yellow = RGBA(r: 1.0, g: 0.84, b: 0.04)
    static let green = RGBA(r: 0.2, g: 0.78, b: 0.35)
    static let blue = RGBA(r: 0.0, g: 0.48, b: 1.0)
    static let purple = RGBA(r: 0.69, g: 0.32, b: 0.87)
    static let black = RGBA(r: 0.1, g: 0.1, b: 0.1)
    static let white = RGBA(r: 1, g: 1, b: 1)

    static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

struct AnnotationStyle: Codable, Equatable {
    var color: RGBA = .red
    var lineWidth: CGFloat = 4
    var arrowStyle: ArrowStyle = .classic
    var textStyle: TextStyle = .filled
    var fontSize: CGFloat = 20
    /// A soft drop shadow under shapes, arrows and text, so they stand off the screenshot.
    var shadow = true
}

/// One object on the canvas. Geometry is in the base image's points, origin top-left, y down,
/// so cropping and backgrounds never move annotations relative to the screenshot.
struct Annotation: Codable, Equatable, Identifiable {
    var id = UUID()
    var tool: EditorTool
    var start: CGPoint
    var end: CGPoint
    /// Pencil and highlighter strokes.
    var points: [CGPoint] = []
    var text: String = ""
    var number: Int = 0
    var style: AnnotationStyle

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Area the annotation can be grabbed by and must be redrawn in.
    var bounds: CGRect {
        let pad = max(style.lineWidth, 2) * 2 + (style.shadow ? 6 : 0)
        switch tool {
        case .pencil, .highlighter:
            guard let first = points.first else { return .null }
            var r = CGRect(origin: first, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -pad, dy: -pad)
        case .counter:
            return badgeRect.insetBy(dx: -4, dy: -4)
        case .text:
            return CGRect(origin: start, size: AnnotationRenderer.textSize(for: self)).insetBy(dx: -4, dy: -4)
        case .arrow:
            let head = AnnotationRenderer.arrowHeadLength(style.lineWidth)
            return rect.insetBy(dx: -head, dy: -head)
        case .numberedArrow:
            let head = AnnotationRenderer.arrowHeadLength(style.lineWidth)
            return rect.insetBy(dx: -head, dy: -head).union(badgeRect.insetBy(dx: -4, dy: -4))
        default:
            return rect.insetBy(dx: -pad, dy: -pad)
        }
    }

    var counterDiameter: CGFloat { max(24, style.fontSize * 1.4) }

    /// The numbered circle of a counter, or at the tail of a numbered arrow.
    var badgeRect: CGRect {
        let d = counterDiameter
        return CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d)
    }

    /// Moves every point the annotation owns.
    mutating func offset(by delta: CGPoint) {
        start = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
        end = CGPoint(x: end.x + delta.x, y: end.y + delta.y)
        points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }

    /// True when `point` is on the visible part of the annotation, within `tolerance` points.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let t = max(tolerance, style.lineWidth / 2 + 3)
        switch tool {
        case .rectangle:
            let outer = rect.insetBy(dx: -t, dy: -t), inner = rect.insetBy(dx: t, dy: t)
            return outer.contains(point) && (inner.isEmpty || !inner.contains(point))
        case .ellipse:
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (point.x - r.midX) / (r.width / 2), ny = (point.y - r.midY) / (r.height / 2)
            let d = sqrt(nx * nx + ny * ny)
            return abs(d - 1) * min(r.width, r.height) / 2 < t
        case .line, .arrow:
            return distance(from: point, toSegment: start, end) < t
        case .numberedArrow:
            return distance(from: point, toSegment: start, end) < t || hypot(point.x - start.x, point.y - start.y) < counterDiameter / 2 + 2
        case .pencil, .highlighter:
            return zip(points, points.dropFirst()).contains { distance(from: point, toSegment: $0, $1) < t }
                || (points.count == 1 && hypot(points[0].x - point.x, points[0].y - point.y) < t)
        case .counter:
            return hypot(point.x - start.x, point.y - start.y) < counterDiameter / 2 + 2
        default:
            return bounds.contains(point)
        }
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// The Background tool: the screenshot on a padded gradient, rounded and shadowed.
struct BackgroundSettings: Codable, Equatable {
    var enabled = false
    var preset: Int = 0
    var padding: CGFloat = 48
    var cornerRadius: CGFloat = 10
    var shadow = true
    var aspect: BackgroundAspect = .auto

    static let presets: [(String, [RGBA])] = [
        ("Ocean", [RGBA(r: 0.23, g: 0.51, b: 0.96), RGBA(r: 0.12, g: 0.23, b: 0.54)]),
        ("Sunset", [RGBA(r: 1.0, g: 0.55, b: 0.35), RGBA(r: 0.85, g: 0.2, b: 0.5)]),
        ("Mint", [RGBA(r: 0.45, g: 0.9, b: 0.75), RGBA(r: 0.1, g: 0.55, b: 0.6)]),
        ("Grape", [RGBA(r: 0.66, g: 0.45, b: 1.0), RGBA(r: 0.35, g: 0.15, b: 0.7)]),
        ("Peach", [RGBA(r: 1.0, g: 0.85, b: 0.7), RGBA(r: 1.0, g: 0.6, b: 0.55)]),
        ("Slate", [RGBA(r: 0.36, g: 0.4, b: 0.47), RGBA(r: 0.12, g: 0.14, b: 0.18)]),
        ("Sand", [RGBA(r: 0.96, g: 0.93, b: 0.86), RGBA(r: 0.88, g: 0.82, b: 0.72)]),
        ("White", [RGBA(r: 1, g: 1, b: 1), RGBA(r: 0.95, g: 0.95, b: 0.96)]),
    ]
}

enum BackgroundAspect: String, CaseIterable, Codable, Identifiable {
    case auto, square, fourThree, sixteenNine, nineSixteen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }
}

/// Everything needed to redraw an edited capture. The image itself travels separately.
struct AnnotationDocument: Codable, Equatable {
    /// Base image size in points.
    var imageSize: CGSize
    /// Pixels per point of the base image (2 for Retina captures).
    var scale: CGFloat
    var annotations: [Annotation] = []
    /// Visible part of the image in image points; nil shows all of it.
    var crop: CGRect?
    var background = BackgroundSettings()

    var visibleRect: CGRect { crop ?? CGRect(origin: .zero, size: imageSize) }

    /// Counters and numbered arrows count in one sequence, so they can be mixed.
    var nextCounterNumber: Int {
        (annotations.filter { $0.tool == .counter || $0.tool == .numberedArrow }.map(\.number).max() ?? 0) + 1
    }
}
