import Foundation

/// How Proof identifies itself to WordPress.com. The OAuth app's ID and secret are injected into
/// the built bundle's Info.plist by Scripts/bundle.sh from .secrets/wpcom.env; neither is in git.
enum WPComConfig {
    /// `PROOF_WPCOM_API` points uploads at a test server.
    static var apiBase: URL {
        if let raw = ProcessInfo.processInfo.environment["PROOF_WPCOM_API"], let url = URL(string: raw) { return url }
        return URL(string: "https://public-api.wordpress.com")!
    }
    static let authorizeURL = URL(string: "https://public-api.wordpress.com/oauth2/authorize")!
    static let tokenURL = URL(string: "https://public-api.wordpress.com/oauth2/token")!

    /// Loominate listens on 52631; a different port lets both apps sign in side by side.
    static let callbackPort: UInt16 = 52632
    /// Must match one of the redirect URLs registered on the OAuth app, byte for byte.
    static let redirectURI = "http://127.0.0.1:52632/callback"

    static let keychainService = "io.github.nickpagz.proof.wpcom"
    static let infoPlistClientIDKey = "ProofWPComClientID"
    static let infoPlistSecretKey = "ProofWPComClientSecret"

    static var clientID: String { infoValue(infoPlistClientIDKey) ?? "" }
    static var clientSecret: String? { infoValue(infoPlistSecretKey) }

    /// Sign-in needs both halves of the OAuth app.
    static var isConfigured: Bool { !clientID.isEmpty && clientSecret != nil }

    /// VideoPress's own player page, which works for any site's video.
    static func videoPressURL(guid: String) -> URL {
        URL(string: "https://videopress.com/v/\(guid)")!
    }

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
