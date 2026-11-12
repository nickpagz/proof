import Foundation

enum ImageFormat: String, CaseIterable, Codable, Identifiable {
    case png, jpeg, heic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        }
    }
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
}

/// What happens right after a capture.
enum AfterCaptureFlow: String, CaseIterable, Codable, Identifiable {
    /// Straight into the editor; nothing is saved until Save as….
    case editor
    /// Saved (or copied) and shown as a Quick Access thumbnail, per the toggles below it.
    case quickAccess
    var id: String { rawValue }
    var label: String {
        switch self {
        case .editor: return "Open it in the editor"
        case .quickAccess: return "Save it and show a thumbnail"
        }
    }
}

/// The service behind a Share button, or none to hide that button's job.
enum ShareDestination: String, CaseIterable, Codable, Identifiable {
    case none, cloudup, wordpress
    var id: String { rawValue }
    var provider: ProviderKind? { ProviderKind(rawValue: rawValue) }
    var label: String { provider?.label ?? "None" }
}

/// What the recording window saves, copies, drags and shares.
enum VideoFormat: String, CaseIterable, Codable, Identifiable {
    case mp4, gif
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
    var mimeType: String { self == .mp4 ? "video/mp4" : "image/gif" }
}

enum GIFSize: String, CaseIterable, Codable, Identifiable {
    case small, medium, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return "Small (640 px wide)"
        case .medium: return "Medium (960 px wide)"
        case .full: return "Full size"
        }
    }
    /// Widest the GIF gets, in pixels; nil keeps the recording's size.
    var maxWidth: Int? {
        switch self {
        case .small: return 640
        case .medium: return 960
        case .full: return nil
        }
    }
}

enum QuickAccessPosition: String, CaseIterable, Codable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum WindowBackground: String, CaseIterable, Codable, Identifiable {
    /// The window and its shadow on a transparent background, like macOS's own window capture.
    case shadow
    /// The window alone, transparent corners, no shadow.
    case transparent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shadow: return "With shadow"
        case .transparent: return "Without shadow"
        }
    }
}

struct Preferences: Codable, Equatable {
    // Saving
    var saveFolderPath: String = Preferences.defaultSaveFolder.path
    var fileNameTemplate: String = FileNaming.defaultTemplate
    var format: ImageFormat = .png
    var jpegQuality: Double = 0.9
    var scaleRetinaTo1x: Bool = false
    var convertToSRGB: Bool = true

    // After capture
    var afterCapture: AfterCaptureFlow = .editor
    /// Ask before closing an editor whose result was never saved, copied or shared.
    var confirmUnsavedClose: Bool = true
    var closeEditorAfterSave: Bool = true
    var showQuickAccess: Bool = true
    var saveAfterCapture: Bool = true
    var copyAfterCapture: Bool = false
    var openEditorAfterCapture: Bool = false

    // Capture
    var hideDesktopIcons: Bool = true
    var freezeScreen: Bool = false
    var showMagnifier: Bool = true
    var showCrosshair: Bool = true
    var windowBackground: WindowBackground = .shadow
    var playSound: Bool = true
    var selfTimerSeconds: Int = 5

    // Recording. The microphone and computer audio can also be switched on the recording bar,
    // which keeps the choice for next time.
    var recordMicrophone: Bool = false
    /// nil follows the system's default input.
    var microphoneDeviceID: String?
    var recordSystemAudio: Bool = false
    var highlightClicks: Bool = true
    var showCursorInRecordings: Bool = true
    var recordingCountdown: Bool = true
    var recordingFrameRate: Int = 30
    /// Off records one pixel per point, which keeps files a quarter the size.
    var recordAtFullResolution: Bool = false
    var videoFormat: VideoFormat = .mp4
    var gifSize: GIFSize = .medium

    // Quick Access Overlay
    var quickAccessPosition: QuickAccessPosition = .left
    /// 0 keeps the thumbnail until it is closed.
    var quickAccessAutoCloseSeconds: Int = 0
    var quickAccessCloseAfterDrag: Bool = true

