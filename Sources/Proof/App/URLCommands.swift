import AppKit

/// `proof://` links, modelled on CleanShot's URL scheme so Raycast, Alfred and Shortcuts can
/// drive captures: proof://capture-area, proof://capture-fullscreen, proof://all-in-one …
@MainActor
enum URLCommands {
    static let commands: [String: HotKeyAction] = [
        "all-in-one": .allInOne,
        "capture-area": .captureArea,
        "capture-previous-area": .capturePreviousArea,
        "capture-fullscreen": .captureFullscreen,
        "capture-window": .captureWindow,
        "self-timer": .selfTimer,
        "record-screen": .recordScreen,
        "toggle-desktop-icons": .toggleDesktopIcons,
        "restore-recently-closed": .restoreLastCapture,
    ]

    static func handle(_ url: URL, state: AppState) {
        guard url.scheme == "proof", let command = url.host else { return }
        Log.note("url command: \(url.absoluteString)")
        if command == "open-settings" {
            state.openSettings()
            return
        }
        if command == "hide-desktop-icons" { state.prefs.hideDesktopIcons = true; return }
        if command == "show-desktop-icons" { state.prefs.hideDesktopIcons = false; return }
        guard let action = commands[command] else {
            Log.note("unknown url command \(command)")
            return
        }
        state.perform(action)
    }
}
