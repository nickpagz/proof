import AppKit
import Observation
import UniformTypeIdentifiers

/// A window that shares: the editor or the recording window. It shows the upload's progress
/// and how it ended.
@MainActor
protocol ShareSink: AnyObject {
    var uploadProgress: Double? { get set }
    var uploadLabel: String { get set }
    func flash(_ message: String)
    func showError(_ message: String)
    func shareSucceeded(_ confirmation: ShareConfirmation)
}

/// Runs shares from the editor and holds what Settings → Sharing shows: sign-in state, the
/// WordPress.com site list, and the history of uploads.
@MainActor @Observable
final class SharingController {
    let history: ShareHistory
    @ObservationIgnored private let makeProvider: (ProviderKind) -> ShareProvider

    init(history: ShareHistory? = nil, makeProvider: @escaping (ProviderKind) -> ShareProvider = ShareProviders.make) {
        self.history = history ?? ShareHistory()
        self.makeProvider = makeProvider
    }

    // CloudUp sign-in form
    var cloudupAccount = CloudUpAccount.load()
    var cloudupUsername = ""
    var cloudupPassword = ""
    var cloudupBusy = false
    var cloudupError: String?
    /// Which API cloudup.com speaks, as last asked. Until then, what the saved sign-in used.
    var cloudupAPI = CloudUpAccount.load()?.api ?? .legacy
    /// The saved sign-in is for the original API and the server has moved to the rebuilt one.
    var cloudupNeedsNewSignIn: Bool { cloudupAccount?.api == .legacy && cloudupAPI == .modern }

    // WordPress.com
    var wpAccount = WPComAccount.load()
    var wpSites: [WPComSite] = []
    var wpBusy = false
    var wpStatus: String?
    var wpError: String?

    /// Records being deleted from their service.
    var deleting: Set<UUID> = []
    var historyError: String?
    var historyStatus: String?

    @ObservationIgnored var prefs: () -> Preferences = { Preferences() }
    @ObservationIgnored var openSharingSettings: () -> Void = {}

    // MARK: Sharing

    func provider(for visibility: ShareVisibility) -> ShareProvider? {
        prefs().destination(for: visibility).map(ShareProviders.make)
    }

    /// The service behind `visibility`, when it is signed in; otherwise says so and opens Settings.
    private func readyProvider(for visibility: ShareVisibility, sink: ShareSink) -> ShareProvider? {
        guard let provider = provider(for: visibility) else { return nil }
        guard provider.isReady else {
            sink.flash("Sign in to \(provider.kind.label) first")
            openSharingSettings()
            return nil
        }
        return provider
    }

    /// WordPress.com puts the file name in the link; CloudUp's links are random already.
    private func uploadName(_ name: String, for provider: ShareProvider) -> String {
        provider.kind == .wordpress && prefs().wordpressRandomFileNames ? FileNaming.random() : name
    }

