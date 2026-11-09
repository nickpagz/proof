import AppKit

/// One capture waiting in the Quick Access Overlay.
@MainActor
final class QuickAccessItem {
    /// Replaced when the capture is edited and saved, so the thumbnail and drags show the edit.
    var capture: Capture
    /// Where the capture was saved, if it was.
    var savedURL: URL?
    /// A temporary copy for dragging when the capture wasn't saved.
    var draftURL: URL?

    init(capture: Capture, savedURL: URL?) {
        self.capture = capture
        self.savedURL = savedURL
    }

    var fileURL: URL? { savedURL ?? draftURL }
}

/// What the overlay asks the app to do. Keeps the panel free of saving and clipboard logic.
@MainActor
protocol QuickAccessDelegate: AnyObject {
    func quickAccessCopy(_ item: QuickAccessItem)
    func quickAccessSave(_ item: QuickAccessItem)
    func quickAccessReveal(_ item: QuickAccessItem)
    func quickAccessOpen(_ item: QuickAccessItem)
    func quickAccessAnnotate(_ item: QuickAccessItem)
    /// Writes a file for dragging when the item has none yet.
    func quickAccessFileForDrag(_ item: QuickAccessItem) -> URL?
}

/// Floating thumbnails in a corner of the screen after each capture, CleanShot style: drag one
/// into any app, or hover for Copy, Save and Close.
@MainActor
final class QuickAccessController {
    weak var delegate: QuickAccessDelegate?
    var position: QuickAccessPosition = .left
    var autoCloseSeconds = 0
    var closeAfterDrag = true

    private var panels: [QuickAccessPanel] = []
    private var lastClosed: QuickAccessItem?

    var hasRecentlyClosed: Bool { lastClosed != nil }

    func show(_ item: QuickAccessItem) {
        let panel = QuickAccessPanel(item: item, controller: self)
        panels.insert(panel, at: 0)
        layout(animated: false, newest: panel)
        panel.orderFrontRegardless()
        if autoCloseSeconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(autoCloseSeconds)) { [weak self, weak panel] in
                guard let self, let panel, !panel.isHovered else { return }
                self.close(panel)
            }
        }
    }

    /// Redraws an item's thumbnail after its capture changed.
    func refresh(_ item: QuickAccessItem) {
        panels.first { $0.item === item }?.refreshImage()
    }

    func restoreRecentlyClosed() {
        guard let item = lastClosed else { return }
        lastClosed = nil
        show(item)
    }

    func closeAll() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    fileprivate func close(_ panel: QuickAccessPanel) {
        guard let index = panels.firstIndex(where: { $0 === panel }) else { return }
        lastClosed = panel.item
        panels.remove(at: index)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
        layout(animated: true, newest: nil)
    }

    fileprivate func copy(_ panel: QuickAccessPanel) { delegate?.quickAccessCopy(panel.item); panel.flash("Copied") }
    fileprivate func save(_ panel: QuickAccessPanel) {
        if panel.item.savedURL != nil { delegate?.quickAccessReveal(panel.item) } else { delegate?.quickAccessSave(panel.item); panel.refreshButtons(); panel.flash("Saved") }
    }
    fileprivate func open(_ panel: QuickAccessPanel) { delegate?.quickAccessOpen(panel.item) }
    fileprivate func annotate(_ panel: QuickAccessPanel) { delegate?.quickAccessAnnotate(panel.item) }
    fileprivate func fileForDrag(_ panel: QuickAccessPanel) -> URL? { delegate?.quickAccessFileForDrag(panel.item) }
    fileprivate func dragEnded(_ panel: QuickAccessPanel, accepted: Bool) {
        if accepted && closeAfterDrag { close(panel) }
    }

    private func layout(animated: Bool, newest: QuickAccessPanel?) {
        let screen = ScreenGeometry.screenUnderMouse
        let visible = screen.visibleFrame
        var y = visible.minY + 16
        for panel in panels {
            let size = panel.frame.size
            let x = position == .left ? visible.minX + 16 : visible.maxX - 16 - size.width
            let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            if animated && panel !== newest {
                panel.animator().setFrame(frame, display: true)
            } else {
                panel.setFrame(frame, display: true)
            }
            y += size.height + 12
            // Thumbnails that would run off the top of the screen are dropped from view but kept.
            panel.alphaValue = y > visible.maxY ? 0 : 1
        }
    }
}

private final class QuickAccessPanel: NSPanel, CaptureChrome {
    let item: QuickAccessItem
    private weak var controller: QuickAccessController?
    private let thumbnail: ThumbnailView
    var isHovered: Bool { thumbnail.isHovered }

