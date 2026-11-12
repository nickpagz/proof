import AVFoundation
import AVKit
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the recording window asks the app to do with the finished file.
@MainActor
protocol VideoDelegate: AnyObject {
    /// Writes `file` over the recording's saved copy and returns where it went, or nil after reporting a failure.
    func videoSave(_ video: VideoModel, file: URL) -> URL?
    func videoSaveAs(_ video: VideoModel, file: URL) -> URL?
    func videoShare(_ video: VideoModel, file: URL, visibility: ShareVisibility)
    func videoCanShare(_ visibility: ShareVisibility) -> Bool
    func videoShareService(_ visibility: ShareVisibility) -> String?
    func videoShareHelp(_ visibility: ShareVisibility) -> String
    func videoFormatChanged(_ format: VideoFormat)
    func videoStopAskingBeforeClose()
    func videoDidClose(_ video: VideoModel)
}

/// State of one recording window: the format and trim chosen, and the files made from them.
@MainActor @Observable
final class VideoModel: ShareSink {
    let video: RecordedVideo
    var format: VideoFormat {
        didSet {
            guard format != oldValue else { return }
            handled = false
            delegate?.videoFormatChanged(format)
            prepareOutput()
        }
    }
    /// The part to keep; nil keeps all of it.
    private(set) var trim: CMTimeRange?
    /// Where Save last wrote.
    var fileURL: URL?
    var statusMessage: String?
    /// "Making GIF… 40%" while the file for the chosen format and trim is being made.
    private(set) var preparing: String?
    var uploadProgress: Double?
    var uploadLabel = ""
    var errorMessage: String?
    var shareConfirmation: ShareConfirmation?
    var isUploading: Bool { uploadProgress != nil }

    @ObservationIgnored weak var delegate: VideoDelegate?
    @ObservationIgnored var gifMaxWidth: Int?
    @ObservationIgnored var confirmsUnsavedClose = true
    @ObservationIgnored var closesAfterSave = true
    @ObservationIgnored var onRequestClose: (() -> Void)?
    @ObservationIgnored var onBeginTrim: (() -> Void)?

    @ObservationIgnored private var handled = false
    @ObservationIgnored private var outputs: [OutputKey: URL] = [:]
    @ObservationIgnored private var making: [OutputKey: Task<URL, Error>] = [:]

    private struct OutputKey: Hashable {
        let format: VideoFormat
        let start: Double?
        let end: Double?
    }

