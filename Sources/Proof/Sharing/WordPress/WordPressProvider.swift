import Foundation

/// Uploads to the media library of one WordPress.com (or Jetpack) site and shares the file's
/// URL. Media on a public site is public; on a private site only its members can open it.
struct WordPressProvider: ShareProvider {
    let kind = ProviderKind.wordpress
    let account: WPComAccount?

    init(account: WPComAccount? = WPComAccount.load()) {
        // Against a test server the site comes from the environment, never from Settings.
        let env = ProcessInfo.processInfo.environment
        if env["PROOF_WPCOM_API"] != nil, let site = env["PROOF_WPCOM_SITE"].flatMap(Int.init) {
            var test = WPComAccount(scope: "global", userLogin: "tester", displayName: "Tester", signedInAt: Date())
            test.siteID = site
            self.account = test
        } else {
            self.account = account
        }
    }

    var isReady: Bool { account?.siteID != nil && WPComToken.load() != nil }
    var destinationLabel: String? { account?.siteLabel }
    /// Each site has its own limit; the server's answer is the one that counts.
    var maxBytes: Int? { nil }

    func upload(_ file: ShareFile, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareResult {
        guard let siteID = account?.siteID else { throw ShareError.notConfigured("Choose a WordPress.com site in Settings → Sharing.") }
        guard let token = WPComToken.load() else { throw ShareError.notConfigured("Sign in to WordPress.com in Settings → Sharing.") }

        var form = MultipartForm()
        form.add("attrs[0][title]", file.title)
        form.addFile("media[]", filename: file.filename, mimeType: file.mimeType, url: file.url)
        let body = try form.write()
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: WPComConfig.apiBase.appending(path: "rest/v1.1/sites/\(siteID)/media/new"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await HTTP.upload(request, file: body, progress: progress)
        try Self.check(response, data)

        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // Per-file failures come back as 200 with an `errors` array.
        if let errors = object["errors"] as? [[String: Any]], let first = errors.first {
            throw ShareError.server("WordPress.com: \((first["message"] as? String) ?? (first["error"] as? String) ?? "upload failed")")
        }
        guard let media = (object["media"] as? [[String: Any]])?.first,
              let urlString = media["URL"] as? String, let url = URL(string: urlString) else {
            throw ShareError.unexpected("WordPress.com didn't return the uploaded file")
        }
        let mediaID = (media["ID"] as? Int).map(String.init) ?? (media["ID"] as? String) ?? ""
        return ShareResult(url: url, directURL: url,
                           receipt: ShareReceipt(kind: .wordpress, identifiers: ["site": String(siteID), "media": mediaID]))
    }

    func delete(_ receipt: ShareReceipt) async throws {
        guard let site = receipt.identifiers["site"], let media = receipt.identifiers["media"], !media.isEmpty else { return }
        guard let token = WPComToken.load() else { throw ShareError.notConfigured("Sign in to WordPress.com to delete this upload.") }
        var request = URLRequest(url: WPComConfig.apiBase.appending(path: "rest/v1.1/sites/\(site)/media/\(media)/delete"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HTTP.send(request)
        if response.statusCode == 404 { return }
        try Self.check(response, data)
    }

    private static func check(_ response: HTTPURLResponse, _ data: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403:
            let body = WPComAPI.parseErrorBody(data)
            if body.code == "unauthorized" || body.code == "invalid_token" || response.statusCode == 401 {
                throw ShareError.badCredentials("WordPress.com no longer accepts the saved sign-in. Sign in again in Settings → Sharing.")
            }
            throw ShareError.server("WordPress.com: \(body.message.isEmpty ? "not allowed to upload to this site" : body.message)")
        default:
            throw ShareError.server("WordPress.com: \(HTTP.message(from: data, status: response.statusCode))")
        }
    }
}