    init(item: QuickAccessItem, controller: QuickAccessController) {
        self.item = item
        self.controller = controller
        let maxSide: CGFloat = 200
        let size = item.capture.pointSize
        let ratio = min(maxSide / max(size.width, 1), 150 / max(size.height, 1), 1)
        let thumbSize = NSSize(width: max(120, (size.width * ratio).rounded()), height: max(80, (size.height * ratio).rounded()))
        thumbnail = ThumbnailView(frame: NSRect(origin: .zero, size: thumbSize), image: item.capture.image)
        super.init(contentRect: NSRect(origin: .zero, size: thumbSize), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = thumbnail
        thumbnail.panel = self
        refreshButtons()
    }

    override var canBecomeKey: Bool { false }

    func refreshButtons() {
        thumbnail.saveTitle = item.savedURL == nil ? "Save" : "Show in Finder"
    }

    func flash(_ message: String) { thumbnail.flash(message) }

    func refreshImage() {
        thumbnail.image = item.capture.image
        refreshButtons()
    }

    fileprivate func perform(_ action: ThumbnailView.Action) {
        switch action {
        case .copy: controller?.copy(self)
        case .save: controller?.save(self)
        case .close: controller?.close(self)
        case .open: controller?.open(self)
        case .annotate: controller?.annotate(self)
        }
    }

    fileprivate func fileForDrag() -> URL? { controller?.fileForDrag(self) }
    fileprivate func dragEnded(accepted: Bool) { controller?.dragEnded(self, accepted: accepted) }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    enum Action { case copy, save, close, open, annotate }

    weak var panel: QuickAccessPanel?
    var image: CGImage { didSet { needsDisplay = true } }
    private(set) var isHovered = false { didSet { updateHover() } }
    private var mouseDownPoint: NSPoint?
    private let buttonStack = NSStackView()
    private let saveButton = NSButton()
    private let closeButton = NSButton()
    private let flashLabel = NSTextField(labelWithString: "")

    var saveTitle = "Save" { didSet { saveButton.title = saveTitle } }

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let annotate = pill("Annotate") { [weak self] in self?.panel?.perform(.annotate) }
        let copy = pill("Copy") { [weak self] in self?.panel?.perform(.copy) }
        configurePill(saveButton, title: saveTitle) { [weak self] in self?.panel?.perform(.save) }
        buttonStack.orientation = .vertical
        buttonStack.spacing = 6
        buttonStack.addArrangedSubview(annotate)
        buttonStack.addArrangedSubview(copy)
        buttonStack.addArrangedSubview(saveButton)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonStack)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        flashLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        flashLabel.textColor = .white
        flashLabel.alignment = .center
        flashLabel.isHidden = true
        flashLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flashLabel)

        NSLayoutConstraint.activate([
            buttonStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            flashLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            flashLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateHover()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = NSSize(width: image.width, height: image.height)
        let ratio = min(bounds.width / size.width, bounds.height / size.height)
        let drawn = NSRect(x: (bounds.width - size.width * ratio) / 2, y: (bounds.height - size.height * ratio) / 2,
                           width: size.width * ratio, height: size.height * ratio)
        context.interpolationQuality = .high
        context.draw(image, in: drawn)
        if isHovered || !flashLabel.isHidden {
            NSColor.black.withAlphaComponent(0.45).setFill()
            bounds.fill()
        }
    }

    private func updateHover() {
        let showControls = isHovered && flashLabel.isHidden
        buttonStack.isHidden = !showControls
        closeButton.isHidden = !showControls
        needsDisplay = true
    }

    func flash(_ message: String) {
        flashLabel.stringValue = message
        flashLabel.isHidden = false
        updateHover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.flashLabel.isHidden = true
            self?.updateHover()
        }
    }

    // MARK: Buttons

    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    private func pill(_ title: String, handler: @escaping () -> Void) -> NSButton {
        let button = NSButton()
        configurePill(button, title: title, handler: handler)
        return button
    }

    private func configurePill(_ button: NSButton, title: String, handler: @escaping () -> Void) {
        button.title = title
        button.bezelStyle = .push
        button.controlSize = .regular
        button.target = self
        button.action = #selector(pillTapped(_:))
        handlers[ObjectIdentifier(button)] = handler
    }

    @objc private func pillTapped(_ sender: NSButton) { handlers[ObjectIdentifier(sender)]?() }
    @objc private func closeTapped() { panel?.perform(.close) }

    // MARK: Click and drag

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        if event.clickCount == 2 { panel?.perform(.open) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, let url = panel?.fileForDrag() else { return }
        mouseDownPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = NSImage(cgImage: image, size: bounds.size)
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        panel?.dragEnded(accepted: operation != [])
    }
}
