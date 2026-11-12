import AppKit

/// The editable picture. A flipped view sized to the output in points; the scroll view around
/// it handles zoom, so mouse locations are already in output points.
final class CanvasView: NSView, NSTextViewDelegate {
    let model: EditorModel

    private enum Drag {
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case resizing(UUID, handle: Handle)
        case crop(anchor: CGPoint)
        case cropMove(offset: CGPoint)
        case cropResize(handle: Handle)
    }
    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end }

    private var drag: Drag?
    private var textView: NSTextView?
    private var editingTextID: UUID?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        syncSize()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// In crop mode the whole uncropped image is shown, without the background.
    private var cropping: Bool { model.tool == .crop }

    private var displayDocument: AnnotationDocument {
        var doc = model.document
        if cropping { doc.crop = nil; doc.background.enabled = false }
        return doc
    }

    var layout: RenderLayout { AnnotationRenderer.layout(displayDocument) }

    func syncSize() {
        let size = layout.outputSize
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        layout.toImage(convert(event.locationInWindow, from: nil))
    }

    private func viewRect(_ imageRect: CGRect) -> CGRect {
        let l = layout
        return CGRect(origin: l.toOutput(imageRect.origin), size: imageRect.size)
    }

    /// Screen-constant sizes (handles, hit slop) in image points at the current zoom.
    private var pointsPerScreenPoint: CGFloat {
        1 / max(enclosingScrollView?.magnification ?? 1, 0.05)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        model.renderer.draw(model.document, in: context, hiding: editingTextID.map { [$0] } ?? [], showFullImage: cropping)
        if cropping {
            drawCropOverlay(context)
        } else if let selected = model.annotation(model.selection), editingTextID == nil {
            drawSelection(selected, context)
        }
    }

    private func drawSelection(_ a: Annotation, _ context: CGContext) {
        let s = pointsPerScreenPoint
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1 * s)
        context.setLineDash(phase: 0, lengths: [4 * s, 3 * s])
        context.stroke(viewRect(a.bounds))
        context.restoreGState()
        for (_, point) in handles(for: a) {
            let p = layout.toOutput(point)
            let r = CGRect(x: p.x - 4.5 * s, y: p.y - 4.5 * s, width: 9 * s, height: 9 * s)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: r)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5 * s)
            context.strokeEllipse(in: r)
        }
    }

    private func drawCropOverlay(_ context: CGContext) {
        guard let crop = model.pendingCrop else { return }
        let s = pointsPerScreenPoint
        let r = viewRect(crop)
        context.saveGState()
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(r)
        context.addPath(path)
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1 * s)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            context.move(to: CGPoint(x: x, y: r.minY)); context.addLine(to: CGPoint(x: x, y: r.maxY))
            context.move(to: CGPoint(x: r.minX, y: y)); context.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        context.strokePath()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2 * s)
        context.stroke(r)
        context.setFillColor(NSColor.white.cgColor)
        for (_, p) in rectHandles(crop) {
            let v = layout.toOutput(p)
            context.fill(CGRect(x: v.x - 5 * s, y: v.y - 5 * s, width: 10 * s, height: 10 * s))
        }
        context.restoreGState()
        let label = NSAttributedString(string: "\(Int(crop.width * model.document.scale)) × \(Int(crop.height * model.document.scale)) px", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * s, weight: .medium), .foregroundColor: NSColor.white,
        ])
        label.draw(at: CGPoint(x: r.minX + 6 * s, y: r.minY + 6 * s))
    }

    // MARK: Handles

    private func rectHandles(_ r: CGRect) -> [(Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
         (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    private func handles(for a: Annotation) -> [(Handle, CGPoint)] {
        switch a.tool {
        case .line, .arrow, .numberedArrow: return [(.start, a.start), (.end, a.end)]
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur, .spotlight: return rectHandles(a.rect)
        default: return []
        }
    }

    private func handle(at p: CGPoint, in list: [(Handle, CGPoint)]) -> Handle? {
        let slop = 8 * pointsPerScreenPoint
        return list.first { hypot($0.1.x - p.x, $0.1.y - p.y) < slop }?.0
    }

    private static func resize(_ r: CGRect, _ handle: Handle, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        case .start, .end: break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: Mouse

    private func topAnnotation(at p: CGPoint) -> Annotation? {
        let tolerance = 4 * pointsPerScreenPoint
        return model.document.annotations.reversed().first { $0.hitTest(p, tolerance: tolerance) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if editingTextID != nil { endTextEditing() }
        let p = imagePoint(event)

        if cropping {
            guard let crop = model.pendingCrop else { return }
            if let h = handle(at: p, in: rectHandles(crop)) {
                drag = .cropResize(handle: h)
            } else if crop.contains(p) {
                drag = .cropMove(offset: CGPoint(x: p.x - crop.minX, y: p.y - crop.minY))
            } else {
                drag = .crop(anchor: clampToImage(p))
            }
            return
        }

        // Handles of the selected annotation win over everything else.
        if let selected = model.annotation(model.selection), let h = handle(at: p, in: handles(for: selected)) {
            model.beginGesture()
            drag = .resizing(selected.id, handle: h)
            return
        }

        let tool = model.tool
        if let hit = topAnnotation(at: p), tool == .select || (tool != .pencil && tool != .highlighter && tool != .counter && !(tool == .text && hit.tool != .text)) {
            model.selection = hit.id
            if hit.tool == .text && (event.clickCount == 2 || tool == .text) {
                beginTextEditing(hit.id)
                return
            }
            model.beginGesture()
            drag = .moving(hit.id, last: p)
            return
        }

        switch tool {
        case .select:
            model.selection = nil
        case .counter:
            var a = Annotation(tool: .counter, start: p, end: p, style: model.style)
            a.number = model.document.nextCounterNumber
            model.mutate("Add Counter") { $0.annotations.append(a) }
            model.selection = a.id
        case .text:
            // Adding and typing are one undo step; an empty box leaves no trace.
            let a = Annotation(tool: .text, start: CGPoint(x: p.x - AnnotationRenderer.textInset.width, y: p.y - model.style.fontSize * 0.7),
                               end: p, style: model.style)
            model.beginGesture()
            model.updateDuringGesture { $0.annotations.append(a) }
            model.selection = a.id
            beginTextEditing(a.id, gestureStarted: true)
        default:
            var a = Annotation(tool: tool, start: p, end: p, style: model.style)
            if tool == .pencil || tool == .highlighter { a.points = [p] }
            if tool == .numberedArrow { a.number = model.document.nextCounterNumber }
            model.beginGesture()
            model.updateDuringGesture { $0.annotations.append(a) }
            model.selection = nil
            drag = .creating(a.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        var p = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case .crop(let anchor):
            p = clampToImage(p)
            model.pendingCrop = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        case .cropMove(let offset):
            guard let crop = model.pendingCrop else { return }
            let size = model.document.imageSize
            let x = min(max(p.x - offset.x, 0), size.width - crop.width), y = min(max(p.y - offset.y, 0), size.height - crop.height)
            model.pendingCrop = CGRect(x: x, y: y, width: crop.width, height: crop.height)
        case .cropResize(let handle):
            guard let crop = model.pendingCrop else { return }
            model.pendingCrop = Self.resize(crop, handle, to: clampToImage(p))
        case .creating(let id):
            model.updateDuringGesture { doc in
                guard let i = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
                var a = doc.annotations[i]
                if a.tool == .pencil || a.tool == .highlighter {
                    if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) < 1.5 { return }
                    a.points.append(p)
                } else {
                    a.end = shift ? Self.constrain(from: a.start, to: p, tool: a.tool) : p
                }
                doc.annotations[i] = a
            }
        case .moving(let id, let last):
            let delta = CGPoint(x: p.x - last.x, y: p.y - last.y)
            model.updateDuringGesture { doc in
                if let i = doc.annotations.firstIndex(where: { $0.id == id }) { doc.annotations[i].offset(by: delta) }
            }
            self.drag = .moving(id, last: p)
        case .resizing(let id, let handle):
            model.updateDuringGesture { doc in
                guard let i = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
                var a = doc.annotations[i]
                switch handle {
                case .start: a.start = shift ? Self.constrain(from: a.end, to: p, tool: a.tool) : p
                case .end: a.end = shift ? Self.constrain(from: a.start, to: p, tool: a.tool) : p
                default:
                    let r = Self.resize(a.rect, handle, to: p)
                    a.start = r.origin
                    a.end = CGPoint(x: r.maxX, y: r.maxY)
                }
                doc.annotations[i] = a
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard let drag else { return }
        switch drag {
        case .creating(let id):
            // A click without a drag leaves nothing behind.
            if let a = model.annotation(id), a.tool != .pencil, a.tool != .highlighter, hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 3 {
                model.updateDuringGesture { $0.annotations.removeAll { $0.id == id } }
                model.endGesture("Add")
            } else {
                model.endGesture("Add \(model.annotation(id)?.tool.label ?? "Annotation")")
                if let a = model.annotation(id), a.tool != .pencil, a.tool != .highlighter { model.selection = id }
            }
        case .moving:
            model.endGesture("Move")
        case .resizing:
            model.endGesture("Resize")
        case .crop:
            if let crop = model.pendingCrop, crop.width < 4 || crop.height < 4 { model.resetCrop() }
        default:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: imagePoint(event))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: imagePoint(event))
    }

    /// The toolbar and the grey surround get the normal pointer back.
    override func mouseExited(with event: NSEvent) {
        if drag == nil { NSCursor.arrow.set() }
    }

    private func updateCursor(at p: CGPoint) {
        if cropping || model.tool == .select {
            if let crop = model.pendingCrop, cropping, crop.contains(p) { NSCursor.openHand.set(); return }
            if !cropping, topAnnotation(at: p) != nil { NSCursor.openHand.set(); return }
            if cropping { NSCursor.crosshair.set(); return }
            NSCursor.arrow.set()
        } else if model.tool == .text {
            NSCursor.iBeam.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        let size = model.document.imageSize
        return CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
    }

    /// Shift: squares and circles, or lines snapped to 45°.
    private static func constrain(from a: CGPoint, to b: CGPoint, tool: EditorTool) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        switch tool {
        case .line, .arrow, .numberedArrow:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 51, 117: // Delete
            model.deleteSelection()
        case 53: // Escape
            if cropping { model.cancelCrop() } else { model.selection = nil }
        case 36, 76: // Return
            if cropping { model.applyCrop() } else if let id = model.selection, model.annotation(id)?.tool == .text { beginTextEditing(id) }
        case 123, 124, 125, 126:
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            model.nudgeSelection(dx: dx, dy: dy)
        default:
            if flags.isEmpty || flags == .shift, let ch = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = EditorTool.allCases.first(where: { $0.key == ch }) {
                model.tool = tool
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Text editing

    func beginTextEditing(_ id: UUID, gestureStarted: Bool = false) {
        guard let a = model.annotation(id) else { return }
        if editingTextID != nil { endTextEditing() }
        editingTextID = id
        if !gestureStarted { model.beginGesture() }
        let tv = NSTextView(frame: .zero)
        tv.delegate = self
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        tv.font = AnnotationRenderer.font(for: a.style)
        tv.textColor = .textColor
        tv.string = a.text
        tv.textContainerInset = AnnotationRenderer.textInset
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 10_000, height: 10_000)
        tv.wantsLayer = true
        tv.layer?.borderColor = NSColor.controlAccentColor.cgColor
        tv.layer?.borderWidth = 1
        tv.layer?.cornerRadius = 4
        addSubview(tv)
        textView = tv
        layoutTextView()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        needsDisplay = true
    }

    private func layoutTextView() {
        guard let tv = textView, let id = editingTextID, let a = model.annotation(id) else { return }
        let size = AnnotationRenderer.textSize(for: a)
        tv.frame = CGRect(origin: layout.toOutput(a.start), size: CGSize(width: max(size.width + 20, 80), height: size.height))
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingTextID else { return }
        model.updateDuringGesture { doc in
            if let i = doc.annotations.firstIndex(where: { $0.id == id }) { doc.annotations[i].text = tv.string }
        }
        layoutTextView()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endTextEditing()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func endTextEditing() {
        guard let id = editingTextID else { return }
        textView?.removeFromSuperview()
        textView = nil
        editingTextID = nil
        if let a = model.annotation(id), a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.updateDuringGesture { $0.annotations.removeAll { $0.id == id } }
            model.selection = nil
        }
        model.endGesture("Text")
        needsDisplay = true
    }
}

/// Keeps a smaller-than-window canvas centred instead of pinned to the top-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}
