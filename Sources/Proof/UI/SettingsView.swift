import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general, screenshots, quickAccess, sharing, shortcuts, updates
}

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView(selection: $state.settingsTab) {
            GeneralSettings(state: state).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            CaptureSettings(state: state).tabItem { Label("Screenshots", systemImage: "camera.viewfinder") }.tag(SettingsTab.screenshots)
            QuickAccessSettings(state: state).tabItem { Label("Quick Access", systemImage: "square.on.square") }.tag(SettingsTab.quickAccess)
            SharingSettings(state: state, sharing: state.sharing).tabItem { Label("Sharing", systemImage: "link") }.tag(SettingsTab.sharing)
            ShortcutSettings(state: state).tabItem { Label("Shortcuts", systemImage: "command") }.tag(SettingsTab.shortcuts)
            UpdateSettings(state: state).tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(SettingsTab.updates)
        }
        .frame(width: 600)
        .frame(minHeight: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("After capture") {
                Picker("When you take a capture", selection: $state.prefs.afterCapture) {
                    ForEach(AfterCaptureFlow.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Close the editor after saving or sharing", isOn: $state.prefs.closeEditorAfterSave)
                switch state.prefs.afterCapture {
                case .editor:
                    Toggle("Ask before closing an unsaved capture", isOn: $state.prefs.confirmUnsavedClose)
                    Text("Nothing is saved until you choose Save as… in the editor. Copying, dragging or sharing it counts as dealt with, so closing doesn't ask.")
                        .font(.caption).foregroundStyle(.secondary)
                case .quickAccess:
                    Toggle("Show Quick Access Overlay", isOn: $state.prefs.showQuickAccess)
                    Toggle("Save to the captures folder", isOn: $state.prefs.saveAfterCapture)
                    Toggle("Copy to clipboard", isOn: $state.prefs.copyAfterCapture)
                    Toggle("Also open the editor", isOn: $state.prefs.openEditorAfterCapture)
                    if !state.prefs.showQuickAccess && !state.prefs.saveAfterCapture && !state.prefs.copyAfterCapture && !state.prefs.openEditorAfterCapture {
                        Text("With everything off, captures are copied to the clipboard so none are lost.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Captures folder") {
                LabeledContent("Save to") {
                    HStack {
                        Text(state.prefs.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                TextField("File name", text: $state.prefs.fileNameTemplate, prompt: Text(FileNaming.defaultTemplate))
                Text("Example: \(example).\(state.prefs.format.fileExtension)  ·  Tokens: \(FileNaming.tokens.map(\.token).joined(separator: " "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Play a sound", isOn: $state.prefs.playSound)
                Toggle("Open Proof at login", isOn: $state.prefs.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    private var example: String {
        FileNaming.name(template: state.prefs.fileNameTemplate, date: Date(), appName: "Safari", kind: .area, counter: { 1 })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = state.prefs.saveFolder
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            state.prefs.saveFolderPath = url.path
        }
    }
}

// MARK: - Screenshots

private struct CaptureSettings: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Format") {
                Picker("File format", selection: $state.prefs.format) {
                    ForEach(ImageFormat.allCases) { Text($0.label).tag($0) }
                }
                if state.prefs.format != .png {
                    LabeledContent("Quality") {
                        Slider(value: $state.prefs.jpegQuality, in: 0.4...1.0)
                    }
                }
                Toggle("Scale Retina captures to 1x", isOn: $state.prefs.scaleRetinaTo1x)
                Toggle("Convert to sRGB", isOn: $state.prefs.convertToSRGB)
            }
            Section("Capturing") {
                Toggle("Hide desktop icons", isOn: $state.prefs.hideDesktopIcons)
                Toggle("Freeze the screen while selecting", isOn: $state.prefs.freezeScreen)
                Toggle("Show crosshair", isOn: $state.prefs.showCrosshair)
                Toggle("Show magnifier", isOn: $state.prefs.showMagnifier)
                Picker("Window captures", selection: $state.prefs.windowBackground) {
                    ForEach(WindowBackground.allCases) { Text($0.label).tag($0) }
                }
                Picker("Self-timer", selection: $state.prefs.selfTimerSeconds) {
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
            Section {
                Text("While selecting: drag for an area, Space to switch to window mode, Space while dragging to move the selection, Shift for a square, Option to draw from the centre, arrow keys to nudge, Escape to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Quick Access

private struct QuickAccessSettings: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Quick Access Overlay") {
                Picker("Position", selection: $state.prefs.quickAccessPosition) {
                    ForEach(QuickAccessPosition.allCases) { Text($0.label).tag($0) }
                }
                Picker("Close automatically", selection: $state.prefs.quickAccessAutoCloseSeconds) {
                    Text("Never").tag(0)
                    Text("After 10 seconds").tag(10)
                    Text("After 30 seconds").tag(30)
                    Text("After 1 minute").tag(60)
                }
                Toggle("Close after dragging the capture out", isOn: $state.prefs.quickAccessCloseAfterDrag)
            }
            Section {
                Text("Drag a thumbnail into any app, or hover for Annotate, Copy and Save. Double-click opens the editor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sharing

private struct SharingSettings: View {
    @Bindable var state: AppState
    @Bindable var sharing: SharingController

    var body: some View {
        Form {
            Section {
                Picker("Share Private uses", selection: $state.prefs.privateDestination) {
                    ForEach(ShareDestination.allCases) { Text($0.label).tag($0) }
                }
                Picker("Share Public uses", selection: $state.prefs.publicDestination) {
                    ForEach(ShareDestination.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Copy the link when the upload finishes", isOn: $state.prefs.copyLinkAfterShare)
            } header: {
                Text("Editor buttons")
            } footer: {
                Text("Nothing leaves your Mac until you press Share Private or Share Public.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("CloudUp") {
                if let account = sharing.cloudupAccount {
                    LabeledContent("Signed in as") {
                        HStack {
                            Text(account.displayName == account.username ? account.username : "\(account.displayName) (\(account.username))")
                            Button("Sign Out") { sharing.signOutOfCloudUp() }
                        }
                    }
                    Toggle("Copy the direct image link instead of the CloudUp page",
                           isOn: Binding(get: { account.linkToFile }, set: { sharing.setCloudUpLinkToFile($0) }))
                    Text("Each share gets its own CloudUp stream. Links are unlisted: anyone with the link can open it, and nobody can find it otherwise.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Username or email", text: $sharing.cloudupUsername)
                        .textContentType(.username)
                    SecureField("Password", text: $sharing.cloudupPassword)
                        .textContentType(.password)
                        .onSubmit { sharing.signInToCloudUp() }
                    HStack {
                        Button("Sign In") { sharing.signInToCloudUp() }
                            .disabled(sharing.cloudupBusy || sharing.cloudupUsername.isEmpty || sharing.cloudupPassword.isEmpty)
                        if sharing.cloudupBusy { ProgressView().controlSize(.small) }
                    }
                    if let error = sharing.cloudupError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Text("Your password is kept in the macOS Keychain and sent only to CloudUp.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("WordPress.com") {
                if !WPComConfig.isConfigured {
                    Text("This build has no WordPress.com app, so sign-in is off. Register one at developer.wordpress.com/apps and add its ID and secret to .secrets/wpcom.env (see docs/DEVELOPMENT.md).")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let account = sharing.wpAccount {
                    LabeledContent("Signed in as") {
                        HStack {
                            Text(account.label)
                            Button("Sign Out") { sharing.signOutOfWordPress() }
                        }
                    }
                    Picker("Upload to", selection: Binding(get: { account.siteID }, set: { sharing.selectSite($0) })) {
                        if account.siteID == nil { Text("Choose a site").tag(Int?.none) }
                        if let id = account.siteID, !sharing.wpSites.contains(where: { $0.id == id }) {
                            Text(account.siteLabel ?? "Site \(id)").tag(Int?.some(id))
                        }
                        ForEach(sharing.wpSites) { site in
                            Text(site.isPrivate ? "\(site.label) · private" : site.label).tag(Int?.some(site.id))
                        }
                    }
                    Toggle("Use a random file name in the link", isOn: $state.prefs.wordpressRandomFileNames)
                    Text("Images go to the site's media library, titled with the capture's name. On a private site only its members can open the link.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Sign In with WordPress.com…") { sharing.signInToWordPress() }
                            .disabled(sharing.wpBusy)
                        if sharing.wpBusy { ProgressView().controlSize(.small) }
                    }
                    if let status = sharing.wpStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = sharing.wpError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Recent shares") {
                if sharing.history.records.isEmpty {
                    Text("Links you share appear here, so you can copy them again or delete the upload.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(sharing.history.records.prefix(15)) { record in
                    HStack(spacing: 8) {
                        Image(systemName: record.visibility == .private ? "lock.fill" : "globe")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.title).lineLimit(1).truncationMode(.middle)
                            Text("\(record.result.receipt.kind.label) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy") { sharing.copyLink(record.result.url) }
                        Button("Open") { NSWorkspace.shared.open(record.result.url) }
                        if sharing.deleting.contains(record.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Delete…") { confirmDelete(record) }
                        }
                    }
                    .controlSize(.small)
                }
                if let error = sharing.historyError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if sharing.wpAccount != nil && sharing.wpSites.isEmpty { await sharing.loadSites() }
        }
    }

    private func confirmDelete(_ record: ShareRecord) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(record.title)” from \(record.result.receipt.kind.label)?"
        alert.informativeText = "The link stops working for everyone. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { sharing.deleteRemote(record) }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.label) {
                        HStack(spacing: 6) {
                            if state.shortcutConflicts.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Another app or macOS already uses this shortcut.")
                            }
                            ShortcutField(shortcut: binding(for: action), isRecording: $state.isRecordingShortcut)
                                .frame(width: 140, height: 24)
                            Button {
                                var shortcuts = state.prefs.shortcuts
                                shortcuts[action.rawValue] = .some(nil)
                                state.prefs.shortcuts = shortcuts
                            } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear")
                        }
                    }
                }
                Button("Restore Defaults") { state.prefs.shortcuts = [:] }
            }
            if SystemShortcuts.screenshotShortcutsEnabled || SystemShortcuts.cleanShotRunning {
                Section("Conflicts") {
                    if SystemShortcuts.screenshotShortcutsEnabled {
                        Text("macOS's own screenshot shortcuts (⇧⌘3, ⇧⌘4, ⇧⌘5) are on, and macOS gets them first. Turn them off under Keyboard → Keyboard Shortcuts → Screenshots.")
                            .font(.caption)
                        Button("Open Keyboard Settings") { SystemShortcuts.openKeyboardSettings() }
                    }
                    if SystemShortcuts.cleanShotRunning {
                        Text("CleanShot X is running and may own the same shortcuts. Quit it to let Proof have them.")
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for action: HotKeyAction) -> Binding<Shortcut?> {
        Binding(
            get: { state.prefs.shortcut(for: action) },
            set: { newValue in
                var shortcuts = state.prefs.shortcuts
                shortcuts[action.rawValue] = .some(newValue)
                state.prefs.shortcuts = shortcuts
            }
        )
    }
}

enum SystemShortcuts {
    /// macOS's screenshot shortcuts are symbolic hot keys 28–31 and 184; a missing entry means on.
    static var screenshotShortcutsEnabled: Bool {
        let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        return ["28", "29", "30", "31", "184"].contains { key in
            guard let entry = all[key] as? [String: Any] else { return true }
            return (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) ?? 1 != 0)
        }
    }

    static var cleanShotRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "pl.maketheweb.cleanshotx").isEmpty
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}

/// Click, then type a shortcut. Escape cancels, Delete clears.
private struct ShortcutField: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onChange = { shortcut = $0 }
        button.onRecordingChange = { isRecording = $0 }
        return button
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onChange = { shortcut = $0 }
        view.onRecordingChange = { isRecording = $0 }
        view.shortcut = shortcut
    }
}

private final class RecorderButton: NSButton {
    var onChange: ((Shortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var shortcut: Shortcut? { didSet { if !recording { refresh() } } }
    private var recording = false { didSet { refresh(); onRecordingChange?(recording) } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(clicked)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func clicked() {
        recording = true
        window?.makeFirstResponder(self)
    }

    private func refresh() {
        title = recording ? "Type shortcut…" : (shortcut?.displayString ?? "None")
    }

    override func resignFirstResponder() -> Bool {
        if recording { recording = false }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case 53: // Escape
            recording = false
        case 51, 117: // Delete, Forward Delete
            recording = false
            onChange?(nil)
        default:
            if let new = Shortcut(event: event) {
                recording = false
                onChange?(new)
            } else {
                NSSound.beep()
            }
        }
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Version", value: state.updates.versionLabel)
                Toggle("Check for updates automatically", isOn: $state.prefs.checkForUpdatesAutomatically)
                HStack(spacing: 10) {
                    Button("Check Now") { Task { await state.updates.check(userInitiated: true) } }
                        .disabled(state.updates.isWorking)
                    if state.updates.phase == .checking {
                        ProgressView().controlSize(.small)
                    }
                    Text(state.updates.statusText).font(.caption).foregroundStyle(.secondary)
                }
                if let update = state.updates.availableUpdate {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Proof \(update.version) is available")
                            .font(.subheadline.weight(.semibold))
                        if !update.notes.isEmpty {
                            ScrollView {
                                Text(update.notes)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 110)
                        }
                        switch state.updates.phase {
                        case .downloading(let fraction):
                            ProgressView(value: fraction) { Text("Downloading…").font(.caption) }
                        case .verifying:
                            ProgressView { Text("Checking the download…").font(.caption) }
                        case .installing:
                            ProgressView { Text("Installing…").font(.caption) }
                        default:
                            HStack(spacing: 10) {
                                Button("Install and Relaunch") { state.updates.install() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(state.isCapturing)
                                if state.updates.skippedVersion == update.version {
                                    Button("Stop Skipping") { state.updates.unskip() }
                                } else {
                                    Button("Skip This Version") { state.updates.skipAvailableVersion() }
                                }
                                if update.releaseNotesURL != nil {
                                    Button("Release Notes") { state.updates.openReleaseNotes() }
                                        .buttonStyle(.link)
                                }
                            }
                        }
                    }
                }
                if case .failed(let message) = state.updates.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if case .blocked(let message) = state.updates.phase {
                    Text(message).font(.caption).foregroundStyle(.orange)
                    HStack(spacing: 8) {
                        Text(state.updates.installCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Button("Copy") { state.updates.copyInstallCommand() }
                            .controlSize(.small)
                    }
                }
            }
            Section("Privacy") {
                Text("Proof talks to GitHub once a day to look for a new version, and to nothing else until you share a capture. No analytics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
