import AppKit
import Observation
import ServiceManagement

enum AppInfo {
    /// Notifications, the Keychain and the updater need the real bundle (Info.plist, stable code identity).
    static var isRunningFromBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }

    static let draftsFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("io.github.nickpagz.proof/Drafts", isDirectory: true)
    }()
}

/// Owns preferences and runs every capture from trigger to Quick Access thumbnail.
@MainActor @Observable
final class AppState {
    var prefs: Preferences {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            applyPreferences(changedFrom: oldValue)
        }
    }

    let updates = UpdateController()
    let sharing = SharingController()
    var settingsTab: SettingsTab = .general
    @ObservationIgnored let quickAccess = QuickAccessController()
    private(set) var isCapturing = false
    /// Actions whose shortcut another app or macOS already owns.
    private(set) var shortcutConflicts: Set<HotKeyAction> = []
    /// Set while a shortcut field is recording, so the old shortcut doesn't fire instead.
    var isRecordingShortcut = false { didSet { isRecordingShortcut ? HotKeyCenter.shared.unregisterAll() : registerHotKeys() } }

    @ObservationIgnored private var editors: [EditorWindowController] = []
    /// The Quick Access thumbnail each editor came from, so saving an edit updates it.
    @ObservationIgnored private var editorItems: [ObjectIdentifier: QuickAccessItem] = [:]
    /// Editors opened on a capture Proof saved write back to that file; others save a new one.
    @ObservationIgnored private var editorOwnsFile: Set<ObjectIdentifier> = []

    @ObservationIgnored var onMenuNeedsUpdate: (() -> Void)?
    @ObservationIgnored var openSettingsHandler: (() -> Void)?

    init() {
        prefs = Preferences.load()
        quickAccess.delegate = self
        sharing.prefs = { [weak self] in self?.prefs ?? Preferences() }
        sharing.openSharingSettings = { [weak self] in self?.settingsTab = .sharing; self?.openSettings() }
        applyQuickAccessPreferences()
        updates.isAppBusy = { [weak self] in self?.isCapturing ?? false }
        updates.automaticChecksEnabled = { [weak self] in self?.prefs.checkForUpdatesAutomatically ?? true }
        Notifier.openUpdatesHandler = { [weak self] in self?.openSettings() }
        HotKeyCenter.shared.handler = { [weak self] action in self?.perform(action) }
    }

    func start() {
        registerHotKeys()
        updates.start()
    }

    func openSettings() { openSettingsHandler?() }

    // MARK: Preferences side effects

    private func applyPreferences(changedFrom old: Preferences) {
        if prefs.shortcuts != old.shortcuts { registerHotKeys() }
        if prefs.launchAtLogin != old.launchAtLogin { applyLaunchAtLogin() }
        applyQuickAccessPreferences()
        onMenuNeedsUpdate?()
    }

    private func applyQuickAccessPreferences() {
        quickAccess.position = prefs.quickAccessPosition
        quickAccess.autoCloseSeconds = prefs.quickAccessAutoCloseSeconds
        quickAccess.closeAfterDrag = prefs.quickAccessCloseAfterDrag
    }

    func registerHotKeys() {
        guard !isRecordingShortcut else { return }
        var bindings: [HotKeyAction: Shortcut] = [:]
        for action in HotKeyAction.allCases {
            if let shortcut = prefs.shortcut(for: action) { bindings[action] = shortcut }
        }
        HotKeyCenter.shared.register(bindings)
        shortcutConflicts = HotKeyCenter.shared.conflicts
        onMenuNeedsUpdate?()
    }

    private func applyLaunchAtLogin() {
        do {
            if prefs.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.note("launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: Actions

    func perform(_ action: HotKeyAction) {
        switch action {
        case .allInOne: Task { await runOverlay(startMode: .area, allInOne: true) }
        case .captureArea: Task { await runOverlay(startMode: .area, allInOne: false) }
        case .captureWindow: Task { await runOverlay(startMode: .window, allInOne: false) }
        case .captureFullscreen: Task { await captureFullscreen(displayID: ScreenGeometry.displayID(of: ScreenGeometry.screenUnderMouse)) }
        case .capturePreviousArea: Task { await capturePreviousArea() }
        case .selfTimer: Task { await runOverlay(startMode: .area, allInOne: false, timer: true) }
        case .toggleDesktopIcons: prefs.hideDesktopIcons.toggle()
        case .restoreLastCapture: quickAccess.restoreRecentlyClosed()
        }
    }

    /// False (after explaining) when Screen Recording isn't allowed yet.
    private func ensurePermission() -> Bool {
        if Permissions.screenRecordingGranted() { return true }
        Permissions.requestScreenRecording()
        let alert = NSAlert()
        alert.messageText = "Proof needs Screen Recording permission"
        alert.informativeText = "Allow Proof in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Proof."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Permissions.openSystemSettings(.screenRecording) }
        return false
    }

    func runOverlay(startMode: SelectionOverlay.Mode, allInOne: Bool, timer: Bool = false) async {
        guard !isCapturing, ensurePermission() else { return }
        isCapturing = true
        defer { isCapturing = false }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let appName = previousApp?.localizedName

        var options = SelectionOverlay.Options()
        options.startMode = startMode
        options.allInOne = allInOne
        options.showMagnifier = prefs.showMagnifier
        options.showCrosshair = prefs.showCrosshair
        options.hideDesktopIcons = prefs.hideDesktopIcons
        options.hasPreviousArea = prefs.previousArea != nil
        if allInOne { options.initialSelection = prefs.previousArea }
        let overlay = SelectionOverlay(options: options)
        let result = await overlay.run()
        // Hand focus back to the app being captured, unless the capture opened in the editor.
        defer { if !prefs.capturesOpenEditor { previousApp?.activate() } }

        switch result {
        case .cancelled:
            return
        case .area(let rect):
            prefs.previousArea = rect
            if timer {
                guard await CountdownHUD.run(seconds: prefs.selfTimerSeconds) else { return }
                await captureArea(rect, appName: appName, frozen: nil)
            } else {
                await captureArea(rect, appName: appName, frozen: prefs.freezeScreen ? overlay : nil)
            }
        case .selfTimer(let rect):
            prefs.previousArea = rect
            guard await CountdownHUD.run(seconds: prefs.selfTimerSeconds) else { return }
            await captureArea(rect, appName: appName, frozen: nil)
        case .window(let window):
            await captureWindow(window)
        case .fullscreen(let displayID):
            await captureFullscreen(displayID: displayID, alreadyCapturing: true)
        case .previousArea:
            if let rect = prefs.previousArea { await captureArea(rect, appName: appName, frozen: nil) }
        }
    }

    func capturePreviousArea() async {
        guard let rect = prefs.previousArea else {
            await runOverlay(startMode: .area, allInOne: false)
            return
        }
        guard !isCapturing, ensurePermission() else { return }
        isCapturing = true
        defer { isCapturing = false }
        await captureArea(rect, appName: ScreenGrabber.frontmostAppName, frozen: nil)
    }

    func captureFullscreen(displayID: CGDirectDisplayID, alreadyCapturing: Bool = false) async {
        if !alreadyCapturing {
            guard !isCapturing, ensurePermission() else { return }
            isCapturing = true
        }
        defer { if !alreadyCapturing { isCapturing = false } }
        let bounds = CGDisplayBounds(displayID)
        do {
            let image = try await ScreenGrabber.capture(displayID: displayID, hideDesktopIcons: prefs.hideDesktopIcons)
            finish(Capture(image: image, pointSize: bounds.size, kind: .fullscreen, appName: ScreenGrabber.frontmostAppName, date: Date()))
        } catch {
            report(error)
        }
    }

    private func captureArea(_ rect: CGRect, appName: String?, frozen overlay: SelectionOverlay?) async {
        do {
            let image: CGImage
            if let overlay, let displayID = ScreenGeometry.displayID(containing: rect),
               let snapshot = overlay.snapshot(for: displayID), let cropped = Self.crop(snapshot, displayID: displayID, to: rect) {
                image = cropped
            } else {
                image = try await ScreenGrabber.capture(rect: rect, hideDesktopIcons: prefs.hideDesktopIcons)
            }
            finish(Capture(image: image, pointSize: rect.size, kind: .area, appName: appName, date: Date()))
        } catch {
            report(error)
        }
    }

    private func captureWindow(_ window: PickableWindow) async {
        do {
            let (image, size) = try await ScreenGrabber.capture(windowID: window.id, shadow: prefs.windowBackground == .shadow)
            finish(Capture(image: image, pointSize: size, kind: .window, appName: window.ownerName, date: Date()))
        } catch {
            report(error)
        }
    }

    nonisolated static func crop(_ snapshot: CGImage, displayID: CGDirectDisplayID, to rect: CGRect) -> CGImage? {
        let bounds = CGDisplayBounds(displayID)
        let scale = CGFloat(snapshot.width) / bounds.width
        let local = rect.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let pixels = CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale).integral
        return snapshot.cropping(to: pixels)
    }

    // MARK: After capture

    private func finish(_ capture: Capture) {
        if prefs.playSound { ShutterSound.play() }
        if prefs.afterCapture == .editor {
            Log.note("captured \(capture.kind.rawValue) \(capture.image.width)x\(capture.image.height) → editor")
            // The item isn't shown; it carries the capture so Save as… can name it.
            openEditor(for: QuickAccessItem(capture: capture, savedURL: nil))
            return
        }
        var savedURL: URL?
        if prefs.saveAfterCapture {
            savedURL = save(capture)
        }
        if prefs.copyAfterCapture {
            ImageExporter.copyToClipboard(capture.image, pointSize: capture.pointSize, file: savedURL)
        }
        Log.note("captured \(capture.kind.rawValue) \(capture.image.width)x\(capture.image.height)\(savedURL.map { " → \($0.path)" } ?? "")")
        let item = QuickAccessItem(capture: capture, savedURL: savedURL)
        if prefs.showQuickAccess {
            quickAccess.show(item)
        }
        if prefs.openEditorAfterCapture {
            openEditor(for: item)
        } else if !prefs.showQuickAccess && !prefs.saveAfterCapture && !prefs.copyAfterCapture {
            // Nothing else would keep the capture; don't lose it.
            ImageExporter.copyToClipboard(capture.image, pointSize: capture.pointSize, file: nil)
        }
    }

    func fileName(for capture: Capture) -> String {
        FileNaming.name(template: prefs.fileNameTemplate, date: capture.date, appName: capture.appName, kind: capture.kind)
    }

    @discardableResult
    func save(_ capture: Capture) -> URL? {
        let url = FileNaming.uniqueURL(in: prefs.saveFolder, name: fileName(for: capture), ext: prefs.format.fileExtension)
        do {
            try ImageExporter.write(capture.image, pointSize: capture.pointSize, to: url, options: ImageExporter.Options(prefs))
            return url
        } catch {
            report(error)
            return nil
        }
    }

    private func report(_ error: Error) {
        Log.note("capture failed: \(error.localizedDescription)")
        if case CaptureError.permissionDenied = error {
            _ = ensurePermission()
            return
        }
        Notifier.shared.notify(title: "Capture failed", body: error.localizedDescription)
    }
}