    init(video: RecordedVideo, format: VideoFormat) {
        self.video = video
        self.format = format
        outputs[OutputKey(format: .mp4, start: nil, end: nil)] = video.url
    }

    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? video.title }
    /// A recording that was never saved can only be saved with a name and place.
    var needsSaveAs: Bool { fileURL == nil }
    /// True when closing would lose a recording nobody has kept anywhere.
    var hasUnhandledChanges: Bool { !handled }
    func markHandled() { handled = true }

    private var currentKey: OutputKey {
        OutputKey(format: format, start: trim?.start.seconds, end: trim?.end.seconds)
    }

    /// The file for the current format and trim, when it is already made.
    var readyOutput: URL? { outputs[currentKey] }

    var lengthLabel: String {
        let seconds = trim?.duration.seconds ?? video.duration
        let total = max(0, Int(seconds.rounded()))
        let text = String(format: "%d:%02d", total / 60, total % 60)
        return trim == nil ? text : "\(text) (trimmed)"
    }

    // MARK: Output

    /// Makes (or reuses) the file for the current format and trim.
    func output() async throws -> URL {
        let key = currentKey
        if let url = outputs[key] { return url }
        if let task = making[key] { return try await task.value }
        let task = Task { try await self.make(key) }
        making[key] = task
        defer { making[key] = nil }
        let url = try await task.value
        outputs[key] = url
        return url
    }

    func prepareOutput() {
        guard readyOutput == nil else { return }
        Task { _ = try? await output() }
    }

    private func make(_ key: OutputKey) async throws -> URL {
        let folder = AppInfo.draftsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(video.title).appendingPathExtension(key.format.fileExtension)
        let range = trim
        defer { preparing = nil }
        switch key.format {
        case .mp4:
            guard let range else { return video.url }
            preparing = "Trimming…"
            try await VideoExport.trimmedMP4(from: video.url, range: range, to: url)
        case .gif:
            preparing = "Making GIF…"
            try await VideoExport.gif(from: video.url, range: range, maxWidth: gifMaxWidth, to: url) { fraction in
                Task { @MainActor [weak self] in
                    if self?.preparing != nil { self?.preparing = "Making GIF… \(Int(fraction * 100))%" }
                }
            }
        }
        return url
    }

    /// Runs `body` with the finished file, reporting a failure to make it.
    private func withOutput(_ body: @escaping (URL) -> Void) {
        Task {
            do {
                body(try await output())
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    // MARK: Actions

    func beginTrim() { onBeginTrim?() }

    func setTrim(start: CMTime, end: CMTime) {
        let range = CMTimeRange(start: start, end: end)
        let whole = start.seconds <= 0.01 && end.seconds >= video.duration - 0.01
        let newTrim = whole || range.duration.seconds <= 0 ? nil : range
        guard newTrim != trim else { return }
        trim = newTrim
        handled = false
        prepareOutput()
    }

    func save() {
        if needsSaveAs { return saveAs() }
        withOutput { [weak self] url in
            guard let self, let saved = self.delegate?.videoSave(self, file: url) else { return }
            self.fileURL = saved
            self.didSave()
        }
    }

    func saveAs() {
        withOutput { [weak self] url in
            guard let self, let saved = self.delegate?.videoSaveAs(self, file: url) else { return }
            self.fileURL = saved
            self.didSave()
        }
    }

    private func didSave() {
        markHandled()
        if closesAfterSave { onRequestClose?() } else { flash("Saved") }
    }

    func copy() {
        withOutput { [weak self] url in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            // Chat apps and browsers paste a GIF from its data, not from a file reference.
            if url.pathExtension == "gif", let data = try? Data(contentsOf: url) {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
            }
            self?.markHandled()
            self?.flash("Copied")
        }
    }

    func share(_ visibility: ShareVisibility) {
        guard !isUploading else { return }
        withOutput { [weak self] url in
            guard let self else { return }
            self.delegate?.videoShare(self, file: url, visibility: visibility)
        }
    }

    func canShare(_ visibility: ShareVisibility) -> Bool { delegate?.videoCanShare(visibility) ?? false }
    func shareService(_ visibility: ShareVisibility) -> String? { delegate?.videoShareService(visibility) }
    func shareHelp(_ visibility: ShareVisibility) -> String { delegate?.videoShareHelp(visibility) ?? "" }

    // MARK: ShareSink

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

    func flash(_ message: String) {
        statusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.statusMessage == message { self?.statusMessage = nil }
        }
    }
}

// MARK: - Window

/// Takes the app menu's Save, Save As… and Copy (⌘S, ⇧⌘S, ⌘C) for the recording.
final class VideoWindow: NSWindow {
    weak var video: VideoModel?

    @objc func saveCapture(_ sender: Any?) { video?.save() }
    @objc func saveCaptureAs(_ sender: Any?) { video?.saveAs() }
    @objc func copy(_ sender: Any?) { video?.copy() }
}

@MainActor
final class VideoWindowController: NSWindowController, NSWindowDelegate {
    let model: VideoModel
    private let player: AVPlayer
    private let playerView = AVPlayerView()

    init(model: VideoModel) {
        self.model = model
        player = AVPlayer(url: model.video.url)
        let window = VideoWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = model.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        // Narrower would push the bar's buttons off the edge.
        window.minSize = NSSize(width: max(760, NSHostingView(rootView: VideoBottomBar(model: model)).fittingSize.width + 16), height: 360)
        window.delegate = self
        window.video = model

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        window.contentView = NSHostingView(rootView: VideoRootView(model: model, playerView: playerView))

        model.onRequestClose = { [weak self] in self?.window?.close() }
        model.onBeginTrim = { [weak self] in self?.beginTrim() }
        sizeWindowToFit()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The video at its own size when that fits, with the bar under it.
    private func sizeWindowToFit() {
        guard let window, let screen = NSScreen.main else { return }
        let size = model.video.pixelSize
        guard size.width > 0, size.height > 0 else { return }
        let maxSize = CGSize(width: screen.visibleFrame.width * 0.85, height: screen.visibleFrame.height * 0.85 - 52)
        let scale = min(1, maxSize.width / size.width, maxSize.height / size.height)
        let width = max(size.width * scale, window.minSize.width)
        window.setContentSize(NSSize(width: width, height: max(size.height * scale, 240) + 52))
    }

    /// AVPlayerView's own trim bar, as in QuickTime Player.
    private func beginTrim() {
        guard playerView.canBeginTrimming, let item = player.currentItem else { return }
        playerView.beginTrimming { [weak self] result in
            guard let self, result == .okButton else { return }
            let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : item.duration
            Task { @MainActor in self.model.setTrim(start: start, end: end) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.confirmsUnsavedClose, model.hasUnhandledChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save this recording before closing?"
        alert.informativeText = "It hasn't been saved, copied or shared, so closing loses it."
        alert.addButton(withTitle: model.needsSaveAs ? "Save As…" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            if alert.suppressionButton?.state == .on { self.model.delegate?.videoStopAskingBeforeClose() }
            switch response {
            case .alertFirstButtonReturn:
                self.model.save()
            case .alertThirdButtonReturn:
                self.model.markHandled()
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        model.delegate?.videoDidClose(model)
    }
}

// MARK: - SwiftUI

private struct VideoRootView: View {
    @Bindable var model: VideoModel
    let playerView: AVPlayerView

    var body: some View {
        VStack(spacing: 0) {
            PlayerHost(view: playerView)
            Divider()
            VideoBottomBar(model: model)
        }
        .alert("Couldn't finish that", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(model.shareConfirmation.map { $0.copied ? "\($0.service) link copied" : "Shared to \($0.service)" } ?? "",
               isPresented: Binding(get: { model.shareConfirmation != nil }, set: { _ in })) {
            if let confirmation = model.shareConfirmation, !confirmation.copied {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(confirmation.url.absoluteString, forType: .string)
                    model.confirmShare()
                }
            }
            Button("OK") { model.confirmShare() }
                .keyboardShortcut(.defaultAction)
        } message: {
            if let confirmation = model.shareConfirmation {
                Text(confirmation.copied
                     ? "The link is on your clipboard, ready to paste:\n\(confirmation.url.absoluteString)"
                     : confirmation.url.absoluteString)
            }
        }
    }
}

private struct PlayerHost: NSViewRepresentable {
    let view: AVPlayerView
    func makeNSView(context: Context) -> AVPlayerView { view }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct VideoBottomBar: View {
    @Bindable var model: VideoModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("Format", selection: $model.format) {
                ForEach(VideoFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .hoverHint("Save, copy, drag and share as MP4 or as a GIF")
            Button {
                model.beginTrim()
            } label: {
                Image(systemName: "timeline.selection").frame(width: 22, height: 18)
            }
            .hoverHint("Trim")
            Text(model.lengthLabel)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()
            if let progress = model.uploadProgress {
                VStack(spacing: 3) {
                    Text(model.uploadLabel).font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: progress).frame(width: 200)
                }
            } else if let preparing = model.preparing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(preparing).font(.callout).foregroundStyle(.secondary)
                }
            } else if let message = model.statusMessage {
                Text(message).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            } else {
                VideoDragHandle(model: model)
                    .frame(width: 120, height: 30)
                    .hoverHint("Drag the recording into any app")
            }
            Spacer()

            VideoShareSheetButton(model: model).frame(width: 34, height: 28).hoverHint("Share…")
            Button { model.copy() } label: { Image(systemName: "doc.on.doc").frame(width: 22, height: 18) }
                .hoverHint("Copy (⌘C)")
            Menu {
                Button("Save As…") { model.saveAs() }
            } label: {
                Text(model.needsSaveAs ? "Save as…" : "Save")
            } primaryAction: {
                model.save()
            }
            .menuStyle(.button)
            .fixedSize()
            .hoverHint(model.needsSaveAs ? "Choose a name and place (⌘S)" : "Save (⌘S)")
            shareButton(.private)
            shareButton(.public)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
        .disabled(model.isUploading)
    }

    private func shareButton(_ visibility: ShareVisibility) -> some View {
        let available = model.canShare(visibility)
        return Button { model.share(visibility) } label: {
            Label(model.shareService(visibility) ?? visibility.label, systemImage: "paperplane")
        }
        .disabled(!available)
        .hoverHint(available ? model.shareHelp(visibility) : "Choose a \(visibility == .private ? "private" : "public") destination in Settings → Sharing")
    }
}

/// "Drag Me": drags the recording file in the chosen format.
private struct VideoDragHandle: NSViewRepresentable {
    let model: VideoModel
    func makeNSView(context: Context) -> VideoDragHandleView { VideoDragHandleView(model: model) }
    func updateNSView(_ view: VideoDragHandleView, context: Context) {}
}

private final class VideoDragHandleView: NSView, NSDraggingSource {
    let model: VideoModel
    private var hovered = false { didSet { needsDisplay = true } }

    init(model: VideoModel) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
        NSColor.labelColor.withAlphaComponent(hovered ? 0.16 : 0.09).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let text = NSAttributedString(string: "≡  Drag Me  ≡", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with event: NSEvent) { NSCursor.closedHand.set() }
    override func mouseUp(with event: NSEvent) { window?.invalidateCursorRects(for: self) }

    override func mouseDragged(with event: NSEvent) {
        // A trimmed copy or a GIF takes a moment to make; it starts as soon as either is chosen.
        guard let url = model.readyOutput else {
            model.prepareOutput()
            return
        }
        model.markHandled()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        item.setDraggingFrame(NSRect(origin: .zero, size: icon.size), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hovered = false
        window?.invalidateCursorRects(for: self)
    }
}

/// The system share sheet (Messages, Mail, AirDrop…), anchored to its button.
private struct VideoShareSheetButton: NSViewRepresentable {
    let model: VideoModel
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .push
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor final class Coordinator: NSObject {
        let model: VideoModel
        init(model: VideoModel) { self.model = model }
        @objc func share(_ sender: NSButton) {
            guard let url = model.readyOutput else {
                model.prepareOutput()
                model.flash("Getting it ready…")
                return
            }
            model.markHandled()
            NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