    // Shortcuts, keyed by `HotKeyAction.rawValue`. A missing key means the action's default; an
    // explicit `nil` shortcut (stored as an empty record) means the user cleared it.
    var shortcuts: [String: Shortcut?] = [:]

    // Sharing: which service fills each editor button, and what happens after an upload.
    var privateDestination: ShareDestination = .cloudup
    var publicDestination: ShareDestination = .wordpress
    var copyLinkAfterShare: Bool = true
    /// Upload to WordPress.com under a random file name, so the link doesn't give away the
    /// capture's name. The media title keeps the real one.
    var wordpressRandomFileNames: Bool = true

    var launchAtLogin: Bool = false
    var checkForUpdatesAutomatically: Bool = true

    /// The last area captured, in global CoreGraphics points (origin top-left of the main display).
    var previousArea: CGRect?

    static let defaultSaveFolder: URL =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    var saveFolder: URL { URL(fileURLWithPath: saveFolderPath, isDirectory: true) }

    func destination(for visibility: ShareVisibility) -> ProviderKind? {
        (visibility == .private ? privateDestination : publicDestination).provider
    }

    /// True when a capture ends up in the editor window.
    var capturesOpenEditor: Bool { afterCapture == .editor || openEditorAfterCapture }

    func shortcut(for action: HotKeyAction) -> Shortcut? {
        if let stored = shortcuts[action.rawValue] { return stored }
        return action.defaultShortcut
    }

    enum CodingKeys: String, CodingKey {
        case saveFolderPath, fileNameTemplate, format, jpegQuality, scaleRetinaTo1x, convertToSRGB
        case afterCapture, confirmUnsavedClose, closeEditorAfterSave, showQuickAccess, saveAfterCapture, copyAfterCapture, openEditorAfterCapture
        case hideDesktopIcons, freezeScreen, showMagnifier, showCrosshair, windowBackground, playSound, selfTimerSeconds
        case recordMicrophone, microphoneDeviceID, recordSystemAudio, highlightClicks, showCursorInRecordings
        case recordingCountdown, recordingFrameRate, recordAtFullResolution, videoFormat, gifSize
        case quickAccessPosition, quickAccessAutoCloseSeconds, quickAccessCloseAfterDrag
        case privateDestination, publicDestination, copyLinkAfterShare, wordpressRandomFileNames
        case shortcuts, launchAtLogin, checkForUpdatesAutomatically, previousArea
    }

    init() {}

