import AppKit
import CryptoKit
import Foundation
import Security

/// The rebuilt CloudUp's access and refresh tokens, kept in the Keychain as one entry.
struct CloudUpTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?

    private static let keychainAccount = "oauth"

    /// Good for at least another minute. A token without an expiry is used until refused.
    func isFresh(at now: Date = Date()) -> Bool {
        expiresAt.map { $0.timeIntervalSince(now) > 60 } ?? true
    }

    /// `PROOF_CLOUDUP_API` with `PROOF_CLOUDUP_TOKEN` is a test server's token, which never
    /// touches the Keychain and is never renewed.
    static var testToken: String? {
        let env = ProcessInfo.processInfo.environment
        guard env["PROOF_CLOUDUP_API"] != nil, let token = env["PROOF_CLOUDUP_TOKEN"], !token.isEmpty else { return nil }
        return token
    }

    static func load() -> CloudUpTokens? {
        if let testToken { return CloudUpTokens(accessToken: testToken, refreshToken: nil, expiresAt: nil) }
        guard let raw = Keychain.load(service: CloudUpProvider.keychainService, account: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(CloudUpTokens.self, from: Data(raw.utf8))
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try Keychain.save(String(decoding: data, as: UTF8.self), service: CloudUpProvider.keychainService, account: Self.keychainAccount)
    }

    static func delete() {
        Keychain.delete(service: CloudUpProvider.keychainService, account: keychainAccount)
    }
}

/// Hands out a usable access token and renews it once however many uploads ask at the same time:
/// CloudUp replaces the refresh token on each use, so two renewals in parallel would sign the
/// user out.
actor CloudUpTokenStore {
    static let shared = CloudUpTokenStore()
    private var renewal: Task<CloudUpTokens, Error>?

    /// The saved token, renewed first when it is about to expire.
    func current() async throws -> CloudUpTokens {
        guard let tokens = CloudUpTokens.load() else { throw ShareError.notConfigured("Sign in to CloudUp in Settings → Sharing.") }
        return tokens.isFresh() ? tokens : try await renew(tokens)
    }

    /// Call when CloudUp refused `rejected`. Returns a newer token, which another upload may
    /// already have fetched.
    func replacement(for rejected: String) async throws -> CloudUpTokens {
        guard let tokens = CloudUpTokens.load() else { throw CloudUpAuth.expired }
        return tokens.accessToken == rejected ? try await renew(tokens) : tokens
    }

    private func renew(_ tokens: CloudUpTokens) async throws -> CloudUpTokens {
        if let renewal { return try await renewal.value }
        guard CloudUpTokens.testToken == nil, let refreshToken = tokens.refreshToken else { throw CloudUpAuth.expired }
        let task = Task { () throws -> CloudUpTokens in
            let renewed = try await CloudUpAuth.refresh(refreshToken)
            try renewed.save()
            return renewed
        }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }
}

/// The rebuilt CloudUp's OAuth2 authorization-code flow with PKCE and a loopback redirect.
enum CloudUpAuth {
    static let expired = ShareError.badCredentials("CloudUp no longer accepts the saved sign-in. Sign in again in Settings → Sharing.")

    struct PKCE {
        let verifier: String
        let challenge: String

        static func make() -> PKCE {
            let verifier = CloudUpAuth.randomURLSafe(bytes: 48)
            return PKCE(verifier: verifier, challenge: CloudUpAuth.challenge(for: verifier))
        }
    }