extension AppState: QuickAccessDelegate {
    func quickAccessCopy(_ item: QuickAccessItem) {
        ImageExporter.copyToClipboard(item.capture.image, pointSize: item.capture.pointSize, file: item.savedURL)
    }

    func quickAccessSave(_ item: QuickAccessItem) {
        guard item.savedURL == nil else { return }
        item.savedURL = save(item.capture)
    }

    func quickAccessReveal(_ item: QuickAccessItem) {
        guard let url = item.savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func quickAccessOpen(_ item: QuickAccessItem) {
        openEditor(for: item)
    }

    func quickAccessAnnotate(_ item: QuickAccessItem) {
        openEditor(for: item)
    }

    func quickAccessFileForDrag(_ item: QuickAccessItem) -> URL? {
        if let url = item.fileURL { return url }
        let folder = AppInfo.draftsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(fileName(for: item.capture)).appendingPathExtension(prefs.format.fileExtension)
        do {
            try ImageExporter.write(item.capture.image, pointSize: item.capture.pointSize, to: url, options: ImageExporter.Options(prefs))
            item.draftURL = url
            return url
        } catch {
            report(error)
            return nil
        }
    }
}

// MARK: - Editor

extension AppState: EditorDelegate {
    func openEditor(for item: QuickAccessItem) {
        if let existing = editors.first(where: { editorItems[ObjectIdentifier($0.model)] === item }) {
            existing.show()
            return
        }
        let capture = item.capture
        let model = EditorModel(image: capture.image, pointSize: capture.pointSize, fileURL: item.savedURL,
                                title: item.savedURL?.deletingPathExtension().lastPathComponent ?? fileName(for: capture),
                                capturedAt: capture.date, appName: capture.appName)
        editorItems[ObjectIdentifier(model)] = item
        if item.savedURL != nil {
            editorOwnsFile.insert(ObjectIdentifier(model))
            model.markHandled()
        }
        model.confirmsUnsavedClose = prefs.confirmUnsavedClose
        model.closesAfterSave = prefs.closeEditorAfterSave
        present(model)
    }

