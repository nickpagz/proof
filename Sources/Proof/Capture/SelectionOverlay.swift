import AppKit
import SwiftUI

/// Full-screen overlay for choosing what to capture: drag an area, or press Space and click a
/// window. One borderless window per display; the selection itself lives here in global points.
@MainActor
final class SelectionOverlay {
    enum Mode { case area, window }

    enum Result {
        case area(CGRect)
        case window(PickableWindow)
        case fullscreen(CGDirectDisplayID)
        case previousArea
        case selfTimer(CGRect)
        /// All-In-One's Record button.
        case recordArea(CGRect)
        case cancelled
    }

    struct Options {
        var startMode: Mode = .area
        /// Keep the selection adjustable with handles and a toolbar instead of capturing on release.
        var allInOne = false
        var showMagnifier = true
        var showCrosshair = true
        var hideDesktopIcons = true
        var initialSelection: CGRect?
        var hasPreviousArea = false
        /// Choosing what to record: a hint says how, and F picks the whole screen.
        var recording = false
    }

    let options: Options
    private(set) var mode: Mode
    /// Global points.
    var selection: CGRect? { didSet { redraw() } }
    private(set) var hoveredWindow: PickableWindow?
    /// Display snapshots, for the magnifier and for freeze. Filled in shortly after the overlay opens.
    private(set) var snapshots: [CGDirectDisplayID: CGImage] = [:]
    private(set) var mouse: CGPoint = .zero

    private var windows: [OverlayWindow] = []
    private var pickable: [PickableWindow] = []
    private var continuation: CheckedContinuation<Result, Never>?
    private var finished = false

    init(options: Options) {
        self.options = options
        self.mode = options.startMode
        self.selection = options.initialSelection
    }

    /// Shows the overlay and waits for a choice. Snapshots stay available afterwards.
    func run() async -> Result {
        pickable = ScreenGrabber.pickableWindows()
        mouse = ScreenGeometry.globalPoint(fromCocoa: NSEvent.mouseLocation)
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, overlay: self)
            windows.append(window)
        }
        // No NSApp.activate: activating Proof would raise its other windows (an open editor) above
        // the apps in front of them, and the capture would show them there. The overlay is a
        // non-activating panel, which takes the keyboard and mouse without that.
        let underMouse = ScreenGeometry.screenUnderMouse
        for window in windows {
            window.orderFrontRegardless()
            if window.screen == underMouse { window.makeKey() }
        }
        updateHover()
        NSCursor.crosshair.push()
        Task { await loadSnapshots() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func snapshot(for displayID: CGDirectDisplayID) -> CGImage? { snapshots[displayID] }

    private func loadSnapshots() async {
        for screen in NSScreen.screens {
            let id = ScreenGeometry.displayID(of: screen)
            if let image = try? await ScreenGrabber.capture(displayID: id, hideDesktopIcons: options.hideDesktopIcons) {
                snapshots[id] = image
                redraw()
            }
        }
    }

    // MARK: Events from the views

    func mouseMoved(to point: CGPoint) {
        mouse = point
        if mode == .window { updateHover() }
        redraw()
    }

    func toggleMode() {
        mode = mode == .area ? .window : .area
        selection = mode == .window ? nil : selection
        updateHover()
        redraw()
    }

    func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        continuation?.resume(returning: result)
        continuation = nil
    }

    func confirmSelection() {
        guard let selection, selection.width >= 2, selection.height >= 2 else { return }
        finish(.area(selection.integral))
    }

    func redraw() {
        windows.forEach { $0.contentView?.needsDisplay = true }
    }

    private func updateHover() {
        hoveredWindow = mode == .window ? pickable.first { $0.frame.contains(mouse) } : nil
    }
}

// MARK: - Window

