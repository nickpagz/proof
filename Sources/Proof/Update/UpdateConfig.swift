import Foundation

/// Where updates come from and which keys may sign them.
enum UpdateConfig {
    static let bundleID = "io.github.nickpagz.proof"
    static let repository = "nickpagz/proof"

    /// GitHub redirects this to the newest non-draft, non-prerelease release's asset. It is a plain
    /// download, not an API call, so it has no rate limit. It is a 404 while the repo is private.
    static let defaultFeedURL = URL(string: "https://github.com/\(repository)/releases/latest/download/latest.json")!

    /// Override order: environment, then `defaults write io.github.nickpagz.proof updateFeedURL …`,
    /// then GitHub. Used to test the updater against `python3 -m http.server -d dist`.
    static let feedEnvironmentKey = "PROOF_UPDATE_FEED"
    static let feedDefaultsKey = "updateFeedURL"

    /// Ed25519 public keys by key ID (Scripts/sign-manifest.sh keygen prints the line to add).
    /// To rotate, add the new key, ship a release, and remove the old key once no build that
    /// only knows the old key is still in use.
    static let publicKeys: [String: String] = [
        "56b096b1": "C/GcMxDMHm90yH8CqAhbn2rgsF3fRI/65sTcGAfbRc0=",   // created 2026-11-08
    ]

    /// Shown when the app cannot replace itself; the same line the README gives.
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/\(repository)/trunk/install.sh | sh"

    static let maximumZipSize = 200 * 1024 * 1024
    static let checkInterval: TimeInterval = 86_400
    static let initialCheckDelay: TimeInterval = 20

    static var feedOverride: URL? {
        if let raw = ProcessInfo.processInfo.environment[feedEnvironmentKey], let url = URL(string: raw) { return url }
        if let raw = UserDefaults.standard.string(forKey: feedDefaultsKey), let url = URL(string: raw) { return url }
        return nil
    }

    static var feedURL: URL { feedOverride ?? defaultFeedURL }
    static var usesFeedOverride: Bool { feedOverride != nil }

    /// The real feed names an absolute, tag-pinned URL. With a feed override the zip is looked up
    /// next to the manifest instead, so a local folder served over HTTP works without editing it.
    static func zipURL(for payload: UpdatePayload) -> URL {
        if let override = feedOverride, let local = URL(string: payload.zip.name, relativeTo: override)?.absoluteURL {
            return local
        }
        return payload.zip.url
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Proof/\(version)"
    }
}