    /// The S256 challenge for a verifier (RFC 7636).
    static func challenge(for verifier: String) -> String {
        urlSafe(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return urlSafe(Data(bytes))
    }

    private static func urlSafe(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// No scope is requested: CloudUp then grants everything the registered app is allowed.
    static func authorizeURL(state: String, challenge: String) -> URL {
        let items: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", CloudUpConfig.clientID),
            ("redirect_uri", CloudUpConfig.redirectURI),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        var components = URLComponents(url: CloudUpConfig.authBase.appending(path: "auth"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = FormEncoding.encode(items)
        return components.url!
    }

    /// Runs the whole flow: listener, browser, callback, token exchange, account lookup, storage.
    static func signIn(openBrowser: Bool = true, timeout: Duration = .seconds(300)) async throws -> CloudUpAccount {
        guard CloudUpConfig.isConfigured else {
            throw ShareError.notConfigured("This build has no CloudUp app ID and secret, so browser sign-in is unavailable. Add them to .secrets/cloudup.env and rebuild (see docs/DEVELOPMENT.md).")
        }
        let state = randomURLSafe(bytes: 32)
        let pkce = PKCE.make()
        let server = LoopbackServer(port: CloudUpConfig.callbackPort)
        try server.start()
        let url = authorizeURL(state: state, challenge: pkce.challenge)
        Log.note("CloudUp sign-in: \(url.absoluteString)")
        if openBrowser {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }

        let callback: LoopbackServer.Callback
        do {
            callback = try await server.waitForCallback(timeout: timeout)
        } catch {
            server.cancel()
            throw describe(error)
        }
        if let error = callback.error {
            throw ShareError.badCredentials(error == "access_denied" ? "Sign-in was cancelled in the browser."
                                            : "CloudUp sign-in failed: \(callback.errorDescription ?? error)")
        }
        guard callback.state == state, let code = callback.code, !code.isEmpty else {
            throw ShareError.unexpected("the browser came back without a valid sign-in. Try again.")
        }

        let tokens = try await token([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", pkce.verifier),
            ("redirect_uri", CloudUpConfig.redirectURI),
        ])
        let user = try await fetchUser(accessToken: tokens.accessToken)
        let previous = CloudUpAccount.load()
        var account = previous ?? CloudUpAccount(username: user.username, displayName: user.displayName)
        // The original API's password is of no further use; don't keep it around.
        if let previous, previous.api == .legacy {
            Keychain.delete(service: CloudUpProvider.keychainService, account: previous.username)
        }
        account.username = user.username
        account.displayName = user.displayName
        account.api = .modern
        try tokens.save()
        account.save()
        Log.note("signed in to CloudUp as \(user.username) (browser sign-in)")
        return account
    }

    static func refresh(_ refreshToken: String) async throws -> CloudUpTokens {
        do {
            return try await token([("grant_type", "refresh_token"), ("refresh_token", refreshToken)])
        } catch ShareError.badCredentials {
            throw expired
        }
    }

    /// POST /oauth/token with the app's ID and secret added.
    private static func token(_ parameters: [(String, String)]) async throws -> CloudUpTokens {
        var request = URLRequest(url: CloudUpConfig.authBase.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let pairs = parameters + [("client_id", CloudUpConfig.clientID), ("client_secret", CloudUpConfig.clientSecret ?? "")]
        request.httpBody = Data(FormEncoding.encode(pairs).utf8)
        let (data, response) = try await HTTP.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 400, 401, 403: throw ShareError.badCredentials("CloudUp sign-in failed: \(HTTP.message(from: data, status: response.statusCode))")
        default: throw ShareError.server("CloudUp sign-in failed: \(HTTP.message(from: data, status: response.statusCode))")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            throw ShareError.unexpected("CloudUp's sign-in reply had no access token")
        }
        let lifetime = (object["expires_in"] as? NSNumber)?.doubleValue
        return CloudUpTokens(accessToken: access, refreshToken: object["refresh_token"] as? String,
                             expiresAt: lifetime.map { Date().addingTimeInterval($0) })
    }

    private static func fetchUser(accessToken: String) async throws -> (username: String, displayName: String) {
        var request = URLRequest(url: CloudUpConfig.modernBase.appending(path: "users"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HTTP.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ShareError.server("CloudUp account lookup failed: \(HTTP.message(from: data, status: response.statusCode))")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let username = (object["username"] as? String) ?? (object["email"] as? String) ?? "CloudUp"
        let name = (object["name"] as? String) ?? (object["display_name"] as? String) ?? ""
        return (username, name.isEmpty ? username : name)
    }

    /// The loopback listener reports in WordPress.com's terms; say the same things about CloudUp.
    private static func describe(_ error: Error) -> Error {
        switch error as? WPComError {
        case .portInUse:
            return ShareError.server("Port \(CloudUpConfig.callbackPort) is in use, so the sign-in callback cannot be received. Quit whatever holds it (lsof -i :\(CloudUpConfig.callbackPort)) and try again.")
        case .some(let other):
            return ShareError.server(other.localizedDescription)
        case nil:
            return error
        }
    }
}