private final class OverlayWindow: NSPanel, CaptureChrome {
    init(screen: NSScreen, overlay: SelectionOverlay) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), overlay: overlay,
                               displayID: ScreenGeometry.displayID(of: screen))
        contentView = view
        if overlay.options.allInOne, screen == ScreenGeometry.screenUnderMouse {
            view.installToolbar()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View

private final class OverlayView: NSView {
    // Strong on purpose: AppKit can deliver a last mouse event after the overlay finishes, and an
    // unowned reference would crash there. finish() drops the windows, which ends the cycle.
    private let overlay: SelectionOverlay
    private let displayID: CGDirectDisplayID

    private enum Drag {
        case creating(anchor: CGPoint)
        case moving(offset: CGPoint)
        case resizing(handle: Handle, original: CGRect)
    }
    private enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    private var drag: Drag?
    /// Space held while creating moves the whole selection instead of resizing it.
    private var spaceMoveOrigin: (mouse: CGPoint, rect: CGRect)?
    private var toolbar: NSHostingView<OverlayToolbar>?

    init(frame: NSRect, overlay: SelectionOverlay, displayID: CGDirectDisplayID) {
        self.overlay = overlay
        self.displayID = displayID
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    func installToolbar() {
        let host = NSHostingView(rootView: OverlayToolbar(overlay: overlay))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -60),
        ])
        toolbar = host
    }

    // MARK: Coordinates

    private var screenFrame: NSRect { window?.frame ?? .zero }

    private func global(_ event: NSEvent) -> CGPoint {
        let p = event.locationInWindow
        return ScreenGeometry.globalPoint(fromCocoa: NSPoint(x: p.x + screenFrame.minX, y: p.y + screenFrame.minY))
    }

    private func local(_ rect: CGRect) -> NSRect {
        let cocoa = ScreenGeometry.cocoaRect(fromGlobal: rect)
        return cocoa.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private func local(_ point: CGPoint) -> NSPoint {
        let cocoa = NSPoint(x: point.x, y: ScreenGeometry.mainDisplayHeight - point.y)
        return NSPoint(x: cocoa.x - screenFrame.minX, y: cocoa.y - screenFrame.minY)
    }

    private var displayBounds: CGRect { CGDisplayBounds(displayID) }

    private func clamp(_ point: CGPoint) -> CGPoint {
        let b = displayBounds
        return CGPoint(x: min(max(point.x, b.minX), b.maxX), y: min(max(point.y, b.minY), b.maxY))
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        // Proof isn't the active app while the overlay is up, so don't rely on cursor updates alone.
        let overToolbar = toolbar.map { $0.frame.contains(convert(event.locationInWindow, from: nil)) } ?? false
        (overToolbar ? NSCursor.arrow : NSCursor.crosshair).set()
        overlay.mouseMoved(to: global(event))
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamp(global(event))
        overlay.mouseMoved(to: point)
        if overlay.mode == .window {
            if let window = overlay.hoveredWindow { overlay.finish(.window(window)) }
            return
        }
        if overlay.options.allInOne, let selection = overlay.selection {
            if let handle = handle(at: point, in: selection) {
                drag = .resizing(handle: handle, original: selection)
                return
            }
            if selection.contains(point) {
                drag = .moving(offset: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY))
                return
            }
        }
        drag = .creating(anchor: point)
        overlay.selection = CGRect(origin: point, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(global(event))
        overlay.mouseMoved(to: point)
        guard let drag else { return }
        switch drag {
        case .creating(let anchor):
            if let origin = spaceMoveOrigin {
                let dx = point.x - origin.mouse.x, dy = point.y - origin.mouse.y
                let moved = origin.rect.offsetBy(dx: dx, dy: dy)
                overlay.selection = fit(moved)
                // Keep the anchor glued to the moved rectangle so releasing Space resumes resizing.
                self.drag = .creating(anchor: CGPoint(x: anchor.x + dx, y: anchor.y + dy))
                spaceMoveOrigin = (point, moved)
                return
            }
            var rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                              width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            if event.modifierFlags.contains(.shift) {
                let side = max(rect.width, rect.height)
                rect.size = CGSize(width: side, height: side)
                if point.x < anchor.x { rect.origin.x = anchor.x - side }
                if point.y < anchor.y { rect.origin.y = anchor.y - side }
            }
            if event.modifierFlags.contains(.option) {
                rect = CGRect(x: anchor.x - rect.width, y: anchor.y - rect.height, width: rect.width * 2, height: rect.height * 2)
            }
            overlay.selection = rect.intersection(displayBounds)
        case .moving(let offset):
            guard let selection = overlay.selection else { return }
            overlay.selection = fit(CGRect(origin: CGPoint(x: point.x - offset.x, y: point.y - offset.y), size: selection.size))
        case .resizing(let handle, let original):
            overlay.selection = resized(original, handle: handle, to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; spaceMoveOrigin = nil }
        guard drag != nil, overlay.mode == .area else { return }
        guard let selection = overlay.selection, selection.width >= 2, selection.height >= 2 else {
            // A click without a drag captures the window under the pointer, like macOS does.
            if case .creating = drag, !overlay.options.allInOne,
               let window = ScreenGrabber.pickableWindows().first(where: { $0.frame.contains(global(event)) }) {
                overlay.finish(.window(window))
            } else {
                overlay.selection = nil
            }
            return
        }
        if !overlay.options.allInOne { overlay.confirmSelection() }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            overlay.finish(.cancelled)
        case 36, 76: // Return, Enter
            overlay.confirmSelection()
        case 49: // Space
            if case .creating = drag, let selection = overlay.selection {
                if spaceMoveOrigin == nil { spaceMoveOrigin = (overlay.mouse, selection) }
            } else if drag == nil, !event.isARepeat {
                overlay.toggleMode()
            }
        case 123, 124, 125, 126: // arrows nudge the selection; Shift = 10 pt
            guard let selection = overlay.selection else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch Int(event.keyCode) {
            case 123: dx = -step
            case 124: dx = step
            case 125: dy = step
            default: dy = -step
            }
            if event.modifierFlags.contains(.option) {
                overlay.selection = CGRect(origin: selection.origin, size: CGSize(width: max(2, selection.width + dx), height: max(2, selection.height + dy)))
            } else {
                overlay.selection = fit(selection.offsetBy(dx: dx, dy: dy))
            }
        case 3 where overlay.options.recording && drag == nil: // F
            overlay.finish(.fullscreen(displayID))
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceMoveOrigin = nil }
    }

    // MARK: Geometry helpers

    private func fit(_ rect: CGRect) -> CGRect {
        let b = displayBounds
        var r = rect
        r.origin.x = min(max(r.minX, b.minX), b.maxX - r.width)
        r.origin.y = min(max(r.minY, b.minY), b.maxY - r.height)
        return r
    }

    private func handlePoints(_ rect: CGRect) -> [(Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.top, CGPoint(x: rect.midX, y: rect.minY)),
         (.topRight, CGPoint(x: rect.maxX, y: rect.minY)), (.right, CGPoint(x: rect.maxX, y: rect.midY)),
         (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)), (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
         (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)), (.left, CGPoint(x: rect.minX, y: rect.midY))]
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        handlePoints(rect).first { hypot($0.1.x - point.x, $0.1.y - point.y) < 8 }?.0
    }

    private func resized(_ r: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
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
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dim = NSColor.black.withAlphaComponent(0.32)

        switch overlay.mode {
        case .window:
            dim.setFill()
            bounds.fill()
            if let window = overlay.hoveredWindow {
                let rect = local(window.frame)
                context.clear(rect)
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                rect.fill()
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                path.lineWidth = 2
                path.stroke()
                if rect.intersects(bounds) {
                    drawLabel(window.ownerName.isEmpty ? "Window" : window.ownerName,
                              at: NSPoint(x: rect.midX, y: rect.midY), centered: true)
                }
            }
        case .area:
            if let selection = overlay.selection, selection.width > 0 || selection.height > 0 {
                dim.setFill()
                bounds.fill()
                let rect = local(selection)
                context.clear(rect)
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
                border.lineWidth = 1
                border.stroke()
                if overlay.options.allInOne && drag == nil {
                    for (_, point) in handlePoints(selection) {
                        let p = local(point)
                        let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                        NSColor.white.setFill(); dot.fill()
                        NSColor.controlAccentColor.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                    }
                }
                if rect.intersects(bounds) {
                    drawLabel("\(Int(selection.width)) × \(Int(selection.height))",
                              at: NSPoint(x: rect.midX, y: rect.minY - 22), centered: true)
                }
            } else if overlay.options.showCrosshair, displayBounds.contains(overlay.mouse) {
                let p = local(overlay.mouse)
                NSColor.white.withAlphaComponent(0.75).setStroke()
                let lines = NSBezierPath()
                lines.move(to: NSPoint(x: 0, y: p.y + 0.5)); lines.line(to: NSPoint(x: bounds.maxX, y: p.y + 0.5))
                lines.move(to: NSPoint(x: p.x + 0.5, y: 0)); lines.line(to: NSPoint(x: p.x + 0.5, y: bounds.maxY))
                lines.lineWidth = 1
                context.saveGState()
                context.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
                lines.stroke()
                context.restoreGState()
            }
            if overlay.options.showMagnifier, drag.map({ if case .creating = $0 { return true } else { return false } }) ?? true,
               displayBounds.contains(overlay.mouse) {
                drawMagnifier(context)
            }
        }
        if overlay.options.recording, !overlay.options.allInOne, overlay.selection == nil, displayBounds.contains(overlay.mouse) {
            let hint = overlay.mode == .area
                ? "Drag to record an area  ·  Click a window  ·  F records the whole screen  ·  Esc cancels"
                : "Click a window to record it  ·  Space for an area  ·  Esc cancels"
            drawLabel(hint, at: NSPoint(x: bounds.midX, y: bounds.maxY - 64), centered: true)
        }
    }

    private func drawLabel(_ text: String, at point: NSPoint, centered: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var box = NSRect(x: point.x - (centered ? size.width / 2 : 0) - 7, y: point.y - 3, width: size.width + 14, height: size.height + 6)
        box.origin.x = min(max(box.minX, 4), bounds.maxX - box.width - 4)
        box.origin.y = min(max(box.minY, 4), bounds.maxY - box.height - 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: NSPoint(x: box.minX + 7, y: box.minY + 3))
    }

    /// An 8x loupe of the pixels around the pointer, from the display snapshot.
    private func drawMagnifier(_ context: CGContext) {
        guard let image = overlay.snapshot(for: displayID) else { return }
        let bounds = displayBounds
        let scale = CGFloat(image.width) / bounds.width
        let mouse = overlay.mouse
        let pixelsAcross = 15
        let center = CGPoint(x: ((mouse.x - bounds.minX) * scale).rounded(.down), y: ((mouse.y - bounds.minY) * scale).rounded(.down))
        let source = CGRect(x: center.x - CGFloat(pixelsAcross / 2), y: center.y - CGFloat(pixelsAcross / 2),
                            width: CGFloat(pixelsAcross), height: CGFloat(pixelsAcross))
        guard let crop = image.cropping(to: source) else { return }

        let size: CGFloat = 120
        let p = local(mouse)
        var origin = NSPoint(x: p.x + 24, y: p.y - 24 - size)
        if origin.x + size > self.bounds.maxX - 8 { origin.x = p.x - 24 - size }
        if origin.y < 8 { origin.y = p.y + 24 }
        let box = NSRect(origin: origin, size: CGSize(width: size, height: size))

        context.saveGState()
        let clip = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        NSColor.black.setFill(); clip.fill()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        clip.addClip()
        context.interpolationQuality = .none
        // cropping() drops pixels outside the image; place the crop where it belongs in the grid.
        let cell = size / CGFloat(pixelsAcross)
        let offsetX = max(0, -source.minX) * cell
        let offsetY = max(0, -source.minY) * cell
        let drawRect = NSRect(x: box.minX + offsetX, y: box.maxY - offsetY - CGFloat(crop.height) * cell,
                              width: CGFloat(crop.width) * cell, height: CGFloat(crop.height) * cell)
        context.draw(crop, in: drawRect)
        // Centre pixel outline.
        let mid = NSRect(x: box.minX + CGFloat(pixelsAcross / 2) * cell, y: box.minY + CGFloat(pixelsAcross / 2) * cell, width: cell, height: cell)
        NSColor.white.setStroke()
        let centre = NSBezierPath(rect: mid)
        centre.lineWidth = 1.5
        centre.stroke()
        context.restoreGState()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        clip.lineWidth = 1
        clip.stroke()

        let coordinates = "\(Int(mouse.x - bounds.minX)), \(Int(mouse.y - bounds.minY))"
        drawLabel(coordinates, at: NSPoint(x: box.midX, y: box.minY - 26), centered: true)
    }
}

// MARK: - All-In-One toolbar

private struct OverlayToolbar: View {
    let overlay: SelectionOverlay

    var body: some View {
        HStack(spacing: 4) {
            button("Area", "rectangle.dashed") { if overlay.mode == .window { overlay.toggleMode() } }
            button("Window", "macwindow") { if overlay.mode == .area { overlay.toggleMode() } }
            button("Fullscreen", "display") {
                overlay.finish(.fullscreen(ScreenGeometry.displayID(of: ScreenGeometry.screenUnderMouse)))
            }
            if overlay.options.hasPreviousArea {
                button("Previous", "arrow.uturn.backward.square") { overlay.finish(.previousArea) }
            }
            button("Timer", "timer") {
                if let selection = overlay.selection, selection.width >= 2 { overlay.finish(.selfTimer(selection.integral)) }
            }
            button("Record", "record.circle") {
                if let selection = overlay.selection, selection.width >= 2 { overlay.finish(.recordArea(selection.integral)) }
            }
            Divider().frame(height: 22).padding(.horizontal, 4)
            Button("Capture") { overlay.confirmSelection() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Button("Cancel") { overlay.finish(.cancelled) }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.caption2)
            }
            .frame(width: 62, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
