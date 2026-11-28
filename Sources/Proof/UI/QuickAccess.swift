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
    func quickAccessShareDestinations() -> [(ShareVisibility, ProviderKind)]
    func quickAccessShare(_ item: QuickAccessItem, from sink: ShareSink, visibility: ShareVisibility)
    func quickAccessOpenSharingSettings()
    func quickAccessReveal(_ item: QuickAccessItem)
    func quickAccessOpen(_ item: QuickAccessItem)
    func quickAccessAnnotate(_ item: QuickAccessItem)
    /// Writes a file for dragging when the item has none yet.
    func quickAccessFileForDrag(_ item: QuickAccessItem) -> URL?
}

/// Floating thumbnails in a corner of the screen after each capture, CleanShot style: drag one
/// into any app, or hover for actions without opening the editor.
@MainActor
final class QuickAccessController {
    weak var delegate: QuickAccessDelegate?
    var position: QuickAccessPosition = .left
    var autoCloseSeconds = 0
    var closeAfterDrag = true

    private var panels: [QuickAccessPanel] = []
    // Restore the same panel so an in-flight upload keeps its progress and feedback.
    private var lastClosed: QuickAccessPanel?

    var hasRecentlyClosed: Bool { lastClosed != nil }

    func show(_ item: QuickAccessItem) {
        show(QuickAccessPanel(item: item, controller: self))
    }

    private func show(_ panel: QuickAccessPanel) {
        panels.insert(panel, at: 0)
        layout(animated: false, newest: panel)
        panel.orderFrontRegardless()
        if autoCloseSeconds > 0 {
            let deadlineID = UUID()
            panel.deadlineID = deadlineID
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(autoCloseSeconds)) { [weak self, weak panel] in
                guard let self, let panel, panel.deadlineID == deadlineID else { return }
                if panel.isShowingFeedback {
                    panel.autoCloseDeferred = true
                } else if !panel.isHovered {
                    self.close(panel)
                }
            }
        }
    }

    /// Redraws an item's thumbnail after its capture changed.
    func refresh(_ item: QuickAccessItem) {
        panels.first { $0.item === item }?.refreshImage()
    }

    func restoreRecentlyClosed() {
        guard let panel = lastClosed else { return }
        lastClosed = nil
        panel.refreshImage()
        show(panel)
    }

    func closeAll() {
        panels.forEach { $0.hidePreview() }
        panels = []
    }

    fileprivate func close(_ panel: QuickAccessPanel) {
        guard let index = panels.firstIndex(where: { $0 === panel }) else { return }
        lastClosed = panel
        panels.remove(at: index)
        panel.hidePreview()
        layout(animated: true, newest: nil)
    }

    fileprivate func resumeAutoClose(_ panel: QuickAccessPanel) {
        guard panel.autoCloseDeferred, !panel.isHovered, !panel.isShowingFeedback else { return }
        panel.autoCloseDeferred = false
        close(panel)
    }

    fileprivate func copy(_ panel: QuickAccessPanel) { delegate?.quickAccessCopy(panel.item); panel.flash("Copied") }
    fileprivate func save(_ panel: QuickAccessPanel) {
        if panel.item.savedURL != nil {
            delegate?.quickAccessReveal(panel.item)
            return
        }
        delegate?.quickAccessSave(panel.item)
        panel.refreshButtons()
        if panel.item.savedURL != nil {
            panel.flash("Saved")
        } else {
            panel.flash("Couldn’t save")
            // Keep the thumbnail and open the editor so the user can try Save As.
            delegate?.quickAccessOpen(panel.item)
        }
    }
    fileprivate func shareDestinations() -> [(ShareVisibility, ProviderKind)] {
        delegate?.quickAccessShareDestinations() ?? []
    }
    fileprivate func share(_ panel: QuickAccessPanel, visibility: ShareVisibility) {
        guard panel.uploadProgress == nil else { return }
        delegate?.quickAccessShare(panel.item, from: panel, visibility: visibility)
    }
    fileprivate func openSharingSettings() { delegate?.quickAccessOpenSharingSettings() }
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

