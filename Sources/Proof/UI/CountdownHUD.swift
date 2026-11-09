import AppKit

/// The self-timer: a large number counting down in the middle of the screen. Escape cancels.
@MainActor
enum CountdownHUD {
    /// True when the countdown ran out, false when it was cancelled.
    static func run(seconds: Int) async -> Bool {
        guard seconds > 0 else { return true }
        let screen = ScreenGeometry.screenUnderMouse
        let size = NSSize(width: 160, height: 160)
        let panel = ChromePanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let box = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 28
        box.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 84, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size.height - 100) / 2, width: size.width, height: 100)
        box.addSubview(label)
        panel.contentView = box
        panel.orderFrontRegardless()

        var cancelled = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { cancelled = true }
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            panel.orderOut(nil)
        }
        for remaining in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(remaining)"
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if cancelled { return false }
            }
        }
        panel.orderOut(nil)
        // Let the window server drop the HUD before the capture.
        try? await Task.sleep(for: .milliseconds(120))
        return true
    }
}

private final class ChromePanel: NSPanel, CaptureChrome {}
