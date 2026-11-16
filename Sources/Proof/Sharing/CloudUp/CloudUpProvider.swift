import Foundation

/// Non-secret CloudUp settings. The password (original API) or the tokens (rebuilt CloudUp) are
/// in the Keychain.
struct CloudUpAccount: Codable, Equatable {
    var username: String
    var displayName: String
    /// Copy the raw image link (cldup.com) instead of the CloudUp page.
    var linkToFile = false
    /// The API this sign-in belongs to. Accounts saved before the rebuilt CloudUp have none.
    var api = CloudUpAPI.legacy

    private static let defaultsKey = "cloudup.account.v1"

    init(username: String, displayName: String, linkToFile: Bool = false, api: CloudUpAPI = .legacy) {
        self.username = username
        self.displayName = displayName
        self.linkToFile = linkToFile
        self.api = api
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decode(String.self, forKey: .displayName)
        linkToFile = try container.decodeIfPresent(Bool.self, forKey: .linkToFile) ?? false
        api = try container.decodeIfPresent(CloudUpAPI.self, forKey: .api) ?? .legacy
    }

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

/// CloudUp, on whichever API the account signed in to. Each share is its own stream, so a link
/// never leads to other captures. CloudUp links are unlisted: anyone with the link can open it,
/// nobody can find it otherwise.
///
/// Original API (api.cloudup.com/1, Basic auth): POST /streams, POST /items (answers with an S3
/// upload policy), POST the file to S3 as a form, then PATCH the item complete.
///
/// Rebuilt CloudUp (same host without /1, Bearer token): POST /streams, POST /items (answers with
/// a presigned S3 address), PUT the file there, then PATCH the item complete.
///
/// Delete removes the stream and the item with it on both.
struct CloudUpProvider: ShareProvider {
    let kind = ProviderKind.cloudup
    static let keychainService = "io.github.nickpagz.proof.cloudup"

    /// `PROOF_CLOUDUP_API` points at a test server. It then takes the password from
    /// `PROOF_CLOUDUP_PASSWORD` (original API) or the token from `PROOF_CLOUDUP_TOKEN` (rebuilt
    /// CloudUp), so tests never touch the Keychain.
    static var apiBase: URL { CloudUpConfig.legacyBase }

    private static var testPassword: String? {
        ProcessInfo.processInfo.environment["PROOF_CLOUDUP_API"] == nil ? nil : ProcessInfo.processInfo.environment["PROOF_CLOUDUP_PASSWORD"]
    }

    let account: CloudUpAccount?

    init(account: CloudUpAccount? = CloudUpAccount.load()) {
        // Against a test server the account comes from the environment, never from Settings.
        let user = ProcessInfo.processInfo.environment["PROOF_CLOUDUP_USER"]
        if CloudUpTokens.testToken != nil {
            self.account = CloudUpAccount(username: user ?? "tester", displayName: user ?? "tester", api: .modern)
        } else if Self.testPassword != nil, let user {
            self.account = CloudUpAccount(username: user, displayName: user)
        } else {
            self.account = account
        }
    }

    var isReady: Bool {
        guard let account else { return false }
        return account.api == .modern ? CloudUpTokens.load() != nil : password != nil
    }
    var destinationLabel: String? { account.map { $0.displayName.isEmpty ? $0.username : $0.displayName } }
    /// The upload policy CloudUp hands out caps files at about 200 MB.
    var maxBytes: Int? { 200 * 1024 * 1024 }

    private var password: String? {
        guard let account else { return nil }
        return Self.testPassword ?? Keychain.load(service: Self.keychainService, account: account.username)
    }

    // MARK: Account

    /// cloudup.com now runs the rebuilt CloudUp, which no longer takes a password over the API.
    static let movedToBrowserSignIn = ShareError.badCredentials("CloudUp has moved to signing in through the browser. Open Settings → Sharing and sign in to CloudUp again.")

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
        case 401, 403:
            if CloudUpConfig.classify(status: response.statusCode, body: data) == .modern { throw Self.movedToBrowserSignIn }
            throw ShareError.badCredentials("CloudUp didn't accept that username and password.")
        default: throw ShareError.server("CloudUp sign-in failed: \(HTTP.message(from: data, status: response.statusCode))")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let name = (object["name"] as? String) ?? (object["username"] as? String) ?? ""
        let login = (object["username"] as? String) ?? user
        var account = CloudUpAccount.load() ?? CloudUpAccount(username: user, displayName: name)
        account.username = user
        account.displayName = name.isEmpty ? login : name
        account.api = .legacy
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
        CloudUpTokens.delete()
        CloudUpAccount.clear()
        Log.note("signed out of CloudUp")
    }

    // MARK: Upload