    /// "Open…": any image file. Its pixels-per-point come from the file's DPI.
    func openEditor(file url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Notifier.shared.notify(title: "Can't open \(url.lastPathComponent)", body: "It isn't an image Proof can read.")
            return
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let scale = max(1, (dpi / 72).rounded())
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let model = EditorModel(image: image, pointSize: size, fileURL: url, title: url.deletingPathExtension().lastPathComponent)
        model.markHandled()
        model.confirmsUnsavedClose = prefs.confirmUnsavedClose
        model.closesAfterSave = prefs.closeEditorAfterSave
        present(model)
    }

    func chooseFileToEdit() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { openEditor(file: url) }
    }

    /// The most recently opened editor, for UI tests.
    var lastEditorModel: EditorModel? { editors.last?.model }

    private func present(_ model: EditorModel) {
        model.delegate = self
        let controller = EditorWindowController(model: model)
        editors.append(controller)
        controller.show()
    }

    func editorSave(_ editor: EditorModel, image: CGImage, pointSize: CGSize) -> URL? {
        let url: URL
        if let file = editor.fileURL, editorOwnsFile.contains(ObjectIdentifier(editor)) {
            url = file
        } else if let item = editorItems[ObjectIdentifier(editor)], editor.fileURL == nil {
            // A capture that was never saved gets its usual name.
            url = FileNaming.uniqueURL(in: prefs.saveFolder, name: fileName(for: item.capture), ext: prefs.format.fileExtension)
        } else {
            // Never overwrite a file Proof didn't make; save the edit next to the captures.
            let base = editor.fileURL?.deletingPathExtension().lastPathComponent ?? editor.title
            url = FileNaming.uniqueURL(in: prefs.saveFolder, name: FileNaming.sanitize(base + " (edited)"), ext: prefs.format.fileExtension)
        }
        return write(editor, image: image, pointSize: pointSize, to: url)
    }

