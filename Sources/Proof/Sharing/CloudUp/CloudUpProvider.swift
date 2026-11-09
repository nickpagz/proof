import Foundation

/// Non-secret CloudUp settings. The password is in the Keychain under the username.
struct CloudUpAccount: Codable, Equatable {
    var username: String
    var displayName: String
    /// Copy the raw image link (cldup.com) instead of the CloudUp page.
    var linkToFile = false

    private static let defaultsKey = "cloudup.account.v1"

    static func load() -> CloudUpAccount? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CloudUpAccount.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// CloudUp's original API (api.cloudup.com/1) with Basic auth. Each share is its own stream, so
/// a link never leads to other captures. CloudUp links are unlisted: anyone with the link can
/// open it, nobody can find it otherwise.
///
/// Upload: POST /streams, POST /items (answers with an S3 upload policy), POST the file to S3 as
/// a form, then PATCH the item complete. Delete removes the stream and the item with it.
struct CloudUpProvider: ShareProvider {
    let kind = ProviderKind.cloudup
    static let keychainService = "io.github.nickpagz.proof.cloudup"

    /// `PROOF_CLOUDUP_API` points at a test server; it then also takes the password from
    /// `PROOF_CLOUDUP_PASSWORD`, so tests never touch the Keychain.
    static var apiBase: URL {
        if let raw = ProcessInfo.processInfo.environment["PROOF_CLOUDUP_API"], let url = URL(string: raw) { return url }
        return URL(string: "https://api.cloudup.com/1")!
    }

    private static var testPassword: String? {
        ProcessInfo.processInfo.environment["PROOF_CLOUDUP_API"] == nil ? nil : ProcessInfo.processInfo.environment["PROOF_CLOUDUP_PASSWORD"]
    }

    let account: CloudUpAccount?

    init(account: CloudUpAccount? = CloudUpAccount.load()) {
        // Against a test server the account comes from the environment, never from Settings.
        if Self.testPassword != nil, let user = ProcessInfo.processInfo.environment["PROOF_CLOUDUP_USER"] {
            self.account = CloudUpAccount(username: user, displayName: user)
        } else {
            self.account = account
        }
    }

    var isReady: Bool { account != nil && password != nil }
    var destinationLabel: String? { account.map { $0.displayName.isEmpty ? $0.username : $0.displayName } }
    /// The upload policy CloudUp hands out caps files at about 200 MB.
    var maxBytes: Int? { 200 * 1024 * 1024 }

    private var password: String? {
        guard let account else { return nil }
        return Self.testPassword ?? Keychain.load(service: Self.keychainService, account: account.username)
    }

    // MARK: Account

