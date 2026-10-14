import Foundation
@testable import ScoreKit
import XCTest

/// Answers requests from a closure instead of the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: Any]))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let (status, body) = Self.handler?(request) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Hands out "old" until asked to renew, then "new".
actor StubSession: SessionProvider {
    var token = "old"
    var renewals = 0
    func accessToken() async -> String? { token }
    func renewAccessToken(rejected: String) async -> String? {
        renewals += 1
        token = "new"
        return token
    }
}

final class AccountTests: XCTestCase {
    var urlSession: URLSession!
    let config = OMRServerConfig.parse("server.test", device: DeviceInfo(installID: "install-1", appVersion: "1.0"))!

    override func setUp() {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        urlSession = URLSession(configuration: c)
        StubProtocol.seen = []
    }

    func testRejectedTokenIsRenewedOnceAndTheRequestRetried() async throws {
        StubProtocol.handler = { r in
            r.value(forHTTPHeaderField: "Authorization") == "Bearer new"
                ? (200, ["scores": [], "collections": ["modified": NSNull()]])
                : (401, ["error": "Sign in to continue.", "code": "unauthorised"])
        }
        let session = StubSession()
        let listing = try await LibraryServer(config: config, auth: session, session: urlSession).listing()
        XCTAssertTrue(listing.scores.isEmpty)
        let renewals = await session.renewals
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(StubProtocol.seen.count, 2)
        XCTAssertEqual(StubProtocol.seen.first?.value(forHTTPHeaderField: "X-Device"), "install-1", "every request says which install it is")
    }

    func testSignInMistakesAreNotTreatedAsAnExpiredSession() async {
        StubProtocol.handler = { _ in (401, ["error": "Wrong email or password.", "code": "bad_credentials"]) }
        do {
            _ = try await AccountClient(config: config, session: urlSession).signIn(email: "a@b.co", password: "x")
            XCTFail("should throw")
        } catch let e as ServerError {
            XCTAssertEqual(e, ServerError(status: 401, code: "bad_credentials", message: "Wrong email or password."))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSigningOutErasesTheLocalLibraryWithoutTombstones() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = ScoreLibrary(directory: dir)
        let score = Score.blank(measures: 2)
        try library.save(score, original: Data("%PDF".utf8))
        library.updateCollections { $0.collections.append(ScoreCollection(name: "Book 1", scoreIds: [score.id])) }
        let gone = Score.blank(measures: 1)
        try library.save(gone)
        library.delete(gone.id)
        library.eraseAll()
        XCTAssertTrue(library.summaries.value.isEmpty)
        XCTAssertTrue(library.collections.value.collections.isEmpty)
        XCTAssertTrue(library.tombstones.isEmpty, "nothing here was deleted: it just isn't on this device any more")
        XCTAssertTrue(ScoreLibrary(directory: dir).summaries.value.isEmpty, "and it stays gone after a relaunch")
    }

    func testSignInResultDecodes() throws {
        let json = #"{"accessToken":"a","refreshToken":"r","expiresIn":3600,"mergedScores":2,"user":{"id":"u","displayName":"","email":null,"emailVerified":false,"isGuest":true,"providers":[],"created":1}}"#
        let r = try JSONDecoder().decode(SignInResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.user.label, "Guest")
        XCTAssertEqual(r.tokens(now: Date(timeIntervalSince1970: 0)).expires, Date(timeIntervalSince1970: 3600))
    }
}
