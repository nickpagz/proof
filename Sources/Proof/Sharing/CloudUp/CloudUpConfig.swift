import Foundation

/// Which CloudUp API a server speaks. cloudup.com is moving from the first to the second, and the
/// same host answers for both, so Proof asks the server instead of assuming.
enum CloudUpAPI: String, Codable {
    /// The original API (api.cloudup.com/1): Basic auth and an S3 form upload.
    case legacy
    /// The rebuilt CloudUp: OAuth with PKCE, Bearer tokens and a presigned S3 PUT.
    case modern
}

/// Where CloudUp lives and how Proof identifies itself to the rebuilt service. The OAuth app's ID
/// and secret are injected into the built bundle's Info.plist by Scripts/bundle.sh from
/// .secrets/cloudup.env; neither is in git.
enum CloudUpConfig {
    /// The original API's address. `PROOF_CLOUDUP_API` points it at a test or staging server.
    static var legacyBase: URL {
        if let raw = ProcessInfo.processInfo.environment["PROOF_CLOUDUP_API"], let url = URL(string: raw) { return url }
        return URL(string: "https://api.cloudup.com/1")!
    }

    /// The rebuilt API serves the same host without the version segment.
    static var modernBase: URL { modernBase(for: legacyBase) }

    static func modernBase(for legacy: URL) -> URL {
        legacy.lastPathComponent == "1" ? legacy.deletingLastPathComponent() : legacy
    }

    /// The sign-in server. `PROOF_CLOUDUP_AUTH` overrides it for a test server.
    static var authBase: URL {
        if let raw = ProcessInfo.processInfo.environment["PROOF_CLOUDUP_AUTH"], let url = URL(string: raw) { return url }
        return authBase(for: modernBase)
    }

    /// api.cloudup.com signs in at auth.cloudup.com: the sign-in server is the API host's `auth.`
    /// sibling. Any other host, such as a local test server, signs in where its API is.
    static func authBase(for api: URL) -> URL {
        guard var components = URLComponents(url: api, resolvingAgainstBaseURL: false),
              let host = components.host, host.hasPrefix("api.") else { return api }
        components.host = "auth." + host.dropFirst("api.".count)
        components.path = ""
        return components.url ?? api
    }

    /// WordPress.com sign-in listens on 52632 and Loominate on 52631.
    static let callbackPort: UInt16 = 52633
    /// Must match the redirect URL registered on the CloudUp OAuth app, byte for byte.
    static let redirectURI = "http://127.0.0.1:52633/callback"

    static let infoPlistClientIDKey = "ProofCloudUpClientID"
    static let infoPlistSecretKey = "ProofCloudUpClientSecret"

    /// Against a test or staging server (`PROOF_CLOUDUP_API`) the app can come from the
    /// environment, since each CloudUp server has its own registered apps.
    static var clientID: String { testValue("PROOF_CLOUDUP_CLIENT_ID") ?? infoValue(infoPlistClientIDKey) ?? "" }
    static var clientSecret: String? { testValue("PROOF_CLOUDUP_CLIENT_SECRET") ?? infoValue(infoPlistSecretKey) }

    /// Browser sign-in needs both halves of the OAuth app.
    static var isConfigured: Bool { !clientID.isEmpty && clientSecret != nil }

    // MARK: Which API

    /// Reads a reply to an unauthenticated request. The rebuilt CloudUp answers every one, the
    /// old `/1` paths included, with an OAuth error object; the original API answers 401 without
    /// one. Nil when the reply says nothing either way (an outage, a proxy page).
    static func classify(status: Int, body: Data) -> CloudUpAPI? {
        guard status == 401 else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           object["error"] as? String == "access_denied" {
            return .modern
        }
        return .legacy
    }

    /// Asks the server which API it speaks. Nil when it can't be reached or doesn't say.
    static func detect() async -> CloudUpAPI? {
        var request = URLRequest(url: legacyBase.appending(path: "user"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await HTTP.send(request) else { return nil }
        let api = classify(status: response.statusCode, body: data)
        Log.note("CloudUp at \(legacyBase.host ?? "?") speaks \(api?.rawValue ?? "an unknown API") (HTTP \(response.statusCode))")
        return api
    }

    // MARK: Plumbing

    private static func testValue(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["PROOF_CLOUDUP_API"] != nil, let value = env[name], !value.isEmpty else { return nil }
        return value
    }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
