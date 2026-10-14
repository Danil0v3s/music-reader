import Foundation

/// The signed-in person, as the server describes them.
public struct AccountUser: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var email: String?
    public var emailVerified: Bool
    public var isGuest: Bool
    /// Ways to sign in: "apple", "google", "email".
    public var providers: [String]

    public init(id: String, displayName: String = "", email: String? = nil, emailVerified: Bool = false, isGuest: Bool, providers: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.emailVerified = emailVerified
        self.isGuest = isGuest
        self.providers = providers
    }

    /// How to refer to the account: a name, an address, or "Guest".
    public var label: String {
        if isGuest { return "Guest" }
        if !displayName.isEmpty { return displayName }
        return email ?? "Signed in"
    }
}

/// A session: a short-lived access token and the refresh token that renews it.
public struct SessionTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expires: Date

    public init(accessToken: String, refreshToken: String, expires: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expires = expires
    }
}

/// What every way of signing in (and refreshing) returns.
public struct SignInResult: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Double
    public let user: AccountUser
    /// Scores a guest brought into the account it signed in to.
    public let mergedScores: Int?

    public func tokens(now: Date = Date()) -> SessionTokens {
        SessionTokens(accessToken: accessToken, refreshToken: refreshToken, expires: now.addingTimeInterval(expiresIn))
    }
}

/// Supplies the current access token to server requests, and renews it when the server rejects it.
public protocol SessionProvider: Sendable {
    func accessToken() async -> String?
    /// The server said `rejected` is no good: a fresh token, or nil when the session can't be renewed
    /// (the person has to sign in again).
    func renewAccessToken(rejected: String) async -> String?
}

/// This install of the app, sent with every request (X-Device): free scans are counted per device.
public struct DeviceInfo: Hashable, Codable, Sendable {
    public var installID: String
    public var platform: String
    public var appVersion: String

    public init(installID: String, platform: String = "iOS", appVersion: String = "") {
        self.installID = installID
        self.platform = platform
        self.appVersion = appVersion
    }
}

/// A request the server refused, with its message for people and its code for the app.
public struct ServerError: Error, LocalizedError, Equatable, Sendable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Request building, the session (with one renewal on a rejected token) and error mapping, shared by the
/// server clients.
struct ServerHTTP: Sendable {
    let config: OMRServerConfig
    let session: URLSession
    let auth: (any SessionProvider)?

    func request(_ path: String, method: String = "GET", modified: Date? = nil, query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.timeoutInterval = 60
        if let device = config.device {
            r.setValue(device.installID, forHTTPHeaderField: "X-Device")
            r.setValue(device.platform, forHTTPHeaderField: "X-Platform")
            r.setValue(device.appVersion, forHTTPHeaderField: "X-App-Version")
        }
        if let modified { r.setValue(String(format: "%.3f", modified.timeIntervalSince1970), forHTTPHeaderField: "X-Modified") }
        return r
    }

    func json(_ path: String, _ body: [String: Any], method: String = "POST") -> URLRequest {
        var r = request(path, method: method)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    /// Sends with the session's access token; a rejected token is renewed once and the request retried.
    func send(_ request: URLRequest) async throws -> Data {
        guard let auth else { return try await sendOnce(request) }
        var r = request
        let token = await auth.accessToken()
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            return try await sendOnce(r)
        } catch OMRError.unauthorised {
            guard let token, let fresh = await auth.renewAccessToken(rejected: token) else { throw OMRError.unauthorised }
            r.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            return try await sendOnce(r)
        }
    }

    func sendOnce(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw OMRError.cancelled
        } catch let e as URLError where e.code == .cancelled {
            throw OMRError.cancelled
        } catch {
            throw OMRError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = body?["code"] as? String ?? "http_\(status)"
        // A 401 from the sign-in routes is a wrong password or a bad token, not an expired session.
        if status == 401, code == "unauthorised" { throw OMRError.unauthorised }
        throw ServerError(status: status, code: code, message: body?["error"] as? String ?? "The server answered HTTP \(status).")
    }
}

/// Signing in, the session and the account (server/api.py: /auth, /me).
public final class AccountClient: Sendable {
    private let http: ServerHTTP

    /// With `auth`, sign-in requests carry the current session: a guest signing in is upgraded (or brings its
    /// library into the account it signs in to) instead of being replaced.
    public init(config: OMRServerConfig, auth: (any SessionProvider)? = nil, session: URLSession = .shared) {
        http = ServerHTTP(config: config, session: session, auth: auth)
    }

    private func signIn(_ path: String, _ body: [String: Any]) async throws -> SignInResult {
        try JSONDecoder().decode(SignInResult.self, from: await http.send(http.json(path, body)))
    }

    public func continueAsGuest() async throws -> SignInResult { try await signIn("auth/guest", [:]) }

    public func signInWithApple(identityToken: String, nonce: String, name: String) async throws -> SignInResult {
        try await signIn("auth/apple", ["identityToken": identityToken, "nonce": nonce, "name": name])
    }

    public func signInWithGoogle(idToken: String) async throws -> SignInResult {
        try await signIn("auth/google", ["idToken": idToken])
    }

    public func signUp(email: String, password: String, name: String) async throws -> SignInResult {
        try await signIn("auth/email/signup", ["email": email, "password": password, "name": name])
    }

    public func signIn(email: String, password: String) async throws -> SignInResult {
        try await signIn("auth/email/signin", ["email": email, "password": password])
    }

    public func requestPasswordReset(email: String) async throws {
        _ = try await http.send(http.json("auth/email/reset-request", ["email": email]))
    }

    /// Renews a session (both tokens change). Sent without a session of its own.
    public func refresh(_ refreshToken: String) async throws -> SignInResult {
        let plain = ServerHTTP(config: http.config, session: http.session, auth: nil)
        return try JSONDecoder().decode(SignInResult.self, from: await plain.send(plain.json("auth/refresh", ["refreshToken": refreshToken])))
    }

    public func signOut(everywhere: Bool = false) async throws {
        _ = try await http.send(http.json("auth/signout", ["everywhere": everywhere]))
    }

    public func me() async throws -> AccountUser {
        try JSONDecoder().decode(AccountUser.self, from: await http.send(http.request("me")))
    }

    public func deleteAccount() async throws {
        _ = try await http.send(http.request("me", method: "DELETE"))
    }
}