    /// Checks the credentials against GET /user and stores them. Returns the account.
    static func signIn(username: String, password: String) async throws -> CloudUpAccount {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else { throw ShareError.badCredentials("Enter your CloudUp username and password.") }
        var request = URLRequest(url: apiBase.appending(path: "user"))
        request.setValue(HTTP.basicAuth(user, password), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HTTP.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw ShareError.badCredentials("CloudUp didn't accept that username and password.")
        default: throw ShareError.server("CloudUp sign-in failed: \(HTTP.message(from: data, status: response.statusCode))")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let name = (object["name"] as? String) ?? (object["username"] as? String) ?? ""
        let login = (object["username"] as? String) ?? user
        var account = CloudUpAccount.load() ?? CloudUpAccount(username: user, displayName: name)
        account.username = user
        account.displayName = name.isEmpty ? login : name
        // A test server's account never replaces the real one.
        if testPassword == nil {
            try Keychain.save(password, service: keychainService, account: user)
            account.save()
        }
        Log.note("signed in to CloudUp as \(login)")
        return account
    }

    static func signOut() {
        if let account = CloudUpAccount.load() {
            Keychain.delete(service: keychainService, account: account.username)
        }
        CloudUpAccount.clear()
        Log.note("signed out of CloudUp")
    }

    // MARK: Upload

    func upload(_ file: ShareFile, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareResult {
        guard let account, let password else { throw ShareError.notConfigured("Sign in to CloudUp in Settings → Sharing.") }
        try checkSize(file)
        let auth = HTTP.basicAuth(account.username, password)

        let stream = try await json("POST", "streams", body: ["title": file.title], auth: auth)
        guard let streamID = stream["id"] as? String else { throw ShareError.unexpected("CloudUp created a stream without an id") }
        do {
            var itemBody: [String: Any] = [
                "filename": file.filename, "mime": file.mimeType, "size": file.byteCount,
                "stream_id": streamID, "bucket": "cldup", "title": file.title,
            ]
            if let size = file.pixelSize {
                itemBody["width"] = Int(size.width)
                itemBody["height"] = Int(size.height)
            }
            let item = try await json("POST", "items", body: itemBody, auth: auth, extraHeaders: ["X-Cloudup-Required-Fields": "1"])
            guard let itemID = item["id"] as? String,
                  let s3URLString = item["s3_url"] as? String, let s3URL = Self.secure(s3URLString),
                  let key = item["s3_key"] as? String else {
                throw ShareError.unexpected("CloudUp didn't say where to upload the file")
            }

            // The S3 form: policy fields first, the file last (S3 ignores fields after the file).
            var form = MultipartForm()
            form.add("key", key)
            if let accessKey = item["s3_access_key"] as? String { form.add("AWSAccessKeyId", accessKey) }
            form.add("acl", "public-read")
            if let policy = item["s3_policy"] as? String { form.add("policy", policy) }
            if let signature = item["s3_signature"] as? String { form.add("signature", signature) }
            if let required = item["s3_required_form_fields"] as? [String: Any] {
                for (name, value) in required.sorted(by: { $0.key < $1.key }) { form.add(name, "\(value)") }
            }
            form.add("Content-Type", file.mimeType)
            form.add("Content-Length", String(file.byteCount))
            form.addFile("file", filename: file.filename, mimeType: file.mimeType, url: file.url)
            let body = try form.write()
            defer { try? FileManager.default.removeItem(at: body) }
            Log.note("CloudUp upload to \(s3URL.host ?? "?") for item \(itemID)")
            var s3Request = URLRequest(url: s3URL)
            s3Request.httpMethod = "POST"
            s3Request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            let (s3Data, s3Response) = try await HTTP.upload(s3Request, file: body, progress: progress)
            guard (200..<300).contains(s3Response.statusCode) else {
                throw ShareError.server("CloudUp's storage refused the file: \(HTTP.message(from: s3Data, status: s3Response.statusCode))")
            }

            let done = try await json("PATCH", "items/\(itemID)", body: ["complete": true], auth: auth)
            let pageURL = Self.secure((done["url"] as? String) ?? (item["url"] as? String) ?? "") ?? URL(string: "https://cloudup.com/\(itemID)")!
            let directURL = ((done["direct_url"] as? String) ?? (item["direct_url"] as? String)).flatMap(Self.secure)
            return ShareResult(url: account.linkToFile ? (directURL ?? pageURL) : pageURL, directURL: directURL,
                               receipt: ShareReceipt(kind: .cloudup, identifiers: ["stream": streamID, "item": itemID]))
        } catch {
            // Don't leave an empty stream behind.
            _ = try? await json("DELETE", "streams/\(streamID)", body: nil, auth: auth)
            throw error
        }
    }

    func delete(_ receipt: ShareReceipt) async throws {
        guard let account, let password else { throw ShareError.notConfigured("Sign in to CloudUp to delete this upload.") }
        let auth = HTTP.basicAuth(account.username, password)
        if let stream = receipt.identifiers["stream"] {
            _ = try await json("DELETE", "streams/\(stream)", body: nil, auth: auth, allowMissing: true)
        } else if let item = receipt.identifiers["item"] {
            _ = try await json("DELETE", "items/\(item)", body: nil, auth: auth, allowMissing: true)
        }
    }

    // MARK: Plumbing

    /// CloudUp's original API still hands out http:// addresses for its S3 bucket and links.
    /// macOS only allows HTTPS, and S3 and cloudup.com answer the same paths over HTTPS. Local
    /// test servers keep their scheme.
    static func secure(_ string: String) -> URL? {
        guard var components = URLComponents(string: string), components.host != nil else { return nil }
        let local = components.host == "127.0.0.1" || components.host == "localhost"
        if components.scheme == "http" && !local { components.scheme = "https" }
        return components.url
    }

    private func json(_ method: String, _ path: String, body: [String: Any]?, auth: String,
                      extraHeaders: [String: String] = [:], allowMissing: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: Self.apiBase.appending(path: path))
        request.httpMethod = method
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await HTTP.send(request)
        switch response.statusCode {
        case 200..<300:
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        case 404 where allowMissing:
            return [:]
        case 401, 403:
            throw ShareError.badCredentials("CloudUp no longer accepts the saved sign-in. Sign in again in Settings → Sharing.")
        default:
            throw ShareError.server("CloudUp: \(HTTP.message(from: data, status: response.statusCode))")
        }
    }
}
