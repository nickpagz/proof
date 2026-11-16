import XCTest
@testable import Proof

/// cloudup.com is moving from its original API to the rebuilt one on the same host. These cover
/// how Proof tells the two apart and the pieces of the rebuilt API's sign-in that need no network.
final class CloudUpAPITests: XCTestCase {
    func testRebuiltCloudUpAnswersUnauthenticatedRequestsWithAnOAuthError() {
        // What the rebuilt CloudUp answers for the original API's /1/user.
        let body = Data(#"{"error":"access_denied","error_description":"The resource owner or authorization server denied the request.","hint":"The JWT string must have two dots"}"#.utf8)
        XCTAssertEqual(CloudUpConfig.classify(status: 401, body: body), .modern)
    }

    func testOriginalAPIAnswersWithoutAnOAuthError() {
        XCTAssertEqual(CloudUpConfig.classify(status: 401, body: Data("invalid credentials".utf8)), .legacy)
        XCTAssertEqual(CloudUpConfig.classify(status: 401, body: Data()), .legacy)
        XCTAssertEqual(CloudUpConfig.classify(status: 401, body: Data(#"{"message":"bad credentials"}"#.utf8)), .legacy)
    }

    func testOutagesAndProxyPagesSayNothing() {
        for status in [200, 403, 404, 500, 502, 503] {
            XCTAssertNil(CloudUpConfig.classify(status: status, body: Data(#"{"error":"access_denied"}"#.utf8)), "HTTP \(status)")
        }
    }

    func testRebuiltAPIIsTheSameHostWithoutTheVersion() {
        XCTAssertEqual(CloudUpConfig.modernBase(for: URL(string: "https://api.cloudup.com/1")!).appending(path: "streams").absoluteString,
                       "https://api.cloudup.com/streams")
        XCTAssertEqual(CloudUpConfig.modernBase(for: URL(string: "http://127.0.0.1:8765/new/1")!).appending(path: "items/i1").absoluteString,
                       "http://127.0.0.1:8765/new/items/i1")
        // A base without the version is already the rebuilt API's.
        XCTAssertEqual(CloudUpConfig.modernBase(for: URL(string: "https://api.preview.cloudup.example")!).absoluteString,
                       "https://api.preview.cloudup.example")
    }

    func testSignInServerSitsBesideTheAPI() {
        XCTAssertEqual(CloudUpConfig.authBase(for: URL(string: "https://api.cloudup.com/")!).appending(path: "oauth/token").absoluteString,
                       "https://auth.cloudup.com/oauth/token")
        XCTAssertEqual(CloudUpConfig.authBase(for: URL(string: "https://api.preview.cloudup.example/")!).appending(path: "auth").absoluteString,
                       "https://auth.preview.cloudup.example/auth")
        // A test server signs in where its API is.
        XCTAssertEqual(CloudUpConfig.authBase(for: URL(string: "http://127.0.0.1:8765/new/")!).absoluteString,
                       "http://127.0.0.1:8765/new/")
    }

    func testPKCEChallengeMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        XCTAssertEqual(CloudUpAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pkce = CloudUpAuth.PKCE.make()
        XCTAssertEqual(pkce.challenge, CloudUpAuth.challenge(for: pkce.verifier))
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertNotEqual(pkce.verifier, CloudUpAuth.PKCE.make().verifier)
    }

    func testAuthorizeURLCarriesPKCEAndTheLoopbackRedirect() {
        let url = CloudUpAuth.authorizeURL(state: "s t", challenge: "abc")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.path, "/auth")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge"], "abc")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:52633/callback")
        XCTAssertEqual(items["state"], "s t")
        XCTAssertNil(items["scope"], "no scope: CloudUp grants what the registered app is allowed")
    }

    func testAccountsSavedBeforeTheRebuiltCloudUpAreOriginalAPIAccounts() throws {
        let saved = Data(#"{"username":"nick","displayName":"Nick","linkToFile":true}"#.utf8)
        let account = try JSONDecoder().decode(CloudUpAccount.self, from: saved)
        XCTAssertEqual(account.api, .legacy)
        XCTAssertTrue(account.linkToFile)

        var moved = account
        moved.api = .modern
        let reloaded = try JSONDecoder().decode(CloudUpAccount.self, from: JSONEncoder().encode(moved))
        XCTAssertEqual(reloaded, moved)
    }

    func testTokensAreRenewedAMinuteBeforeTheyExpire() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = { (seconds: TimeInterval?) in
            CloudUpTokens(accessToken: "a", refreshToken: "r", expiresAt: seconds.map { now.addingTimeInterval($0) })
        }
        XCTAssertTrue(token(3600).isFresh(at: now))
        XCTAssertFalse(token(30).isFresh(at: now))
        XCTAssertFalse(token(-10).isFresh(at: now))
        XCTAssertTrue(token(nil).isFresh(at: now), "without an expiry the token is used until refused")
    }
}
