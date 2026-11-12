import Foundation

/// Resumable (tus 1.0.0) upload to VideoPress through WordPress.com's video-uploads endpoint, using
/// POST + X-HTTP-Method-Override because the API only accepts GET and POST.
final class TusUploader: NSObject, URLSessionTaskDelegate {
    struct Completion {
        let guid: String
        let mediaID: Int
        let srcURL: String?
    }

    static let chunkSize = 10_000_000
    private static let retryDelays: [Double] = [1, 3, 5, 10, 30]

    private let session: URLSession
    private let lock = NSLock()
    private var chunkStart: Int64 = 0
    private var fileSize: Int64 = 0
    private var lastPercent = -1
    private var progress: ((Int64, Int64) -> Void)?

    init(session: URLSession) {
        self.session = session
    }

    func upload(file: URL,
                endpoint: URL,
                token: String,
                metadata: [(String, String)],
                progress: @escaping (Int64, Int64) -> Void) async throws -> Completion {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
            throw WPComError.failed("The recording file is empty.")
        }
        lock.withLock { fileSize = size; self.progress = progress; lastPercent = -1 }

        let created = try await create(endpoint: endpoint, token: token, size: size, metadata: metadata)
        let location = created.location
        let keyToken = created.keyToken ?? token
        Log.note("tus upload created: \(size) bytes, key=\(created.key ?? "?")")

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var attempt = 0
        while offset < size {
            try Task.checkCancellation()
            do {
                try handle.seek(toOffset: UInt64(offset))
                let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
                guard !chunk.isEmpty else { throw WPComError.failed("Could not read the recording file at offset \(offset).") }
                lock.withLock { chunkStart = offset }

                let response = try await patch(location, token: keyToken, offset: offset, data: chunk)
                attempt = 0
                guard let serverOffset = Self.int64Header("Upload-Offset", in: response) else {
                    throw WPComError.invalidResponse("no Upload-Offset after chunk")
                }
                offset = serverOffset
                progress(offset, size)

                if offset >= size {
                    guard let guid = response.value(forHTTPHeaderField: "x-videopress-upload-guid"),
                          let mediaIDValue = response.value(forHTTPHeaderField: "x-videopress-upload-media-id"),
                          let mediaID = Int(mediaIDValue.trimmingCharacters(in: .whitespaces)) else {
                        Log.note("final chunk accepted but no GUID; headers=\(response.allHeaderFields)")
                        throw WPComError.invalidResponse("the upload finished without a VideoPress GUID")
                    }
                    return Completion(guid: guid, mediaID: mediaID, srcURL: response.value(forHTTPHeaderField: "x-videopress-upload-src-url"))
                }
            } catch let error as WPComError where error.isRetryable && attempt < Self.retryDelays.count {
                let delay = Self.retryDelays[attempt]
                attempt += 1
                Log.note("upload chunk failed (\(error.localizedDescription)); retry \(attempt) in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
                if let resumed = try? await currentOffset(location, token: keyToken) {
                    Log.note("resuming from server offset \(resumed)")
                    offset = resumed
                }
            }
        }
        throw WPComError.invalidResponse("the upload loop ended without a final response")
    }

    // MARK: Requests

    private struct Created {
        let location: URL
        let key: String?
        let keyToken: String?
    }

    private func create(endpoint: URL, token: String, size: Int64, metadata: [(String, String)]) async throws -> Created {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        request.setValue(String(size), forHTTPHeaderField: "Upload-Length")
        let encoded = metadata.map { "\($0.0) \(Data($0.1.utf8).base64EncodedString())" }.joined(separator: ",")
        request.setValue(encoded, forHTTPHeaderField: "Upload-Metadata")
        request.setValue(token, forHTTPHeaderField: "x-videopress-upload-token")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (data, response) = try await WPComAPI.perform(request, on: session)
        guard (200..<300).contains(response.statusCode) else {
            Self.logRejection("create", response, data)
            throw WPComAPI.mapError(status: response.statusCode, data: data)
        }
        guard let locationValue = response.value(forHTTPHeaderField: "Location"),
              let location = URL(string: locationValue, relativeTo: endpoint)?.absoluteURL else {
            throw WPComError.invalidResponse("no Location header from the upload creation")
        }
        return Created(location: location,
                       key: response.value(forHTTPHeaderField: "x-videopress-upload-key"),
                       keyToken: response.value(forHTTPHeaderField: "x-videopress-upload-key-token"))
    }

    private func patch(_ location: URL, token: String, offset: Int64, data: Data) async throws -> HTTPURLResponse {
        var request = URLRequest(url: location)
        request.httpMethod = "POST"
        request.setValue("PATCH", forHTTPHeaderField: "X-HTTP-Method-Override")
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-videopress-upload-token")
        request.timeoutInterval = 600
        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await session.upload(for: request, from: data, delegate: self)
        } catch let error as URLError {
            throw WPComAPI.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw WPComError.invalidResponse("not an HTTP response") }
        switch http.statusCode {
        case 200..<300:
            return http
        case 409:
            throw WPComError.retryable("offset conflict (HTTP 409)")
        case 404:
            throw WPComError.failed("The upload session expired on the server. Retry the upload.")
        default:
            Self.logRejection("chunk at \(offset)", http, body)
            throw WPComAPI.mapError(status: http.statusCode, data: body)
        }
    }

    /// VideoPress often answers a refusal with an empty body; the headers may say more.
    private static func logRejection(_ step: String, _ response: HTTPURLResponse, _ body: Data) {
        let headers = response.allHeaderFields.compactMap { key, value -> String? in
            let name = "\(key)".lowercased()
            guard !name.contains("token"), !name.contains("cookie") else { return nil }
            return "\(name)=\(value)"
        }.sorted().joined(separator: "; ")
        Log.note("tus \(step) HTTP \(response.statusCode): body \(WPComAPI.redactedPreview(body)) headers \(headers)")
    }

    private func currentOffset(_ location: URL, token: String) async throws -> Int64 {
        var request = URLRequest(url: location)
        request.httpMethod = "GET"
        request.setValue("HEAD", forHTTPHeaderField: "X-HTTP-Method-Override")
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        request.setValue(token, forHTTPHeaderField: "x-videopress-upload-token")
        request.timeoutInterval = 20
        let (data, response) = try await WPComAPI.perform(request, on: session)
        guard (200..<300).contains(response.statusCode) else {
            throw WPComAPI.mapError(status: response.statusCode, data: data)
        }
        guard let offset = Self.int64Header("Upload-Offset", in: response) else {
            throw WPComError.invalidResponse("no Upload-Offset from HEAD")
        }
        return offset
    }

    private static func int64Header(_ name: String, in response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: name) else { return nil }
        return Int64(value.trimmingCharacters(in: .whitespaces))
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let sent = chunkStart + totalBytesSent
        let total = fileSize
        let percent = total > 0 ? Int(sent * 100 / total) : 0
        let changed = percent != lastPercent
        if changed { lastPercent = percent }
        let callback = progress
        lock.unlock()
        if changed { callback?(min(sent, total), total) }
    }
}
