import XCTest
@testable import Proof

final class WordPressDeletionTests: XCTestCase {
    private var savedEnvironment: [String: String] = [:]
    private let receipt = ShareReceipt(kind: .wordpress, identifiers: ["site": "123", "media": "71"])
    private let unauthorized = (403, #"{"error":"unauthorized","message":"User is not authorized delete media"}"#)
    private let missing = (404, #"{"error":"unknown_media","message":"Unknown Media"}"#)

    override func setUp() {
        super.setUp()
        // Never read the developer's Keychain or send requests to a real service.
        for key in ["PROOF_WPCOM_API", "PROOF_WPCOM_TOKEN"] {
            savedEnvironment[key] = ProcessInfo.processInfo.environment[key]
        }
        setenv("PROOF_WPCOM_API", "https://proof-delete.test", 1)
        setenv("PROOF_WPCOM_TOKEN", "test-token", 1)
        MediaProtocol.reset([])
    }

    override func tearDown() {
        for key in ["PROOF_WPCOM_API", "PROOF_WPCOM_TOKEN"] {
            if let value = savedEnvironment[key] { setenv(key, value, 1) }
            else { unsetenv(key) }
        }
        super.tearDown()
    }

    private func provider() -> WordPressProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaProtocol.self]
        return WordPressProvider(account: nil, deletionSession: URLSession(configuration: configuration))
    }

    func testMissingAttachmentBehindUnauthorizedResponse() async throws {
        MediaProtocol.reset([unauthorized, missing])
        let result = try await provider().delete(receipt)
        XCTAssertEqual(result, .alreadyMissing)
        XCTAssertEqual(MediaProtocol.requests.map(\.httpMethod), ["POST", "GET"])
        XCTAssertEqual(MediaProtocol.requests.map { $0.url!.path }, [
            "/rest/v1.1/sites/123/media/71/delete", "/rest/v1.1/sites/123/media/71"
        ])
        XCTAssertTrue(MediaProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    func testExplicitMissingAttachmentNeedsNoLookup() async throws {
        MediaProtocol.reset([missing])
        let result = try await provider().delete(receipt)
        XCTAssertEqual(result, .alreadyMissing)
        XCTAssertEqual(MediaProtocol.requests.count, 1)
    }

    func testExistingAttachmentDeletesNormally() async throws {
        MediaProtocol.reset([(200, #"{"ID":71,"status":"deleted"}"#)])
        let result = try await provider().delete(receipt)
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(MediaProtocol.requests.count, 1)
    }

    func testReadableAttachmentWithDeleteDeniedIsNotAnExpiredSignIn() async {
        MediaProtocol.reset([unauthorized, (200, #"{"ID":71}"#)])
        do {
            _ = try await provider().delete(receipt)
            XCTFail("Delete permission was denied")
        } catch ShareError.server(let message) {
            XCTAssertTrue(message.contains("permission to delete"))
            XCTAssertFalse(message.contains("Sign in again"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testExpiredTokenIsNotTreatedAsMissing() async {
        for status in [401, 403] {
            MediaProtocol.reset([(status, #"{"error":"invalid_token","message":"Token expired"}"#)])
            do {
                _ = try await provider().delete(receipt)
                XCTFail("Invalid token must fail")
            } catch ShareError.badCredentials { }
            catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(MediaProtocol.requests.count, 1)
        }
    }

    func testOtherFailuresNeverCountAsMissing() async {
        let failures: [[(Int, String)]] = [
            [(404, #"{"error":"unknown_blog"}"#)],
            [(404, "not found")],
            [(500, "server error")],
            [unauthorized, unauthorized],
            [unauthorized, (401, #"{"error":"invalid_token"}"#)],
            [unauthorized, (404, #"{"error":"unknown_blog"}"#)],
            [unauthorized, (404, "not found")],
            [unauthorized, (500, "server error")],
            [unauthorized] // The stub fails the lookup with a network error.
        ]
        for replies in failures {
            MediaProtocol.reset(replies)
            do {
                _ = try await provider().delete(receipt)
                XCTFail("Must preserve failure: \(replies)")
            } catch { }
        }
    }

    @MainActor
    func testHistoryRemovalAndMessageForMissingMedia() async throws {
        for replies in [[unauthorized, missing], [missing]] {
            try await checkHistory(replies: replies, removed: true, reportsMissing: true)
        }
    }

    @MainActor
    func testNormalDeleteRemovesHistoryWithoutMissingMessage() async throws {
        try await checkHistory(replies: [(200, "{}")], removed: true, reportsMissing: false)
    }

    @MainActor
    func testHistoryAndSavedSignInSurviveFailures() async throws {
        for replies in [[unauthorized, (200, #"{"ID":71}"#)],
                        [(401, #"{"error":"invalid_token"}"#)],
                        [unauthorized, unauthorized],
                        [unauthorized, (500, "server error")],
                        [unauthorized],
                        [(404, #"{"error":"unknown_blog"}"#)]] {
            try await checkHistory(replies: replies, removed: false, reportsMissing: false)
        }
    }

    @MainActor
    private func checkHistory(replies: [(Int, String)], removed: Bool, reportsMissing: Bool) async throws {
        MediaProtocol.reset(replies)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let historyURL = folder.appendingPathComponent("shares.json")
        let history = ShareHistory(fileURL: historyURL)
        let record = ShareRecord(date: Date(), title: "Test screenshot", visibility: .public,
                                 result: ShareResult(url: URL(string: "https://example.com/image.png")!,
                                                     directURL: nil, receipt: receipt))
        let unrelated = ShareRecord(date: Date(), title: "Keep this capture", visibility: .public, result: record.result)
        history.add(unrelated)
        history.add(record)
        let provider = provider()
        let controller = SharingController(history: history, makeProvider: { _ in provider })
        controller.historyStatus = "Stale status"
        controller.historyError = "Stale error"
        let task = controller.deleteRemote(record)
        XCTAssertTrue(controller.deleting.contains(record.id))
        await task.value
        XCTAssertEqual(history.records.contains { $0.id == record.id }, !removed)
        XCTAssertTrue(history.records.contains { $0.id == unrelated.id })
        let reloaded = ShareHistory(fileURL: historyURL)
        XCTAssertEqual(reloaded.records.map(\.id), history.records.map(\.id))
        XCTAssertEqual(controller.historyError == nil, removed)
        XCTAssertEqual(controller.historyStatus != nil, reportsMissing)
        if reportsMissing {
            XCTAssertTrue(controller.historyStatus?.contains("no longer exists on WordPress.com") == true)
            XCTAssertTrue(controller.historyStatus?.contains("Removed it from Recent shares") == true)
        }
        XCTAssertTrue(controller.deleting.isEmpty)
        XCTAssertEqual(WPComToken.load(), "test-token")
    }
}

private final class MediaProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var replies: [(Int, String)] = []
    private static var recordedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    static func reset(_ responses: [(Int, String)]) {
        lock.lock(); defer { lock.unlock() }
        replies = responses
        recordedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()
        guard let (status, body) = reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
