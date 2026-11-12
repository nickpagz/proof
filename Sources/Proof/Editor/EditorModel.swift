import AppKit
import Observation

/// What the editor asks the app to do with the finished image.
@MainActor
protocol EditorDelegate: AnyObject {
    /// Writes the image and returns where it went, or nil after reporting a failure.
    func editorSave(_ editor: EditorModel, image: CGImage, pointSize: CGSize) -> URL?
    func editorSaveAs(_ editor: EditorModel, image: CGImage, pointSize: CGSize) -> URL?
    func editorShare(_ editor: EditorModel, image: CGImage, pointSize: CGSize, visibility: ShareVisibility)
    func editorCanShare(_ visibility: ShareVisibility) -> Bool
    /// The service behind the button, which is also its title: "CloudUp", "WordPress.com".
    func editorShareService(_ visibility: ShareVisibility) -> String?
    func editorShareHelp(_ visibility: ShareVisibility) -> String
    func editorStopAskingBeforeClose()
    func editorDidClose(_ editor: EditorModel)
}

/// Shown over the editor once a share is up; OK closes the editor.
struct ShareConfirmation: Equatable {
    let service: String
    let url: URL
    /// False when "Copy the link" is off in Settings; the alert then offers to copy it.
    let copied: Bool
}

enum ShareVisibility: String, Codable {
    case `private`, `public`
    var label: String { self == .private ? "Share Private" : "Share Public" }
}

