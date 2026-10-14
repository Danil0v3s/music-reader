import AuthenticationServices
import CryptoKit
import UIKit

/// Sign in with Apple: the system sheet, returning the identity token for the server to verify. A random
/// nonce goes into the request (Apple puts its SHA-256 in the token) so a token can't be replayed.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Credential {
        let identityToken: String
        let nonce: String
        /// Apple shares the name only the first time someone signs in to the app.
        let name: String
    }

    private var continuation: CheckedContinuation<Credential, Error>?
    private var nonce = ""
    private weak var window: UIWindow?

    func signIn(from window: UIWindow?) async throws -> Credential {
        self.window = window
        nonce = randomString(32)
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            controller.performRequests()
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? fallbackAnchor() }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                finish(.failure(SignInError.message("Apple didn't return a sign-in token. Try again.")))
                return
            }
            let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) } ?? ""
            finish(.success(Credential(identityToken: token, nonce: nonce, name: name)))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            let cancelled = (error as? ASAuthorizationError)?.code == .canceled
            finish(.failure(cancelled ? CancellationError() : error))
        }
    }

    private func finish(_ result: Result<Credential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Google Sign-In without Google's SDK: the OAuth authorisation page in a secure web sheet (with PKCE), then
/// the code exchanged for an ID token, which the server verifies against Google's keys. Needs an iOS OAuth
/// client id from Google Cloud in Info.plist (GoogleClientID); without one the button isn't offered.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static var clientID: String? {
        let id = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? ""
        return id.hasSuffix(".apps.googleusercontent.com") ? id : nil
    }

    private weak var window: UIWindow?

    func signIn(from window: UIWindow?) async throws -> String {
        guard let clientID = Self.clientID else { throw SignInError.message("Google sign-in isn't set up in this build.") }
        self.window = window
        // Google's iOS clients redirect to the reversed client id.
        let scheme = "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = randomString(64)
        let state = randomString(16)
        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: base64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { c in
            let session = ASWebAuthenticationSession(url: auth.url!, callback: .customScheme(scheme)) { url, error in
                if let url { c.resume(returning: url) } else {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    c.resume(throwing: cancelled ? CancellationError() : (error ?? SignInError.message("Google sign-in failed.")))
                }
            }
            session.presentationContextProvider = self
            session.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw SignInError.message("Google sign-in didn't complete. Try again.")
        }
        var exchange = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        exchange.httpMethod = "POST"
        exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier), URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ]
        exchange.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await URLSession.shared.data(for: exchange)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let idToken = json["id_token"] as? String else {
            throw SignInError.message("Google didn't return a sign-in token. Try again.")
        }
        return idToken
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? fallbackAnchor() }
    }
}

@MainActor
private func fallbackAnchor() -> ASPresentationAnchor {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.keyWindow ?? ASPresentationAnchor(windowScene: scene!)
}

enum SignInError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}

private func randomString(_ length: Int) -> String {
    let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
    var rng = SystemRandomNumberGenerator()
    return String((0..<length).map { _ in chars.randomElement(using: &rng)! })
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
