// Signs and verifies Proof's update manifest (latest.json). Run it through
// Scripts/sign-manifest.sh, which compiles this file together with the app's
// UpdateManifest.swift so the tool and the app share one implementation.
import CryptoKit
import Foundation

@main
struct SignManifestTool {
    static let usage = """
    usage:
      sign-manifest keygen <private-key-file> [--force]
          Creates an Ed25519 key. Prints the key ID and the public key to add to UpdateConfig.swift.
      sign-manifest pubkey <private-key-file>
      sign-manifest sign --key FILE --out FILE --version X.Y.Z --build N --zip FILE --zip-url URL
                         [--bundle-id ID] [--min-os VERSION] [--notes-file FILE]
                         [--release-notes-url URL] [--allows-identity-change]
      sign-manifest verify --manifest FILE --public-key BASE64 [--zip FILE] [--bundle-id ID]
          Exit status 0 only when the signature, and the zip's hash and size if given, all check out.
    """

    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write("sign-manifest: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Options {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        static let booleanFlags: Set<String> = ["--allows-identity-change", "--force"]

        init(_ args: [String]) throws {
            var i = 0
            while i < args.count {
                let arg = args[i]
                if Options.booleanFlags.contains(arg) {
                    flags.insert(arg)
                } else if arg.hasPrefix("--") {
                    guard i + 1 < args.count else { throw Failure("\(arg) needs a value") }
                    values[arg] = args[i + 1]
                    i += 1
                } else {
                    positional.append(arg)
                }
                i += 1
            }
        }

        func require(_ name: String) throws -> String {
            guard let value = values[name] else { throw Failure("missing \(name)") }
            return value
        }
    }

    static func run(_ args: [String]) throws {
        guard let command = args.first else { print(usage); exit(64) }
        let options = try Options(Array(args.dropFirst()))
        switch command {
        case "keygen": try keygen(options)
        case "pubkey": try pubkey(options)
        case "sign": try sign(options)
        case "verify": try verify(options)
        case "--help", "-h", "help": print(usage)
        default: throw Failure("unknown command \(command)\n\(usage)")
        }
    }

    // MARK: Keys

    static func privateKeyPath(_ options: Options) throws -> String {
        guard let path = options.positional.first else { throw Failure("give the private key file path") }
        return path
    }

    static func loadPrivateKey(_ path: String) throws -> Curve25519.Signing.PrivateKey {
        guard let raw = FileManager.default.contents(atPath: path) else { throw Failure("cannot read \(path)") }
        guard raw.count == 32 else { throw Failure("\(path) is not a 32-byte Ed25519 private key") }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    static func describe(_ key: Curve25519.Signing.PublicKey) {
        let id = UpdateManifest.keyID(for: key)
        print("keyId:      \(id)")
        print("public key: \(key.rawRepresentation.base64EncodedString())")
        print("Add this line to publicKeys in Sources/Proof/Update/UpdateConfig.swift:")
        print("        \"\(id)\": \"\(key.rawRepresentation.base64EncodedString())\",")
    }

    static func keygen(_ options: Options) throws {
        let path = try privateKeyPath(options)
        if FileManager.default.fileExists(atPath: path) && !options.flags.contains("--force") {
            throw Failure("\(path) already exists; pass --force to replace it (builds signed with the old key will stop updating)")
        }
        let key = Curve25519.Signing.PrivateKey()
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard FileManager.default.createFile(atPath: path, contents: key.rawRepresentation,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Failure("could not write \(path)")
        }
        print("Wrote the private key to \(path). Keep it out of git and back it up somewhere safe (1Password):")
        print("without it no future release can be signed, and with it anyone can publish an update.")
        describe(key.publicKey)
    }

    static func pubkey(_ options: Options) throws {
        describe(try loadPrivateKey(try privateKeyPath(options)).publicKey)
    }

    // MARK: Sign

    static func sign(_ options: Options) throws {
        let key = try loadPrivateKey(try options.require("--key"))
        let zipPath = try options.require("--zip")
        guard let zipData = FileManager.default.contents(atPath: zipPath) else { throw Failure("cannot read \(zipPath)") }
        guard let zipURL = URL(string: try options.require("--zip-url")), zipURL.scheme != nil else {
            throw Failure("--zip-url must be an absolute URL")
        }
        guard let build = Int(try options.require("--build")) else { throw Failure("--build must be an integer") }
        let version = try options.require("--version")
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw Failure("--version must look like 1.2.3")
        }
        var notes = ""
        if let notesPath = options.values["--notes-file"] {
            guard let data = FileManager.default.contents(atPath: notesPath), let text = String(data: data, encoding: .utf8) else {
                throw Failure("cannot read \(notesPath)")
            }
            notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let payload = UpdatePayload(
            bundleID: options.values["--bundle-id"] ?? "io.github.nickpagz.proof",
            version: version,
            build: build,
            minimumSystemVersion: options.values["--min-os"] ?? "26.0",
            publishedAt: Date(),
            zip: .init(name: (zipPath as NSString).lastPathComponent, url: zipURL,
                       sha256: UpdateManifest.sha256Hex(of: zipData), size: zipData.count),
            notes: notes,
            releaseNotesURL: options.values["--release-notes-url"].flatMap(URL.init(string:)),
            allowsIdentityChange: options.flags.contains("--allows-identity-change"))
        let envelope = try UpdateManifest.sign(payload, with: key)
        let out = try options.require("--out")
        try envelope.write(to: URL(fileURLWithPath: out))
        print("Signed \(out): \(payload.version) (\(payload.build)) keyId \(UpdateManifest.keyID(for: key.publicKey))")
        print("  zip \(payload.zip.name) \(payload.zip.size) bytes sha256 \(payload.zip.sha256)")
    }

    // MARK: Verify

    static func verify(_ options: Options) throws {
        let manifestPath = try options.require("--manifest")
        guard let data = FileManager.default.contents(atPath: manifestPath) else { throw Failure("cannot read \(manifestPath)") }
        let publicKeyBase64 = try options.require("--public-key")
        guard let raw = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw Failure("--public-key is not a base64 Ed25519 public key")
        }
        let keyID = UpdateManifest.keyID(for: publicKey)
        let payload = try UpdateManifest.verify(data, publicKeys: [keyID: publicKeyBase64])
        if let expected = options.values["--bundle-id"], payload.bundleID != expected {
            throw UpdateError.wrongBundle(payload.bundleID)
        }
        if let zipPath = options.values["--zip"] {
            guard let zip = FileManager.default.contents(atPath: zipPath) else { throw Failure("cannot read \(zipPath)") }
            guard zip.count == payload.zip.size else { throw UpdateError.sizeMismatch(expected: payload.zip.size, actual: zip.count) }
            guard UpdateManifest.sha256Hex(of: zip) == payload.zip.sha256 else { throw UpdateError.hashMismatch }
        }
        print("OK: signature valid (keyId \(keyID))\(options.values["--zip"] != nil ? ", zip hash and size match" : "")")
        print("  \(payload.bundleID) \(payload.version) (\(payload.build)), macOS \(payload.minimumSystemVersion)+, published \(payload.publishedAt)")
        print("  \(payload.zip.url.absoluteString)")
        print("  sha256 \(payload.zip.sha256) size \(payload.zip.size)")
        if payload.allowsIdentityChange { print("  allowsIdentityChange: true") }
    }
}