    func upload(_ file: ShareFile, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareResult {
        guard let account else { throw ShareError.notConfigured("Sign in to CloudUp in Settings → Sharing.") }
        try checkSize(file)
        if account.api == .modern { return try await uploadModern(file, account: account, progress: progress) }
        guard let password else { throw ShareError.notConfigured("Sign in to CloudUp in Settings → Sharing.") }
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

    func delete(_ receipt: ShareReceipt) async throws -> ShareDeletionResult {
        guard let account else { throw ShareError.notConfigured("Sign in to CloudUp to delete this upload.") }
        // Streams keep their IDs across the move, so shares made on the original API are still
        // deletable after signing in to the rebuilt one.
        if account.api == .modern {
            if let stream = receipt.identifiers["stream"] {
                _ = try await modernJSON("DELETE", "streams/\(stream)", body: nil, allowMissing: true)
            } else if let item = receipt.identifiers["item"] {
                _ = try await modernJSON("DELETE", "items/\(item)", body: nil, allowMissing: true)
            }
            return .deleted
        }
        guard let password else { throw ShareError.notConfigured("Sign in to CloudUp to delete this upload.") }
        let auth = HTTP.basicAuth(account.username, password)
        if let stream = receipt.identifiers["stream"] {
            _ = try await json("DELETE", "streams/\(stream)", body: nil, auth: auth, allowMissing: true)
        } else if let item = receipt.identifiers["item"] {
            _ = try await json("DELETE", "items/\(item)", body: nil, auth: auth, allowMissing: true)
        }
        return .deleted
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
            if CloudUpConfig.classify(status: response.statusCode, body: data) == .modern { throw Self.movedToBrowserSignIn }
            throw CloudUpAuth.expired
        default:
            throw ShareError.server("CloudUp: \(HTTP.message(from: data, status: response.statusCode))")
        }
    }

    // MARK: Rebuilt CloudUp

    private func uploadModern(_ file: ShareFile, account: CloudUpAccount,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> ShareResult {
        let stream = try await modernJSON("POST", "streams", body: ["title": file.title])
        guard let streamID = stream["id"] as? String else { throw ShareError.unexpected("CloudUp created a stream without an id") }
        do {
            let item = try await modernJSON("POST", "items", body: [
                "filename": file.filename, "mime": file.mimeType, "size": file.byteCount,
                "stream_id": streamID, "title": file.title,
            ])
            guard let itemID = item["id"] as? String,
                  let s3URL = (item["s3_url"] as? String).flatMap(Self.secure) else {
                throw ShareError.unexpected("CloudUp didn't say where to upload the file")
            }

            // The address is presigned for this object alone. It carries its own authorization,
            // and S3 refuses x-amz-* headers that weren't signed, so only Content-Type goes along.
            Log.note("CloudUp upload to \(s3URL.host ?? "?") for item \(itemID)")
            var put = URLRequest(url: s3URL)
            put.httpMethod = "PUT"
            put.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
            let (s3Data, s3Response) = try await HTTP.upload(put, file: file.url, progress: progress)
            guard (200..<300).contains(s3Response.statusCode) else {
                throw ShareError.server("CloudUp's storage refused the file: \(HTTP.message(from: s3Data, status: s3Response.statusCode))")
            }

            let done = try await modernJSON("PATCH", "items/\(itemID)", body: ["complete": true])
            let pageURL = Self.secure((done["url"] as? String) ?? (item["url"] as? String) ?? "") ?? URL(string: "https://cloudup.com/\(itemID)")!
            let directURL = ((done["direct_url"] as? String) ?? (item["direct_url"] as? String)).flatMap(Self.secure)
            return ShareResult(url: account.linkToFile ? (directURL ?? pageURL) : pageURL, directURL: directURL,
                               receipt: ShareReceipt(kind: .cloudup, identifiers: ["stream": streamID, "item": itemID]))
        } catch {
            // Don't leave an empty stream behind.
            _ = try? await modernJSON("DELETE", "streams/\(streamID)", body: nil)
            throw error
        }
    }

    /// A Bearer-authenticated call. A refused token is renewed once and the call repeated.
    private func modernJSON(_ method: String, _ path: String, body: [String: Any]?, allowMissing: Bool = false) async throws -> [String: Any] {
        var tokens = try await CloudUpTokenStore.shared.current()
        var (data, response) = try await modernSend(method, path, body: body, token: tokens.accessToken)
        if response.statusCode == 401 {
            tokens = try await CloudUpTokenStore.shared.replacement(for: tokens.accessToken)
            (data, response) = try await modernSend(method, path, body: body, token: tokens.accessToken)
        }
        switch response.statusCode {
        case 200..<300:
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        case 404 where allowMissing:
            return [:]
        case 401:
            throw CloudUpAuth.expired
        default:
            throw ShareError.server("CloudUp: \(HTTP.message(from: data, status: response.statusCode))")
        }
    }

    private func modernSend(_ method: String, _ path: String, body: [String: Any]?, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: CloudUpConfig.modernBase.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await HTTP.send(request)
    }
}
