import Foundation

/// Fetches and verifies `latest.json`. A successful result is signed by a known key and names this
/// app; whether it is newer or installable is decided by the caller.
struct UpdateFeed {
    let session: URLSession

    init(session: URLSession = UpdateFeed.makeSession()) {
        self.session = session
    }

    /// No caching anywhere: a stale manifest would hide releases, and a cached zip could outlive
    /// the manifest that vouched for it.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": UpdateConfig.userAgent]
        return URLSession(configuration: config)
    }

    func fetchManifest(from url: URL = UpdateConfig.feedURL) async throws -> UpdatePayload {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.feedUnavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.feedUnavailable("no HTTP response") }
        switch http.statusCode {
        case 200: break
        case 404: throw UpdateError.feedUnavailable("no published release yet (HTTP 404)")
        default: throw UpdateError.feedUnavailable("HTTP \(http.statusCode)")
        }
        guard data.count <= 64 * 1024 else { throw UpdateError.badManifest("the manifest is too large") }
        let payload = try UpdateManifest.verify(data, publicKeys: UpdateConfig.publicKeys)
        guard payload.bundleID == UpdateConfig.bundleID else { throw UpdateError.wrongBundle(payload.bundleID) }
        return payload
    }
}