    // Decode field by field so preferences saved by an older build still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        saveFolderPath = try c.decodeIfPresent(String.self, forKey: .saveFolderPath) ?? d.saveFolderPath
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? d.fileNameTemplate
        format = try c.decodeIfPresent(ImageFormat.self, forKey: .format) ?? d.format
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? d.jpegQuality
        scaleRetinaTo1x = try c.decodeIfPresent(Bool.self, forKey: .scaleRetinaTo1x) ?? d.scaleRetinaTo1x
        convertToSRGB = try c.decodeIfPresent(Bool.self, forKey: .convertToSRGB) ?? d.convertToSRGB
        afterCapture = try c.decodeIfPresent(AfterCaptureFlow.self, forKey: .afterCapture) ?? d.afterCapture
        confirmUnsavedClose = try c.decodeIfPresent(Bool.self, forKey: .confirmUnsavedClose) ?? d.confirmUnsavedClose
        closeEditorAfterSave = try c.decodeIfPresent(Bool.self, forKey: .closeEditorAfterSave) ?? d.closeEditorAfterSave
        showQuickAccess = try c.decodeIfPresent(Bool.self, forKey: .showQuickAccess) ?? d.showQuickAccess
        saveAfterCapture = try c.decodeIfPresent(Bool.self, forKey: .saveAfterCapture) ?? d.saveAfterCapture
        copyAfterCapture = try c.decodeIfPresent(Bool.self, forKey: .copyAfterCapture) ?? d.copyAfterCapture
        openEditorAfterCapture = try c.decodeIfPresent(Bool.self, forKey: .openEditorAfterCapture) ?? d.openEditorAfterCapture
        hideDesktopIcons = try c.decodeIfPresent(Bool.self, forKey: .hideDesktopIcons) ?? d.hideDesktopIcons
        freezeScreen = try c.decodeIfPresent(Bool.self, forKey: .freezeScreen) ?? d.freezeScreen
        showMagnifier = try c.decodeIfPresent(Bool.self, forKey: .showMagnifier) ?? d.showMagnifier
        showCrosshair = try c.decodeIfPresent(Bool.self, forKey: .showCrosshair) ?? d.showCrosshair
        windowBackground = try c.decodeIfPresent(WindowBackground.self, forKey: .windowBackground) ?? d.windowBackground
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? d.playSound
        selfTimerSeconds = try c.decodeIfPresent(Int.self, forKey: .selfTimerSeconds) ?? d.selfTimerSeconds
        recordMicrophone = try c.decodeIfPresent(Bool.self, forKey: .recordMicrophone) ?? d.recordMicrophone
        microphoneDeviceID = try c.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        recordSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .recordSystemAudio) ?? d.recordSystemAudio
        highlightClicks = try c.decodeIfPresent(Bool.self, forKey: .highlightClicks) ?? d.highlightClicks
        showCursorInRecordings = try c.decodeIfPresent(Bool.self, forKey: .showCursorInRecordings) ?? d.showCursorInRecordings
        recordingCountdown = try c.decodeIfPresent(Bool.self, forKey: .recordingCountdown) ?? d.recordingCountdown
        recordingFrameRate = try c.decodeIfPresent(Int.self, forKey: .recordingFrameRate) ?? d.recordingFrameRate
        recordAtFullResolution = try c.decodeIfPresent(Bool.self, forKey: .recordAtFullResolution) ?? d.recordAtFullResolution
        videoFormat = try c.decodeIfPresent(VideoFormat.self, forKey: .videoFormat) ?? d.videoFormat
        gifSize = try c.decodeIfPresent(GIFSize.self, forKey: .gifSize) ?? d.gifSize
        quickAccessPosition = try c.decodeIfPresent(QuickAccessPosition.self, forKey: .quickAccessPosition) ?? d.quickAccessPosition
        quickAccessAutoCloseSeconds = try c.decodeIfPresent(Int.self, forKey: .quickAccessAutoCloseSeconds) ?? d.quickAccessAutoCloseSeconds
        quickAccessCloseAfterDrag = try c.decodeIfPresent(Bool.self, forKey: .quickAccessCloseAfterDrag) ?? d.quickAccessCloseAfterDrag
        privateDestination = try c.decodeIfPresent(ShareDestination.self, forKey: .privateDestination) ?? d.privateDestination
        publicDestination = try c.decodeIfPresent(ShareDestination.self, forKey: .publicDestination) ?? d.publicDestination
        copyLinkAfterShare = try c.decodeIfPresent(Bool.self, forKey: .copyLinkAfterShare) ?? d.copyLinkAfterShare
        wordpressRandomFileNames = try c.decodeIfPresent(Bool.self, forKey: .wordpressRandomFileNames) ?? d.wordpressRandomFileNames
        shortcuts = try c.decodeIfPresent([String: Shortcut?].self, forKey: .shortcuts) ?? d.shortcuts
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        checkForUpdatesAutomatically = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdatesAutomatically) ?? d.checkForUpdatesAutomatically
        previousArea = try c.decodeIfPresent(CGRect.self, forKey: .previousArea)
    }

    private static let defaultsKey = "preferences.v1"

    static func load() -> Preferences {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let prefs = try? JSONDecoder().decode(Preferences.self, from: data) {
            return prefs
        }
        return Preferences()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Preferences.defaultsKey)
        }
    }
}