    /// Uploads the editor's result to the service behind `visibility`, then copies the link.
    func share(_ image: CGImage, pointSize: CGSize, from editor: EditorModel, visibility: ShareVisibility) {
        guard let provider = readyProvider(for: visibility, sink: editor) else { return }
        let prefs = prefs()
        var options = ImageExporter.Options(prefs)
        // HEIC doesn't open everywhere a link might be pasted; PNG and JPEG do.
        if options.format == .heic { options.format = .png }
        let name = FileNaming.sanitize(editor.fileURL?.deletingPathExtension().lastPathComponent ?? editor.title)
        let fileURL = AppInfo.draftsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(uploadName(name, for: provider)).appendingPathExtension(options.format.fileExtension)
        do {
            try ImageExporter.write(image, pointSize: pointSize, to: fileURL, options: options)
        } catch {
            editor.showError(error.localizedDescription)
            return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        let file = ShareFile(url: fileURL, filename: fileURL.lastPathComponent,
                             mimeType: options.format == .jpeg ? "image/jpeg" : "image/png", byteCount: bytes,
                             pixelSize: CGSize(width: image.width, height: image.height), title: name)
        send(file, with: provider, visibility: visibility, from: editor)
    }

    /// Uploads a finished file, such as a recording, to the service behind `visibility`.
    func share(file url: URL, title: String, mimeType: String, pixelSize: CGSize?, from sink: ShareSink, visibility: ShareVisibility) {
        guard let provider = readyProvider(for: visibility, sink: sink) else { return }
        let name = FileNaming.sanitize(title)
        let copy = AppInfo.draftsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(uploadName(name, for: provider)).appendingPathExtension(url.pathExtension)
        do {
            // A clone on APFS: instant, and no extra space until one of them changes.
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            sink.showError(error.localizedDescription)
            return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int) ?? 0
        let file = ShareFile(url: copy, filename: copy.lastPathComponent, mimeType: mimeType, byteCount: bytes, pixelSize: pixelSize, title: name)
        send(file, with: provider, visibility: visibility, from: sink)
    }

    /// Uploads a file for an agent, to the service behind `visibility`: no window to show progress
    /// in, and the clipboard is left alone. Returns the result and the service's name.
    func upload(file url: URL, visibility: ShareVisibility,
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> (ShareResult, String) {
        guard let provider = provider(for: visibility) else {
            throw ShareError.notConfigured("No service is set for \(visibility.label) in Proof → Settings → Sharing.")
        }
        guard provider.isReady else {
            throw ShareError.notConfigured("Proof isn't signed in to \(provider.kind.label). Ask the person to sign in under Settings → Sharing.")
        }
        let name = FileNaming.sanitize(url.deletingPathExtension().lastPathComponent)
        let folder = AppInfo.draftsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(uploadName(name, for: provider)).appendingPathExtension(url.pathExtension)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int) ?? 0
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let pixels = CLI.loadImage(copy.path).map { CGSize(width: $0.0.width, height: $0.0.height) }
        let file = ShareFile(url: copy, filename: copy.lastPathComponent, mimeType: mimeType, byteCount: bytes, pixelSize: pixels, title: name)
        let result = try await provider.upload(file, progress: progress)
        history.add(ShareRecord(date: Date(), title: name, visibility: visibility, result: result))
        Log.note("shared \(visibility.rawValue) for an agent → \(result.url.absoluteString)")
        return (result, provider.kind.label)
    }

    /// Uploads `file`, which sits alone in a drafts folder that goes once it's done.
    private func send(_ file: ShareFile, with provider: ShareProvider, visibility: ShareVisibility, from sink: ShareSink) {
        let prefs = prefs()
        sink.uploadProgress = 0
        sink.uploadLabel = "Uploading to \(provider.kind.label)…"
        Task {
            defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
            do {
                let result = try await provider.upload(file) { fraction in
                    Task { @MainActor in sink.uploadProgress = max(sink.uploadProgress ?? 0, fraction) }
                }
                sink.uploadProgress = nil
                finish(result, title: file.title, visibility: visibility, prefs: prefs)
                sink.shareSucceeded(ShareConfirmation(service: provider.kind.label, url: result.url, copied: prefs.copyLinkAfterShare))
            } catch {
                sink.uploadProgress = nil
                Log.note("share to \(provider.kind.label) failed: \(error.localizedDescription)")
                sink.showError(error.localizedDescription)
            }
        }
    }

    private func finish(_ result: ShareResult, title: String, visibility: ShareVisibility, prefs: Preferences) {
        history.add(ShareRecord(date: Date(), title: title, visibility: visibility, result: result))
        if prefs.copyLinkAfterShare { copyLink(result.url) }
        Log.note("shared \(visibility.rawValue) → \(result.url.absoluteString)")
    }

    func copyLink(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    // MARK: History

    @discardableResult
    func deleteRemote(_ record: ShareRecord) -> Task<Void, Never> {
        deleting.insert(record.id)
        historyError = nil
        historyStatus = nil
        return Task {
            defer { deleting.remove(record.id) }
            do {
                let result = try await makeProvider(record.result.receipt.kind).delete(record.result.receipt)
                history.remove(record.id)
                if result == .alreadyMissing {
                    historyStatus = "This media no longer exists on \(record.result.receipt.kind.label). Removed it from Recent shares."
                }
                Log.note("deleted share \(record.result.url.absoluteString)")
            } catch {
                historyError = error.localizedDescription
            }
        }
    }

    // MARK: CloudUp

    func signInToCloudUp() {
        cloudupBusy = true
        cloudupError = nil
        Task {
            defer { cloudupBusy = false }
            do {
                cloudupAccount = try await CloudUpProvider.signIn(username: cloudupUsername, password: cloudupPassword)
                cloudupPassword = ""
            } catch {
                cloudupError = error.localizedDescription
                await refreshCloudUpAPI()
            }
        }
    }

    /// Asks cloudup.com which API it speaks, so Settings offers the sign-in that will work.
    /// Keeps the last answer when the server can't be reached.
    func refreshCloudUpAPI() async {
        if let api = await CloudUpConfig.detect() { cloudupAPI = api }
    }

    /// The rebuilt CloudUp signs in through the browser.
    func signInToCloudUpInBrowser() {
        cloudupBusy = true
        cloudupError = nil
        Task {
            defer { cloudupBusy = false }
            do {
                cloudupAccount = try await CloudUpAuth.signIn()
                cloudupPassword = ""
            } catch {
                cloudupError = error.localizedDescription
            }
        }
    }

    func signOutOfCloudUp() {
        CloudUpProvider.signOut()
        cloudupAccount = nil
    }

    func setCloudUpLinkToFile(_ on: Bool) {
        guard var account = cloudupAccount else { return }
        account.linkToFile = on
        account.save()
        cloudupAccount = account
    }

    // MARK: WordPress.com

    func signInToWordPress() {
        wpBusy = true
        wpError = nil
        wpStatus = "Finish signing in in your browser…"
        Task {
            defer { wpBusy = false; wpStatus = nil }
            do {
                let signIn = try await WPComAuth.signIn()
                wpAccount = signIn.account
                await loadSites()
            } catch {
                wpError = error.localizedDescription
            }
        }
    }

    func signOutOfWordPress() {
        WPComAuth.signOut()
        wpAccount = nil
        wpSites = []
    }

    /// The sites the account can upload to; picks the first when none is chosen yet.
    func loadSites() async {
        guard let token = WPComToken.load() else { return }
        do {
            let sites = try await WPComAPI(token: token, session: WPComAPI.makeSession()).sites()
            wpSites = sites.filter(\.isEligible).sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            if wpAccount?.siteID == nil, let first = wpSites.first { selectSite(first.id) }
            // A site chosen before recordings existed learns whether it has VideoPress.
            if let id = wpAccount?.siteID, let site = wpSites.first(where: { $0.id == id }),
               wpAccount?.siteHasVideoPress != site.hasVideoPress {
                selectSite(id)
            }
        } catch {
            wpError = error.localizedDescription
        }
    }

    func selectSite(_ id: Int?) {
        guard var account = wpAccount else { return }
        account.select(wpSites.first { $0.id == id })
        account.save()
        wpAccount = account
    }
}