    func editorSaveAs(_ editor: EditorModel, image: CGImage, pointSize: CGSize) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.directoryURL = editor.fileURL?.deletingLastPathComponent() ?? prefs.saveFolder
        panel.nameFieldStringValue = (editor.fileURL?.deletingPathExtension().lastPathComponent ?? editor.title) + "." + prefs.format.fileExtension
        // The extension picks the format, so keep it visible and editable.
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return write(editor, image: image, pointSize: pointSize, to: url)
    }

    private func write(_ editor: EditorModel, image: CGImage, pointSize: CGSize, to url: URL) -> URL? {
        do {
            try ImageExporter.write(image, pointSize: pointSize, to: url, options: ImageExporter.Options(prefs))
        } catch {
            report(error)
            return nil
        }
        let id = ObjectIdentifier(editor)
        editorOwnsFile.insert(id)
        if let item = editorItems[id] {
            item.capture = Capture(image: image, pointSize: pointSize, kind: item.capture.kind, appName: item.capture.appName, date: item.capture.date)
            item.savedURL = url
            item.draftURL = nil
            quickAccess.refresh(item)
        }
        Log.note("editor saved \(url.path)")
        return url
    }

    func editorShare(_ editor: EditorModel, image: CGImage, pointSize: CGSize, visibility: ShareVisibility) {
        sharing.share(image, pointSize: pointSize, from: editor, visibility: visibility)
    }

    func editorCanShare(_ visibility: ShareVisibility) -> Bool { prefs.destination(for: visibility) != nil }

    func editorShareService(_ visibility: ShareVisibility) -> String? { prefs.destination(for: visibility)?.label }

    func editorShareHelp(_ visibility: ShareVisibility) -> String {
        guard let provider = sharing.provider(for: visibility) else { return "" }
        guard provider.isReady else { return "Sign in to \(provider.kind.label) in Settings → Sharing" }
        let place = provider.destinationLabel.map { " (\($0))" } ?? ""
        return "Upload to \(provider.kind.label)\(place) and copy the link"
    }

    func editorStopAskingBeforeClose() {
        prefs.confirmUnsavedClose = false
        editors.forEach { $0.model.confirmsUnsavedClose = false }
    }

    func editorDidClose(_ editor: EditorModel) {
        let id = ObjectIdentifier(editor)
        editors.removeAll { $0.model === editor }
        editorItems[id] = nil
        editorOwnsFile.remove(id)
        // Back to a menu bar app once no editor is open.
        if editors.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
