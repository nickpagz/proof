import AppKit
import SwiftUI

@main
enum ProofMain {
    static func main() {
        CLI.runIfRequested()
        // Tooltips name the editor's tools, so show them sooner than macOS's default (about 1.5 s).
        // Milliseconds; a value set with `defaults write` still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var state: AppState!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var menuBarIcon: NSImage?
    private var recordingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ExceptionLog.install()
        try? FileManager.default.removeItem(at: AppInfo.draftsFolder)
        state = AppState()
        state.openSettingsHandler = { [weak self] in self?.showSettings() }
        state.onMenuNeedsUpdate = { [weak self] in self?.rebuildMenu() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Proof")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "Proof"
        menuBarIcon = icon
        state.onRecordingChange = { [weak self] in self?.updateRecordingIndicator() }
        rebuildMenu()
        NSApp.mainMenu = makeMainMenu()

        // UI tests leave global shortcuts, the updater and the permission prompt alone, so a test
        // run can't take shortcuts from another app that is in use.
        if UITest.isRequested {
            UITest.runIfRequested(state: state)
            return
        }
        state.start()
        if let notice = state.updates.postInstallNotice {
            Notifier.shared.notify(title: "Proof was updated", body: notice)
            state.updates.postInstallNotice = nil
        }
        if !Permissions.screenRecordingGranted() {
            // Ask once at first launch so the first capture doesn't have to.
            Permissions.requestScreenRecording()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { URLCommands.handle(url, state: state) }
    }

    // MARK: Menu

    private func rebuildMenu() {
        // The icon is a Stop button while recording; the menu comes back when it ends.
        guard !state.recorder.isRecording else { return }
        let menu = NSMenu()
        menu.delegate = self
        if state.updates.shouldOffer, let update = state.updates.availableUpdate {
            let row = NSMenuItem(title: "Proof \(update.version) is available…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
            row.target = self
            row.image = symbol("arrow.down.circle.fill")
            menu.addItem(row)
            menu.addItem(.separator())
        }
        let captureActions: [HotKeyAction] = [.allInOne, .captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer]
        for action in captureActions {
            menu.addItem(item(for: action))
        }
        menu.addItem(.separator())
        menu.addItem(item(for: .recordScreen))
        menu.addItem(.separator())
        let icons = NSMenuItem(title: state.prefs.hideDesktopIcons ? "Show Desktop Icons in Captures" : "Hide Desktop Icons in Captures",
                               action: #selector(toggleDesktopIcons), keyEquivalent: "")
        icons.target = self
        icons.image = symbol(state.prefs.hideDesktopIcons ? "eye" : "eye.slash")
        menu.addItem(icons)
        menu.addItem(.separator())
        let restore = item(for: .restoreLastCapture)
        restore.isEnabled = state.quickAccess.hasRecentlyClosed
        menu.addItem(restore)
        let open = NSMenuItem(title: "Open…", action: #selector(openFile), keyEquivalent: "")
        open.target = self
        open.image = symbol("pencil.and.outline")
        menu.addItem(open)
        let folder = NSMenuItem(title: "Open Captures Folder", action: #selector(openCapturesFolder), keyEquivalent: "")
        folder.target = self
        folder.image = symbol("folder")
        menu.addItem(folder)
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Proof", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func item(for action: HotKeyAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.label, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.image = symbol(action.symbolName)
        if let shortcut = state.prefs.shortcut(for: action), let (key, flags) = shortcut.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = flags
        }
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenuSoon()
    }

    private func rebuildMenuSoon() {
        // The open menu can't be swapped; refresh the dynamic rows in place instead.
        guard let menu = statusItem.menu else { return }
        for item in menu.items where (item.representedObject as? String) == HotKeyAction.restoreLastCapture.rawValue {
            item.isEnabled = state.quickAccess.hasRecentlyClosed
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotKeyAction(rawValue: raw) else { return }
        // Let the menu close before an overlay or capture starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [state] in state?.perform(action) }
    }

    // MARK: Recording

    /// While recording, the menu bar icon is a red Stop button showing the time so far.
    private func updateRecordingIndicator() {
        guard let button = statusItem.button else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        if case .recording(let since) = state.recorder.phase {
            statusItem.menu = nil
            statusItem.length = NSStatusItem.variableLength
            button.image = symbol("stop.circle.fill")
            button.contentTintColor = .systemRed
            button.imagePosition = .imageLeading
            button.toolTip = "Stop recording"
            button.target = self
            button.action = #selector(stopRecording)
            let tick = { [weak button] in
                button?.title = " " + RecordingController.elapsedLabel(Date().timeIntervalSince(since))
            }
            tick()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
        } else {
            button.title = ""
            button.image = menuBarIcon
            button.contentTintColor = nil
            button.toolTip = "Proof"
            button.action = nil
            statusItem.length = NSStatusItem.squareLength
            rebuildMenu()
        }
    }

    @objc private func stopRecording() {
        Task { await state.recorder.stop() }
    }

    @objc private func toggleDesktopIcons() { state.prefs.hideDesktopIcons.toggle() }

    @objc private func openFile() { state.chooseFileToEdit() }

    @objc private func openCapturesFolder() { NSWorkspace.shared.open(state.prefs.saveFolder) }

    @objc private func openSettingsFromMenu() { showSettings() }

    @objc private func checkForUpdates() {
        showSettings(tab: .updates)
        Task { await state.updates.check(userInitiated: true) }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "A free screenshot tool.\nGPL-2.0-or-later."),
        ])
    }

    // MARK: Main menu

    /// Only visible while an editor window is open (the app is a regular app then); it gives the
    /// editor ⌘S, ⌘Z, ⌘C and friends through the responder chain.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        submenu("Proof", [
            item("About Proof", #selector(showAbout), "", target: self),
            .separator(),
            item("Settings…", #selector(openSettingsFromMenu), ",", target: self),
            .separator(),
            item("Hide Proof", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Proof", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("Open…", #selector(openFile), "o", target: self),
            .separator(),
            item("Save", #selector(EditorWindow.saveCapture(_:)), "s"),
            item("Save As…", #selector(EditorWindow.saveCaptureAs(_:)), "s", [.command, .shift]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:)), ""),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    // MARK: Settings window

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { state.settingsTab = tab }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Proof Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(state: state))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Writes any uncaught Objective-C exception to stderr and ~/Library/Logs/Proof/exceptions.log
/// before AppKit terminates the process, so crashes during layout are diagnosable.
enum ExceptionLog {
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Proof", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("exceptions.log")
    }()

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            ExceptionLog.record(exception)
        }
    }

    static func record(_ exception: NSException) {
        let text = """
        \(Date()) \(exception.name.rawValue): \(exception.reason ?? "no reason")
        \(exception.callStackSymbols.joined(separator: "\n"))

        """
        FileHandle.standardError.write(text.data(using: .utf8)!)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        Log.app.fault("uncaught exception: \(exception.name.rawValue): \(exception.reason ?? "")")
    }
}
