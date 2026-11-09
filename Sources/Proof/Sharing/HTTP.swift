import Foundation

/// Proof's saved sign-ins, keyed by service and account, all kept in one generic-password item
/// that is read once per launch. Without an Apple Team ID, macOS ties Keychain access to the exact
/// build, so each new build (and each update) must be allowed once; one item read once keeps that
/// to a single prompt. No data-protection or sync flags: those need entitlements an unnotarized
/// build can't carry.
enum Keychain {
    enum Failure: LocalizedError {
        case status(OSStatus)
        case denied
        var errorDescription: String? {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "Keychain: \(message)"
            case .denied:
                return "Proof wasn't allowed to read its saved sign-ins. Quit and reopen Proof, then choose Always Allow."
            }
        }
    }

    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.nickpagz.proof",
        kSecAttrAccount as String: "sign-ins",
    ]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?
    /// Set when the prompt was refused, so Proof doesn't ask again until it's relaunched.
    nonisolated(unsafe) private static var denied = false

    static func save(_ secret: String, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        // Writing without having read would drop the other sign-ins.
        guard var entries = entries() else { throw Failure.denied }
        entries["\(service)/\(account)"] = secret
        try write(entries)
    }

    static func load(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries()?["\(service)/\(account)"]
    }

    static func delete(service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        guard var entries = entries() else { return }
        entries["\(service)/\(account)"] = nil
        try? write(entries)
    }

    /// The saved sign-ins, from memory after the first read. Nil when access was refused.
    private static func entries() -> [String: String]? {
        if let cache { return cache }
        if denied { return nil }
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            cache = (result as? Data).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        case errSecItemNotFound:
            cache = [:]
        default:
            denied = true
            return nil
        }
        return cache
    }

    private static func write(_ entries: [String: String]) throws {
        if entries.isEmpty {
            let status = SecItemDelete(item as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
        } else {
            let data = try JSONEncoder().encode(entries)
            var add = item
            add[kSecAttrLabel as String] = "Proof sign-ins"
            add[kSecValueData as String] = data
            var status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            }
            guard status == errSecSuccess else { throw Failure.status(status) }
        }
        cache = entries
    }
}

/// multipart/form-data written to a temporary file, so large uploads stream from disk and
/// report progress.
struct MultipartForm {
    let boundary = "ProofBoundary-\(UUID().uuidString)"
    private var parts: [(header: String, body: Body)] = []

    private enum Body {
        case text(String)
        case file(URL)
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func add(_ name: String, _ value: String) {
        parts.append(("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n", .text(value)))
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, url: URL) {
        let safeName = filename.replacingOccurrences(of: "\"", with: "'")
        parts.append(("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n", .file(url)))
    }

    /// Writes the body and returns its location; the caller deletes it.
    func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("proof-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        for part in parts {
            out.write(Data("--\(boundary)\r\n\(part.header)".utf8))
            switch part.body {
            case .text(let value):
                out.write(Data(value.utf8))
            case .file(let source):
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
            }
            out.write(Data("\r\n".utf8))
        }
        out.write(Data("--\(boundary)--\r\n".utf8))
        return url
    }
}

/// URLSession calls shared by the providers.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        config.httpAdditionalHeaders = ["User-Agent": UpdateConfig.userAgent]
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ShareError.unexpected("not an HTTP response") }
            return (data, http)
        } catch let error as URLError {
            throw ShareError.network(error.localizedDescription)
        }
    }

    /// Uploads `file` as the body of `request`, reporting the fraction sent.
    static func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.upload(for: request, fromFile: file, delegate: ProgressDelegate(progress))
            guard let http = response as? HTTPURLResponse else { throw ShareError.unexpected("not an HTTP response") }
            return (data, http)
        } catch let error as URLError {
            throw ShareError.network(error.localizedDescription)
        }
    }

    /// A short, readable message from a JSON or text error body.
    static func message(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = (object["message"] as? String) ?? (object["error_description"] as? String) ?? (object["error"] as? String) {
                return "\(message) (HTTP \(status))"
            }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return "\(message) (HTTP \(status))"
            }
        }
        let text = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.hasPrefix("<") ? "HTTP \(status)" : "\(text) (HTTP \(status))"
    }

    static func basicAuth(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }
}
