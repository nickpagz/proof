import AppKit
import Foundation

/// The places a capture can be shared to. Each fills the Private or Public slot in Settings.
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case cloudup, wordpress
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cloudup: return "CloudUp"
        case .wordpress: return "WordPress.com"
        }
    }
}

/// A file ready to upload.
struct ShareFile {
    let url: URL
    let filename: String
    let mimeType: String
    let byteCount: Int
    /// Pixel size, for services that want it.
    let pixelSize: CGSize?
    let title: String
}

/// What a provider needs later to delete an upload. Opaque to everything else.
struct ShareReceipt: Codable, Equatable {
    var kind: ProviderKind
    var identifiers: [String: String]
}

struct ShareResult: Codable, Equatable {
    /// The link people open.
    let url: URL
    /// The raw file, when the service has one.
    let directURL: URL?
    let receipt: ShareReceipt
}

enum ShareError: LocalizedError {
    case notConfigured(String)
    case tooLarge(limit: Int, actual: Int, provider: String)
    case badCredentials(String)
    case server(String)
    case network(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return what
        case .tooLarge(let limit, let actual, let provider):
            return "\(provider) takes files up to \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)); this one is \(ByteCountFormatter.string(fromByteCount: Int64(actual), countStyle: .file))."
        case .badCredentials(let message): return message
        case .server(let message): return message
        case .network(let message): return "Couldn't reach the server: \(message)"
        case .unexpected(let message): return "Unexpected response: \(message)"
        }
    }
}

/// One sharing service. Implementations keep their secrets in the Keychain and their non-secret
/// settings in UserDefaults; S3-compatible storage can join later by implementing this.
protocol ShareProvider {
    var kind: ProviderKind { get }
    /// Signed in and ready to upload.
    var isReady: Bool { get }
    /// Who or where uploads go, for Settings and messages ("nick on CloudUp").
    var destinationLabel: String? { get }
    /// Largest file the service takes, when known.
    var maxBytes: Int? { get }

    func upload(_ file: ShareFile, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareResult
    func delete(_ receipt: ShareReceipt) async throws
}

extension ShareProvider {
    func checkSize(_ file: ShareFile) throws {
        if let maxBytes, file.byteCount > maxBytes {
            throw ShareError.tooLarge(limit: maxBytes, actual: file.byteCount, provider: kind.label)
        }
    }
}

/// Builds the provider for a kind with its stored settings.
enum ShareProviders {
    static func make(_ kind: ProviderKind) -> ShareProvider {
        switch kind {
        case .cloudup: return CloudUpProvider()
        case .wordpress: return WordPressProvider()
        }
    }
}
