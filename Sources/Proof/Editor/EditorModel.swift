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
            if tool == .crop {
                pendingCrop = document.visibleRect
                let exact = document.exactCropSize
                cropFormat = .freeform
                cropWidth = exact.map { String($0.width) } ?? ""
                cropHeight = exact.map { String($0.height) } ?? ""
                if exact != nil { cropFormat = .custom }
                selection = nil
            }
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
    private(set) var cropFormat: CropFormat = .freeform
    var cropWidth = "" { didSet { previewCustomCrop() } }
    var cropHeight = "" { didSet { previewCustomCrop() } }
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

    private var fullImage: CGRect { CGRect(origin: .zero, size: document.imageSize) }
    private var pixelsPerPoint: CGSize {
        CGSize(width: CGFloat(renderer.image.width) / document.imageSize.width,
               height: CGFloat(renderer.image.height) / document.imageSize.height)
    }

    func cropPixelSize(of rect: CGRect) -> CropPixelSize {
        CropPixelSize(width: Int((rect.width * pixelsPerPoint.width).rounded()),
                      height: Int((rect.height * pixelsPerPoint.height).rounded()))
    }

    private var enteredCropSize: CropPixelSize? {
        guard let width = Int(cropWidth.trimmingCharacters(in: .whitespaces)),
              let height = Int(cropHeight.trimmingCharacters(in: .whitespaces)),
              width > 0, height > 0 else { return nil }
        return CropPixelSize(width: width, height: height)
    }

    private var validCustomCropSize: CropPixelSize? {
        guard let size = enteredCropSize, size.width <= renderer.image.width, size.height <= renderer.image.height else { return nil }
        return size
    }

    var cropProblem: String? {
        guard cropFormat == .custom else { return nil }
        if document.background.enabled { return "Turn off Background to apply an exact-size crop." }
        if enteredCropSize == nil { return "Enter a positive whole number for width and height." }
        if validCustomCropSize == nil { return "Maximum size: \(renderer.image.width) × \(renderer.image.height) px." }
        return nil
    }

    var canApplyCrop: Bool {
        guard let rect = pendingCrop, cropProblem == nil else { return false }
        let pixels = cropPixelSize(of: rect)
        return pixels.width > 0 && pixels.height > 0
    }

    func selectCropFormat(_ format: CropFormat) {
        guard format != cropFormat else { return }
        let rect = pendingCrop ?? fullImage
        let pixels = cropPixelSize(of: rect)
        // Seed the fields from the selection when first switching to Custom.
        if format == .custom, cropWidth.isEmpty, cropHeight.isEmpty {
            cropWidth = String(max(1, pixels.width))
            cropHeight = String(max(1, pixels.height))
        }
        cropFormat = format
        if let ratio = format.ratio {
            let fitted = CropGeometry.fit(ratio, inside: rect)
            let size = cropPixelSize(of: fitted)
            pendingCrop = size.width > 0 && size.height > 0 ? fitted : CropGeometry.fit(ratio, inside: fullImage)
        } else if format == .custom {
            previewCustomCrop()
        }
    }

    private func previewCustomCrop() {
        guard tool == .crop, cropFormat == .custom, let size = validCustomCropSize else { return }
        let rect = pendingCrop ?? fullImage
        let scale = pixelsPerPoint
        let origin = CGPoint(x: rect.midX - CGFloat(size.width) / scale.width / 2,
                             y: rect.midY - CGFloat(size.height) / scale.height / 2)
        pendingCrop = customRect(size, at: origin)
    }

    private func customRect(_ size: CropPixelSize, at origin: CGPoint) -> CGRect {
        let scale = pixelsPerPoint
        let x = min(max(0, (origin.x * scale.width).rounded()), CGFloat(renderer.image.width - size.width))
        let y = min(max(0, (origin.y * scale.height).rounded()), CGFloat(renderer.image.height - size.height))
        return CGRect(x: x / scale.width, y: y / scale.height,
                      width: CGFloat(size.width) / scale.width, height: CGFloat(size.height) / scale.height)
    }

    func moveCrop(to origin: CGPoint) {
        guard let rect = pendingCrop else { return }
        if cropFormat == .custom {
            guard let size = validCustomCropSize else { return }
            pendingCrop = customRect(size, at: origin)
        } else {
            pendingCrop = CropGeometry.positioned(rect.size, at: origin, in: document.imageSize)
        }
    }

    func applyCrop() {
        guard canApplyCrop, let rect = pendingCrop else { return }
        let exact = cropFormat == .custom ? validCustomCropSize : nil
        let full = fullImage
        let freeform = cropFormat == .freeform
        let clipped = freeform ? rect.intersection(full).integral : rect
        let clearsCrop = exact == nil && (clipped == full || (freeform && (clipped.width < 4 || clipped.height < 4)))
        mutate("Crop") {
            $0.crop = clearsCrop ? nil : clipped
            $0.exactCropSize = exact
        }
        tool = .select
    }

    func resetCrop() {
        cropFormat = .freeform
        cropWidth = ""
        cropHeight = ""
        pendingCrop = fullImage
    }

    func cancelCrop() {
        tool = .select
    }

    func setBackground(_ change: (inout BackgroundSettings) -> Void) {
        var background = document.background
        change(&background)
        if background.enabled, document.exactCropSize != nil {
            errorMessage = "To add a Background, first switch Crop to Freeform or a preset and apply it."
            return
        }
        mutate("Background") { $0.background = background }
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