/// State of one editor window: the document, the active tool and style, selection and undo.
@MainActor @Observable
final class EditorModel: ShareSink {
    private(set) var document: AnnotationDocument
    @ObservationIgnored let renderer: AnnotationRenderer
    var tool: EditorTool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .crop { pendingCrop = nil }
            if tool == .crop { pendingCrop = document.crop ?? CGRect(origin: .zero, size: document.imageSize); selection = nil }
            onToolChange?()
            needsDisplay()
        }
    }
    /// The style new annotations get; editing it also restyles the selected annotation.
    var style: AnnotationStyle {
        didSet {
            guard style != oldValue else { return }
            Self.saveStyle(style)
            if let id = selection { restyle(id, from: oldValue) }
        }
    }
    var selection: UUID? { didSet { if selection != oldValue { syncStyleFromSelection(); needsDisplay() } } }
    /// The crop being adjusted while the crop tool is active, in image points.
    var pendingCrop: CGRect? { didSet { needsDisplay() } }
    var showBackgroundPanel = false
    /// Zoom chosen in the bottom bar; nil fits the window.
    var zoom: CGFloat?
    var statusMessage: String?
    /// 0…1 while a share is uploading.
    var uploadProgress: Double?
    var uploadLabel = ""
    /// Shown as an alert over the editor.
    var errorMessage: String?
    var shareConfirmation: ShareConfirmation?
    var isUploading: Bool { uploadProgress != nil }

    /// The file this capture lives in, if any; Save writes back to it.
    var fileURL: URL?
    /// The document as it was last saved, copied, dragged or shared; nil if never.
    @ObservationIgnored private var handledDocument: AnnotationDocument?
    @ObservationIgnored var confirmsUnsavedClose = true
    @ObservationIgnored var closesAfterSave = true
    /// Asks the window to close; set by the window controller.
    @ObservationIgnored var onRequestClose: (() -> Void)?

    /// A capture that was never saved can only be saved with a name and place.
    var needsSaveAs: Bool { fileURL == nil }
    /// True when closing would lose work nobody has kept anywhere.
    var hasUnhandledChanges: Bool { handledDocument != document }

    func markHandled() { handledDocument = document }
    let title: String
    let capturedAt: Date
    let appName: String?

    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored weak var delegate: EditorDelegate?
    @ObservationIgnored var onNeedsDisplay: (() -> Void)?
    @ObservationIgnored var onToolChange: (() -> Void)?
    @ObservationIgnored var onZoomChange: (() -> Void)?
    @ObservationIgnored private var gestureStart: AnnotationDocument?
    @ObservationIgnored private var syncingStyle = false

    init(image: CGImage, pointSize: CGSize, fileURL: URL?, title: String, capturedAt: Date = Date(), appName: String? = nil) {
        renderer = AnnotationRenderer(image: image)
        document = AnnotationDocument(imageSize: pointSize, scale: CGFloat(image.width) / max(pointSize.width, 1))
        style = Self.loadStyle()
        self.fileURL = fileURL
        self.title = title
        self.capturedAt = capturedAt
        self.appName = appName
    }

    // MARK: Changes and undo

    func needsDisplay() { onNeedsDisplay?() }

    /// One undoable change.
    func mutate(_ name: String, _ change: (inout AnnotationDocument) -> Void) {
        let before = document
        change(&document)
        guard document != before else { return }
        registerUndo(restoring: before, name: name)
        needsDisplay()
    }

    /// Mouse drags change the document many times; they become one undo step.
    func beginGesture() { gestureStart = document }

    func updateDuringGesture(_ change: (inout AnnotationDocument) -> Void) {
        change(&document)
        needsDisplay()
    }

    func endGesture(_ name: String) {
        defer { gestureStart = nil }
        guard let start = gestureStart, start != document else { return }
        registerUndo(restoring: start, name: name)
    }

    private func registerUndo(restoring old: AnnotationDocument, name: String) {
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.document
            model.document = old
            if let id = model.selection, !old.annotations.contains(where: { $0.id == id }) { model.selection = nil }
            model.registerUndo(restoring: current, name: name)
            model.needsDisplay()
        }
        undoManager.setActionName(name)
    }

    // MARK: Annotations

    func annotation(_ id: UUID?) -> Annotation? {
        guard let id else { return nil }
        return document.annotations.first { $0.id == id }
    }

    func deleteSelection() {
        guard let id = selection else { return }
        mutate("Delete") { $0.annotations.removeAll { $0.id == id } }
        selection = nil
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let id = selection else { return }
        mutate("Move") { doc in
            if let i = doc.annotations.firstIndex(where: { $0.id == id }) { doc.annotations[i].offset(by: CGPoint(x: dx, y: dy)) }
        }
    }

    func bringSelectionToFront() {
        guard let id = selection else { return }
        mutate("Bring to Front") { doc in
            if let i = doc.annotations.firstIndex(where: { $0.id == id }) { doc.annotations.append(doc.annotations.remove(at: i)) }
        }
    }

    /// Only the properties the user just changed carry over, so restyling a text box doesn't
    /// reset its font size to the arrow's width.
    private func restyle(_ id: UUID, from old: AnnotationStyle) {
        guard !syncingStyle, let current = annotation(id) else { return }
        var s = current.style
        if style.color != old.color { s.color = style.color }
        if style.lineWidth != old.lineWidth { s.lineWidth = style.lineWidth }
        if style.arrowStyle != old.arrowStyle { s.arrowStyle = style.arrowStyle }
        if style.textStyle != old.textStyle { s.textStyle = style.textStyle }
        if style.fontSize != old.fontSize { s.fontSize = style.fontSize }
        if style.shadow != old.shadow { s.shadow = style.shadow }
        guard s != current.style else { return }
        mutate("Change Style") { doc in
            if let i = doc.annotations.firstIndex(where: { $0.id == id }) { doc.annotations[i].style = s }
        }
    }

    /// Selecting an annotation shows its style in the toolbar.
    private func syncStyleFromSelection() {
        guard let a = annotation(selection) else { return }
        syncingStyle = true
        style = a.style
        syncingStyle = false
    }

    // MARK: Crop and background

    func applyCrop() {
        guard let rect = pendingCrop else { return }
        let full = CGRect(origin: .zero, size: document.imageSize)
        let clipped = rect.intersection(full).integral
        mutate("Crop") { $0.crop = (clipped == full || clipped.width < 4 || clipped.height < 4) ? nil : clipped }
        tool = .select
    }

    func resetCrop() {
        pendingCrop = CGRect(origin: .zero, size: document.imageSize)
    }

    func cancelCrop() {
        tool = .select
    }

    func setBackground(_ change: (inout BackgroundSettings) -> Void) {
        mutate("Background") { change(&$0.background) }
    }

    // MARK: Output

    var outputPointSize: CGSize { AnnotationRenderer.layout(document).outputSize }

    func renderedImage() -> CGImage? {
        renderer.render(document)
    }

    func save() {
        if needsSaveAs { return saveAs() }
        guard let image = renderedImage() else { return }
        if let url = delegate?.editorSave(self, image: image, pointSize: outputPointSize) {
            fileURL = url
            didSave()
        }
    }

    func saveAs() {
        guard let image = renderedImage() else { return }
        if let url = delegate?.editorSaveAs(self, image: image, pointSize: outputPointSize) {
            fileURL = url
            didSave()
        }
    }

    private func didSave() {
        markHandled()
        if closesAfterSave {
            onRequestClose?()
        } else {
            flash("Saved")
        }
    }

    func copy() {
        guard let image = renderedImage() else { return }
        ImageExporter.copyToClipboard(image, pointSize: outputPointSize, file: nil)
        markHandled()
        flash("Copied")
    }

    func share(_ visibility: ShareVisibility) {
        guard !isUploading, let image = renderedImage() else { return }
        delegate?.editorShare(self, image: image, pointSize: outputPointSize, visibility: visibility)
    }

    /// The link is out, so the capture is dealt with. The alert says where the link is; its OK
    /// closes the editor like a save does.
    func shareSucceeded(_ confirmation: ShareConfirmation) {
        markHandled()
        shareConfirmation = confirmation
    }

    func confirmShare() {
        shareConfirmation = nil
        if closesAfterSave { onRequestClose?() }
    }

    func showError(_ message: String) {
        errorMessage = message
    }

    func canShare(_ visibility: ShareVisibility) -> Bool { delegate?.editorCanShare(visibility) ?? false }

    func shareHelp(_ visibility: ShareVisibility) -> String { delegate?.editorShareHelp(visibility) ?? "" }

    func shareService(_ visibility: ShareVisibility) -> String? { delegate?.editorShareService(visibility) }

    /// A PNG of the current result in a temporary folder, for dragging and the share sheet.
    func exportDraft() -> URL? {
        guard let image = renderedImage() else { return nil }
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? title
        let url = AppInfo.draftsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(FileNaming.sanitize(name)).appendingPathExtension("png")
        var options = ImageExporter.Options()
        options.format = .png
        do {
            try ImageExporter.write(image, pointSize: outputPointSize, to: url, options: options)
            markHandled()
            return url
        } catch {
            flash("Couldn't export")
            return nil
        }
    }

    func flash(_ message: String) {
        statusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.statusMessage == message { self?.statusMessage = nil }
        }
    }

    // MARK: Style persistence

    private static let styleKey = "editor.style.v1"
    /// Off in self-tests, so they don't change the style the user last picked.
    nonisolated(unsafe) static var persistsStyle = true

    private static func loadStyle() -> AnnotationStyle {
        guard persistsStyle, let data = UserDefaults.standard.data(forKey: styleKey),
              let style = try? JSONDecoder().decode(AnnotationStyle.self, from: data) else { return AnnotationStyle() }
        return style
    }

    private static func saveStyle(_ style: AnnotationStyle) {
        guard persistsStyle else { return }
        if let data = try? JSONEncoder().encode(style) { UserDefaults.standard.set(data, forKey: styleKey) }
    }
}
