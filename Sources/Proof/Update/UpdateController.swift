import AppKit
import Foundation
import Observation

/// Owns the update state the UI shows: checks on a schedule, remembers skipped and announced
/// versions, and runs the installer with progress.
@MainActor @Observable
final class UpdateController {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case verifying
        case installing
        case failed(String)
        /// Installing from here is impossible (read-only volume, no write permission, dev build).
        case blocked(String)
    }

    private enum Keys {
        static let lastCheck = "update.lastCheck"
        static let skippedVersion = "update.skippedVersion"
        static let notifiedVersion = "update.notifiedVersion"
        static let postInstallNotice = "update.postInstallNotice"
    }

    private(set) var phase: Phase = .idle
    /// The newest release the feed offered, kept across phases so notes stay visible after a failure.
    private(set) var latest: UpdatePayload?
    private(set) var lastCheck: Date?
    private(set) var skippedVersion: String?
    /// Set once after an update that changed signing identity; the panel shows it, then clears it.
    var postInstallNotice: String?

    let currentVersion: String
    let currentBuild: Int

    @ObservationIgnored var isAppBusy: @MainActor () -> Bool = { false }
    @ObservationIgnored var automaticChecksEnabled: @MainActor () -> Bool = { true }
    @ObservationIgnored private let feed = UpdateFeed()
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var initialCheck: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        currentVersion = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        currentBuild = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        let defaults = UserDefaults.standard
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
        skippedVersion = defaults.string(forKey: Keys.skippedVersion)
    }

    // MARK: Derived

    var versionLabel: String { "\(currentVersion) (\(currentBuild))" }

    var isWorking: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    var isInstalling: Bool {
        switch phase {
        case .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    /// The offered release when it is newer than what is running.
    var availableUpdate: UpdatePayload? {
        guard let latest, latest.isNewer(thanVersion: currentVersion, build: currentBuild) else { return nil }
        return latest
    }

    /// Show the panel row and send the notification only for versions the user has not skipped.
    var shouldOffer: Bool {
        guard let update = availableUpdate else { return false }
        return update.version != skippedVersion
    }

    var installCommand: String { UpdateConfig.installCommand }

    var statusText: String {
        switch phase {
        case .checking: return "Checking…"
        case .upToDate: return "You're up to date."
        case .available: return ""
        case .failed, .blocked: return ""
        default:
            guard let lastCheck else { return UpdateConfig.usesFeedOverride ? "Using a custom update feed." : "Not checked yet." }
            return "Last checked \(lastCheck.formatted(.relative(presentation: .named)))."
        }
    }

    // MARK: Lifecycle

    /// Called once the app is up: tidies leftovers, checks shortly after launch, then once a day.
    func start() {
        UpdateInstaller.cleanUpLeftovers()
        let defaults = UserDefaults.standard
        if let notice = defaults.string(forKey: Keys.postInstallNotice) {
            postInstallNotice = notice
            defaults.removeObject(forKey: Keys.postInstallNotice)
        }
        initialCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UpdateConfig.initialCheckDelay))
            guard let self, self.automaticChecksEnabled() else { return }
            await self.check(userInitiated: false)
        }
        let scheduler = NSBackgroundActivityScheduler(identifier: "\(UpdateConfig.bundleID).update-check")
        scheduler.repeats = true
        scheduler.interval = UpdateConfig.checkInterval
        scheduler.tolerance = 3600
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self, self.automaticChecksEnabled() else { completion(.finished); return }
                if self.isAppBusy() || self.isWorking { completion(.deferred); return }
                await self.check(userInitiated: false)
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard !isWorking else { return }
        phase = .checking
        do {
            let payload = try await feed.fetchManifest()
            latest = payload
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Keys.lastCheck)
            if payload.isNewer(thanVersion: currentVersion, build: currentBuild) {
                phase = .available
                Log.note("update available: \(payload.version) (\(payload.build)); running \(versionLabel)")
                let notified = UserDefaults.standard.string(forKey: Keys.notifiedVersion)
                if !userInitiated, shouldOffer, notified != payload.version {
                    UserDefaults.standard.set(payload.version, forKey: Keys.notifiedVersion)
                    Notifier.shared.notify(title: "Proof \(payload.version) is available",
                                           body: "Open Proof's settings to install it.",
                                           action: .openUpdates)
                }
            } else {
                phase = .upToDate
                Log.note("update check: \(versionLabel) is current (feed offers \(payload.version) (\(payload.build)))")
            }
        } catch {
            phase = .failed(error.localizedDescription)
            Log.note("update check failed: \(error.localizedDescription)")
        }
    }

    // MARK: Installing

    func install() {
        guard let payload = availableUpdate, !isWorking else { return }
        guard !isAppBusy() else {
            phase = .failed(UpdateError.busy.localizedDescription)
            return
        }
        installTask = Task { [weak self] in
            await self?.performInstall(payload)
        }
    }

    private func performInstall(_ payload: UpdatePayload) async {
        phase = .downloading(0)
        do {
            try await UpdateInstaller.install(payload, session: feed.session, launchAfter: true) { step in
                Task { @MainActor [weak self] in self?.apply(step) }
            }
            Log.note("update installed: \(payload.version) (\(payload.build)); relaunching")
            NSApp.terminate(nil)
        } catch let error as UpdateError {
            if case .notInstallable = error {
                phase = .blocked(error.localizedDescription)
            } else {
                phase = .failed(error.localizedDescription)
            }
            Log.note("update failed: \(error.localizedDescription)")
        } catch {
            phase = .failed(error.localizedDescription)
            Log.note("update failed: \(error.localizedDescription)")
        }
    }

    private func apply(_ step: UpdateInstaller.Step) {
        switch step {
        case .downloading(let done, let total):
            phase = .downloading(total > 0 ? min(1, Double(done) / Double(total)) : 0)
        case .verifying:
            phase = .verifying
        case .installing:
            phase = .installing
        case .identityChange(let notice):
            UserDefaults.standard.set(notice, forKey: Keys.postInstallNotice)
        }
    }

    // MARK: Skipping and helpers

    func skipAvailableVersion() {
        guard let update = availableUpdate else { return }
        skippedVersion = update.version
        UserDefaults.standard.set(update.version, forKey: Keys.skippedVersion)
    }

    func unskip() {
        skippedVersion = nil
        UserDefaults.standard.removeObject(forKey: Keys.skippedVersion)
    }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }

    func openReleaseNotes() {
        guard let url = latest?.releaseNotesURL else { return }
        NSWorkspace.shared.open(url)
    }
}
