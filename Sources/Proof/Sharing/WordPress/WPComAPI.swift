import Foundation

/// Strict percent-encoding for OAuth query strings and form bodies.
enum FormEncoding {
    static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}

/// Bearer-authenticated calls to public-api.wordpress.com.
struct WPComAPI {
    let token: String
    let session: URLSession

    struct Me: Decodable {
        let username: String
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case username
            case displayName = "display_name"
        }
    }

    struct UploadToken: Decodable {
        let uploadToken: String
        let uploadURL: String?
        let uploadBlogID: Int?

        enum CodingKeys: String, CodingKey {
            case uploadToken = "upload_token"
            case uploadURL = "upload_url"
            case uploadBlogID = "upload_blog_id"
        }

        /// WordPress.com omits upload_url; Jetpack derives it from the blog id the same way.
        func endpoint(defaultBlogID: Int) -> URL {
            if let uploadURL, let url = URL(string: uploadURL) { return url }
            return WPComConfig.apiBase.appending(path: "rest/v1.1/video-uploads/\(uploadBlogID ?? defaultBlogID)")
        }
    }

    func me() async throws -> Me {
        let data = try await send(path: "rest/v1.1/me", method: "GET", form: nil)
        return try Self.decode(Me.self, from: data)
    }

    private struct SitesResponse: Decodable {
        let sites: [WPComSite]
    }

    /// Every site the user belongs to, with the fields needed to judge VideoPress eligibility.
    func sites() async throws -> [WPComSite] {
        let data = try await send(path: "rest/v1.1/me/sites", method: "GET", form: nil, query: [
            ("fields", "ID,name,URL,jetpack,jetpack_modules,is_private,capabilities,options"),
            ("options", "videopress_enabled,is_wpcom_atomic"),
            ("site_visibility", "all"),
        ])
        return try Self.decode(SitesResponse.self, from: data).sites
    }

    func videoPressUploadToken(blogID: Int) async throws -> UploadToken {
        let data = try await send(path: "wpcom/v2/sites/\(blogID)/media/videopress-upload-jwt", method: "POST", form: [])
        return try Self.decode(UploadToken.self, from: data)
    }

    func setMediaTitle(blogID: Int, mediaID: Int, title: String) async throws {
        _ = try await send(path: "rest/v1.1/sites/\(blogID)/media/\(mediaID)", method: "POST", form: [("title", title)])
    }

    // MARK: Plumbing

    private func send(path: String, method: String, form: [(String, String)]?, query: [(String, String)] = []) async throws -> Data {
        var components = URLComponents(url: WPComConfig.apiBase.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.percentEncodedQuery = FormEncoding.encode(query) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(FormEncoding.encode(form).utf8)
        }
        let (data, response) = try await Self.perform(request, on: session)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapError(status: response.statusCode, data: data)
        }
        return data
    }

    static func perform(_ request: URLRequest, on session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WPComError.invalidResponse("not an HTTP response")
            }
            return (data, http)
        } catch let error as URLError {
            throw Self.map(error)
        }
    }

    static func map(_ error: URLError) -> WPComError {
        switch error.code {
        case .cancelled: return .cancelled
        case .userAuthenticationRequired: return .authExpired
        default: return .retryable(error.localizedDescription)
        }
    }

    static func mapError(status: Int, data: Data) -> WPComError {
        let body = parseErrorBody(data)
        let message = body.message.isEmpty ? "HTTP \(status)" : "\(body.message) (HTTP \(status))"
        switch status {
        case 401, 403:
            return .authExpired
        case 400 where ["invalid_token", "unauthorized", "authorization_required"].contains(body.code ?? ""):
            return .authExpired
        case 408, 423, 429, 500...599:
            return .retryable(message)
        default:
            return .failed(message)
        }
    }

    /// wpcom/v2 answers { code, message }; rest/v1.1 answers { error, message }; OAuth answers { error, error_description }.
    static func parseErrorBody(_ data: Data) -> (code: String?, message: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        let code = (object["code"] as? String) ?? (object["error"] as? String)
        let message = (object["message"] as? String) ?? (object["error_description"] as? String) ?? code ?? ""
        return (code, message)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let preview = redactedPreview(data)
            Log.note("could not decode \(type): \(error); body: \(preview)")
            throw WPComError.invalidResponse("could not decode \(type); body: \(preview)")
        }
    }

    /// JSON with secret-looking string values masked, for logs and error messages.
    static func redactedPreview(_ data: Data, limit: Int = 400) -> String {
        func mask(_ value: Any, key: String = "") -> Any {
            switch value {
            case let dict as [String: Any]:
                return dict.reduce(into: [String: Any]()) { $0[$1.key] = mask($1.value, key: $1.key) }
            case let array as [Any]:
                return array.map { mask($0) }
            case let string as String:
                let sensitive = ["token", "jwt", "secret", "authorization"].contains { key.lowercased().contains($0) }
                return sensitive || string.count > 80 ? "…(\(string.count) chars)" : string
            default:
                return value
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let masked = try? JSONSerialization.data(withJSONObject: mask(object), options: [.sortedKeys]),
              let text = String(data: masked, encoding: .utf8) else {
            return String(decoding: data.prefix(limit), as: UTF8.self)
        }
        return String(text.prefix(limit))
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }
}
