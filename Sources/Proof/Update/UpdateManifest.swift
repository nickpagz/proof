import CryptoKit
import Foundation

// The update feed is one JSON file, `latest.json`: an envelope whose `payload` is the payload's
// JSON bytes (base64 in transit) and whose `signature` is an Ed25519 signature over exactly those
// bytes. Signing opaque bytes needs no JSON canonicalisation on either side. One signature binds
// the version, the download URL and the zip's SHA-256 together: a swapped zip fails the hash, an
// edited manifest fails the signature. This file is compiled into the app and into the signing
// tool (Scripts/sign-manifest.swift), so both sides share one implementation. Keep it free of
// AppKit and app types.

struct UpdateEnvelope: Codable, Equatable {
    static let currentFormat = 1
    var format: Int
    var keyId: String
    var payload: Data
    var signature: Data
}

struct UpdatePayload: Codable, Equatable {
    struct Archive: Codable, Equatable {
        var name: String
        var url: URL
        var sha256: String
        var size: Int
    }

    var bundleID: String
    var version: String
    var build: Int
    var minimumSystemVersion: String
    var publishedAt: Date
    var zip: Archive
    var notes: String
    var releaseNotesURL: URL?
    /// Only the release that moves to a new signing identity (for example Developer ID) sets this.
    /// The installer then warns that permissions must be granted again instead of refusing.
    var allowsIdentityChange: Bool

    init(bundleID: String, version: String, build: Int, minimumSystemVersion: String, publishedAt: Date,
         zip: Archive, notes: String, releaseNotesURL: URL?, allowsIdentityChange: Bool) {
        self.bundleID = bundleID; self.version = version; self.build = build
        self.minimumSystemVersion = minimumSystemVersion; self.publishedAt = publishedAt; self.zip = zip
        self.notes = notes; self.releaseNotesURL = releaseNotesURL; self.allowsIdentityChange = allowsIdentityChange
    }

    // Optional fields default so an older build can read a manifest with new optional keys dropped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        version = try c.decode(String.self, forKey: .version)
        build = try c.decode(Int.self, forKey: .build)
        minimumSystemVersion = try c.decodeIfPresent(String.self, forKey: .minimumSystemVersion) ?? "26.0"
        publishedAt = try c.decode(Date.self, forKey: .publishedAt)
        zip = try c.decode(Archive.self, forKey: .zip)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        releaseNotesURL = try c.decodeIfPresent(URL.self, forKey: .releaseNotesURL)
        allowsIdentityChange = try c.decodeIfPresent(Bool.self, forKey: .allowsIdentityChange) ?? false
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    /// Version first, numerically per dot-component; the build number only breaks ties.
    func isNewer(thanVersion version: String, build: Int) -> Bool {
        let mine = AppVersion(self.version), theirs = AppVersion(version)
        if mine != theirs { return mine > theirs }
        return self.build > build
    }

    var minimumOSIsSatisfied: Bool {
        let parts = AppVersion(minimumSystemVersion).components
        let needed = OperatingSystemVersion(majorVersion: parts.count > 0 ? parts[0] : 0,
                                            minorVersion: parts.count > 1 ? parts[1] : 0,
                                            patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(needed)
    }
}

/// "x.y.z" compared numerically per component; missing components count as 0, so 1.0 == 1.0.0
/// and 0.10.0 > 0.9.0. Non-numeric suffixes ("1.2.3-beta") are ignored.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init(_ string: String) {
        components = string.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    var description: String { components.map(String.init).joined(separator: ".") }
}

enum UpdateManifest {
    /// Key IDs are the first 8 hex characters of SHA-256 over the raw public key, so the ID is
    /// derived from the key rather than chosen.
    static func keyID(for publicKey: Curve25519.Signing.PublicKey) -> String {
        String(hex(SHA256.hash(data: publicKey.rawRepresentation)).prefix(8))
    }

    static func sign(_ payload: UpdatePayload, with key: Curve25519.Signing.PrivateKey) throws -> Data {
        let bytes = try UpdatePayload.encoder().encode(payload)
        let envelope = UpdateEnvelope(format: UpdateEnvelope.currentFormat,
                                      keyId: keyID(for: key.publicKey),
                                      payload: bytes,
                                      signature: try key.signature(for: bytes))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    /// Checks the envelope's shape and signature against the known keys and returns the payload.
    /// Does not judge the payload (bundle ID, version, OS); callers do that with context.
    static func verify(_ data: Data, publicKeys: [String: String]) throws -> UpdatePayload {
        let envelope: UpdateEnvelope
        do {
            envelope = try JSONDecoder().decode(UpdateEnvelope.self, from: data)
        } catch {
            throw UpdateError.badManifest("not an update manifest")
        }
        guard envelope.format == UpdateEnvelope.currentFormat else {
            throw UpdateError.badManifest("manifest format \(envelope.format) is newer than this build understands")
        }
        guard let keyBase64 = publicKeys[envelope.keyId],
              let raw = Data(base64Encoded: keyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw UpdateError.unknownKey(envelope.keyId)
        }
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw UpdateError.badSignature
        }
        do {
            return try UpdatePayload.decoder().decode(UpdatePayload.self, from: envelope.payload)
        } catch {
            throw UpdateError.badManifest("the signed payload is missing fields")
        }
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(of data: Data) -> String { hex(SHA256.hash(data: data)) }
}
