import AppKit
import Observation

/// Runs shares from the editor and holds what Settings → Sharing shows: sign-in state, the
/// WordPress.com site list, and the history of uploads.
@MainActor @Observable
final class SharingController {
    let history = ShareHistory()

    // CloudUp sign-in form
    var cloudupAccount = CloudUpAccount.load()
    var cloudupUsername = ""
    var cloudupPassword = ""
    var cloudupBusy = false
    var cloudupError: String?

    // WordPress.com
    var wpAccount = WPComAccount.load()
    var wpSites: [WPComSite] = []
    var wpBusy = false
    var wpStatus: String?
    var wpError: String?

    /// Records being deleted from their service.
    var deleting: Set<UUID> = []
    var historyError: String?

    @ObservationIgnored var prefs: () -> Preferences = { Preferences() }
    @ObservationIgnored var openSharingSettings: () -> Void = {}

    // MARK: Sharing

    func provider(for visibility: ShareVisibility) -> ShareProvider? {
        prefs().destination(for: visibility).map(ShareProviders.make)
    }

    /// Uploads the editor's result to the service behind `visibility`, then copies the link.
    func share(_ image: CGImage, pointSize: CGSize, from editor: EditorModel, visibility: ShareVisibility) {
        guard let provider = provider(for: visibility) else { return }
        guard provider.isReady else {
            editor.flash("Sign in to \(provider.kind.label) first")
            openSharingSettings()
            return
        }
        let prefs = prefs()
        var options = ImageExporter.Options(prefs)
        // HEIC doesn't open everywhere a link might be pasted; PNG and JPEG do.
        if options.format == .heic { options.format = .png }
        let name = FileNaming.sanitize(editor.fileURL?.deletingPathExtension().lastPathComponent ?? editor.title)
        // WordPress.com puts the file name in the link; CloudUp's links are random already.
        let uploadName = provider.kind == .wordpress && prefs.wordpressRandomFileNames ? FileNaming.random() : name
        let fileURL = AppInfo.draftsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(uploadName).appendingPathExtension(options.format.fileExtension)
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

        editor.uploadProgress = 0
        editor.uploadLabel = "Uploading to \(provider.kind.label)…"
        Task {
            defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
            do {
                let result = try await provider.upload(file) { fraction in
                    Task { @MainActor in editor.uploadProgress = max(editor.uploadProgress ?? 0, fraction) }
                }
                editor.uploadProgress = nil
                finish(result, title: name, visibility: visibility, prefs: prefs)
                editor.shareSucceeded(ShareConfirmation(service: provider.kind.label, url: result.url, copied: prefs.copyLinkAfterShare))
            } catch {
                editor.uploadProgress = nil
                Log.note("share to \(provider.kind.label) failed: \(error.localizedDescription)")
                editor.showError(error.localizedDescription)
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

    func deleteRemote(_ record: ShareRecord) {
        deleting.insert(record.id)
        historyError = nil
        Task {
            defer { deleting.remove(record.id) }
            do {
                try await ShareProviders.make(record.result.receipt.kind).delete(record.result.receipt)
                history.remove(record.id)
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