private final class QuickAccessPanel: NSPanel, CaptureChrome, ShareSink {
    let item: QuickAccessItem
    private weak var controller: QuickAccessController?
    private let thumbnail: ThumbnailView
    var isHovered: Bool { thumbnail.isHovered }
    var isShowingFeedback: Bool { thumbnail.isShowingFeedback }
    var autoCloseDeferred = false
    var deadlineID: UUID?
    var uploadLabel = ""
    var uploadProgress: Double? {
        didSet { thumbnail.isUploading = uploadProgress != nil }
    }

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
        acceptsMouseMovedEvents = true
        contentView = thumbnail
        thumbnail.panel = self
        refreshButtons()
    }

    override var canBecomeKey: Bool { false }

    func hidePreview() {
        deadlineID = nil
        autoCloseDeferred = false
        orderOut(nil)
        thumbnail.resetHover()
    }

    func refreshButtons() {
        thumbnail.isSaved = item.savedURL != nil
    }

    func flash(_ message: String) { thumbnail.flash(message) }

    func showError(_ message: String) {
        flash("Couldn’t share")
        Notifier.shared.notify(title: "Couldn’t share", body: message)
    }

    func shareSucceeded(_ confirmation: ShareConfirmation) {
        flash(confirmation.copied ? "Link copied" : "Shared")
    }

    fileprivate func showShareMenu(from button: NSButton) {
        let menu = NSMenu()
        for (visibility, service) in controller?.shareDestinations() ?? [] {
            let entry = NSMenuItem(title: "Upload to \(service.label)",
                                   action: #selector(shareSelected(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = visibility.rawValue
            menu.addItem(entry)
        }
        if menu.items.isEmpty {
            let entry = NSMenuItem(title: "Sharing Settings…", action: #selector(openSharingSettings), keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func shareSelected(_ entry: NSMenuItem) {
        guard let value = entry.representedObject as? String, let visibility = ShareVisibility(rawValue: value) else { return }
        controller?.share(self, visibility: visibility)
    }

    @objc private func openSharingSettings() { controller?.openSharingSettings() }

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

    fileprivate func resumeAutoClose() { controller?.resumeAutoClose(self) }
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
    private let saveButton = IconButton()
    private let closeButton = IconButton()
    private let flashLabel = NSTextField(labelWithString: "")
    private var flashID = UUID()
    /// The name of the icon under the pointer. The icons start hidden, and neither tooltips nor
    /// their own hover tracking work until a click, so the thumbnail follows the pointer itself.
    private let hintLabel = NSTextField(labelWithString: "")
    private weak var hoveredButton: NSButton?

    var isSaved = false {
        didSet {
            setIcon(saveButton, isSaved ? "folder" : "square.and.arrow.down", label: isSaved ? "Show in Finder" : "Save")
            updateHover()
        }
    }
    var isUploading = false {
        didSet { if oldValue != isUploading { updateHover() } }
    }

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let annotate = IconButton()
        let copy = IconButton()
        let share = IconButton()
        configure(annotate, "pencil", label: "Annotate") { [weak self] _ in self?.panel?.perform(.annotate) }
        configure(copy, "doc.on.doc", label: "Copy") { [weak self] _ in self?.panel?.perform(.copy) }
        configure(saveButton, "square.and.arrow.down", label: "Save") { [weak self] _ in self?.panel?.perform(.save) }
        configure(share, "square.and.arrow.up", label: "Share…") { [weak self] button in self?.panel?.showShareMenu(from: button) }
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 3
        [annotate, copy, saveButton, share].forEach(buttonStack.addArrangedSubview)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonStack)

        configure(closeButton, "xmark", label: "Dismiss Preview") { [weak self] _ in self?.panel?.perform(.close) }
        addSubview(closeButton)

        flashLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        flashLabel.textColor = .white
        flashLabel.alignment = .center
        flashLabel.isHidden = true
        flashLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flashLabel)

        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.alignment = .center
        hintLabel.isHidden = true
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            buttonStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            flashLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            flashLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            flashLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            flashLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -4),
        ])
        updateHover()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    func resetHover() {
        hoveredButton = nil
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let button = ([closeButton] + buttonStack.arrangedSubviews).first {
            !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: self).contains(point)
        } as? NSButton
        guard button !== hoveredButton else { return }
        hoveredButton = button
        updateHover()
    }
    override func mouseExited(with event: NSEvent) {
        hoveredButton = nil
        isHovered = false
        panel?.resumeAutoClose()
    }
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

    var isShowingFeedback: Bool { !flashLabel.isHidden }

    private func updateHover() {
        flashLabel.stringValue = isUploading ? "Uploading…" : flashMessage ?? ""
        flashLabel.isHidden = flashLabel.stringValue.isEmpty
        let showControls = isHovered && flashLabel.isHidden
        buttonStack.isHidden = !showControls
        closeButton.isHidden = !isHovered
        if hoveredButton?.isHiddenOrHasHiddenAncestor == true { hoveredButton = nil }
        hintLabel.stringValue = hoveredButton?.accessibilityLabel() ?? ""
        hintLabel.isHidden = hintLabel.stringValue.isEmpty
        needsDisplay = true
    }

    private var flashMessage: String?

    func flash(_ message: String) {
        flashMessage = message
        let id = UUID()
        flashID = id
        updateHover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.flashID == id else { return }
            self.flashMessage = nil
            self.updateHover()
            self.panel?.resumeAutoClose()
        }
    }

    // MARK: Buttons

    private final class IconButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private var handlers: [ObjectIdentifier: (NSButton) -> Void] = [:]

    private func setIcon(_ button: NSButton, _ symbol: String, label: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        button.setAccessibilityLabel(label)
    }

    private func configure(_ button: NSButton, _ symbol: String, label: String, handler: @escaping (NSButton) -> Void) {
        button.title = ""
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 24)])
        setIcon(button, symbol, label: label)
        button.target = self
        button.action = #selector(iconTapped(_:))
        handlers[ObjectIdentifier(button)] = handler
    }

    @objc private func iconTapped(_ sender: NSButton) { handlers[ObjectIdentifier(sender)]?(sender) }

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
