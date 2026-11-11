import AppKit
import SwiftUI

extension View {
    /// A tooltip for toolbar controls that moves straight to the next control while one is showing.
    /// macOS tooltips fade out and wait again on every control, which drags when scanning a row of icons.
    func hoverHint(_ text: String) -> some View {
        background(HoverHintAnchor(text: text))
            .accessibilityHint(Text(text))
    }
}

private struct HoverHintAnchor: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> HoverHintAnchorView { HoverHintAnchorView(text: text) }
    func updateNSView(_ view: HoverHintAnchorView, context: Context) {
        view.text = text
        HoverHintPanel.shared.refresh(view)
    }
}

/// Sits behind a control and reports the pointer entering and leaving it. Tracking areas fire
/// whatever is drawn on top, so the control keeps its own clicks.
final class HoverHintAnchorView: NSView {
    var text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { HoverHintPanel.shared.enter(self) }
    override func mouseExited(with event: NSEvent) { HoverHintPanel.shared.exit(self) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { HoverHintPanel.shared.exit(self) }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// One label shared by every anchor, shown in a child window so it can hang over the canvas.
@MainActor
final class HoverHintPanel {
    static let shared = HoverHintPanel()

    /// Wait before the first label, as macOS does, so passing over the toolbar shows nothing.
    private let initialDelay = 0.25
    /// Leaving a control waits this long, so moving to the next one swaps the label without a flash.
    private let hideDelay = 0.08
    /// After a label hides, another control within this time shows its label at once.
    private let warmPeriod = 0.5

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private weak var anchor: HoverHintAnchorView?
    private var pending: DispatchWorkItem?
    private var hiddenAt = Date.distantPast

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        background.addSubview(label)
        panel.contentView = background

        // A click or key press dismisses the label, as with a system tooltip.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.hide()
            return event
        }
    }

    func enter(_ view: HoverHintAnchorView) {
        anchor = view
        pending?.cancel()
        if panel.isVisible || Date().timeIntervalSince(hiddenAt) < warmPeriod {
            show(view)
        } else {
            schedule(after: initialDelay) { [weak self, weak view] in
                guard let self, let view, self.anchor === view else { return }
                self.show(view)
            }
        }
    }

    func exit(_ view: HoverHintAnchorView) {
        guard anchor === view else { return }
        anchor = nil
        pending?.cancel()
        guard panel.isVisible else { return }
        schedule(after: hideDelay) { [weak self] in self?.hide() }
    }

    /// The text changed under the pointer, such as Save becoming Save As.
    func refresh(_ view: HoverHintAnchorView) {
        if anchor === view, panel.isVisible { show(view) }
    }

    private func show(_ view: HoverHintAnchorView) {
        guard let window = view.window else { return }
        label.stringValue = view.text
        label.sizeToFit()
        let padding = NSSize(width: 7, height: 3)
        let size = NSSize(width: ceil(label.frame.width) + padding.width * 2, height: ceil(label.frame.height) + padding.height * 2)
        label.setFrameOrigin(NSPoint(x: padding.width, y: padding.height))

        let anchorRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        // Below a control in the top half of the window, above one in the bottom half, so the label
        // hangs over the canvas rather than off the window's edge.
        let below = anchorRect.midY > window.frame.midY
        var origin = NSPoint(x: anchorRect.midX - size.width / 2,
                             y: below ? anchorRect.minY - 6 - size.height : anchorRect.maxY + 6)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func hide() {
        pending?.cancel()
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        hiddenAt = Date()
    }

    private func schedule(after seconds: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}
