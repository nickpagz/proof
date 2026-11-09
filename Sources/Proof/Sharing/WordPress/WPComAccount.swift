import Foundation

/// Non-secret facts about the signed-in WordPress.com account and the site uploads go to.
/// The token itself lives in the Keychain.
struct WPComAccount: Codable, Equatable {
    var scope: String
    var userLogin: String
    var displayName: String
    var signedInAt: Date
    var siteID: Int?
    var siteName: String?
    var siteURL: String?

    private static let defaultsKey = "wpcom.account.v2"

    static func load() -> WPComAccount? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(WPComAccount.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: WPComAccount.defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Tokens scoped to one site cannot list sites; the app asks those users to sign in again.
    var hasGlobalScope: Bool { scope == "global" }

    var label: String {
        displayName.isEmpty ? userLogin : "\(displayName) (\(userLogin))"
    }

    var siteLabel: String? {
        guard let siteURL else { return siteName }
        let host = URL(string: siteURL)?.host ?? siteURL
        if let siteName, !siteName.isEmpty { return "\(siteName) (\(host))" }
        return host
    }

    mutating func select(_ site: WPComSite?) {
        siteID = site?.id
        siteName = site?.name
        siteURL = site?.url
    }
}
