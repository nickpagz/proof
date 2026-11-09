import Foundation

/// A site the signed-in user belongs to, with what matters for sharing: can they upload to its
/// media library, and does it have VideoPress (Calypso's `canUseVideoPress` rule) for recordings.
struct WPComSite: Identifiable, Equatable, Decodable {
    let id: Int
    let name: String
    let url: String
    let isJetpack: Bool
    let isAtomic: Bool
    let isPrivate: Bool
    let canUpload: Bool
    let hasVideoPress: Bool

    var isEligible: Bool { canUpload }
    var host: String { URL(string: url)?.host ?? url }
    var label: String { name.isEmpty ? host : "\(name) (\(host))" }

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name
        case url = "URL"
        case jetpack
        case jetpackModules = "jetpack_modules"
        case isPrivate = "is_private"
        case capabilities
        case options
    }

    private struct Options: Decodable {
        let videopressEnabled: Bool?
        let isWpcomAtomic: Bool?

        enum CodingKeys: String, CodingKey {
            case videopressEnabled = "videopress_enabled"
            case isWpcomAtomic = "is_wpcom_atomic"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        isJetpack = (try? c.decode(Bool.self, forKey: .jetpack)) ?? false
        isPrivate = (try? c.decode(Bool.self, forKey: .isPrivate)) ?? false
        let modules = (try? c.decode([String].self, forKey: .jetpackModules)) ?? []
        // `capabilities` and `options` come back as empty arrays for sites the user cannot edit.
        let capabilities = (try? c.decode([String: Bool].self, forKey: .capabilities)) ?? [:]
        canUpload = capabilities["upload_files"] ?? false
        let options = try? c.decode(Options.self, forKey: .options)
        isAtomic = options?.isWpcomAtomic ?? false
        hasVideoPress = (options?.videopressEnabled ?? false) || (isJetpack && modules.contains("videopress"))
    }

    init(id: Int, name: String, url: String, isJetpack: Bool = false, isAtomic: Bool = false,
         isPrivate: Bool = false, canUpload: Bool = true, hasVideoPress: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.isJetpack = isJetpack
        self.isAtomic = isAtomic; self.isPrivate = isPrivate; self.canUpload = canUpload; self.hasVideoPress = hasVideoPress
    }
}
