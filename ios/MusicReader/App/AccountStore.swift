import Combine
import Foundation
import ScoreKit
import UIKit

/// Who is signed in, and the session that proves it to the server.
///
/// The session (access and refresh tokens) is kept in the Keychain by `TokenVault`, which also renews it:
/// before it expires, or when the server rejects it. When it can't be renewed (signed out elsewhere, the
/// password changed, the account was deleted) the state becomes `.signedOut` and the app asks the person to
/// sign in again; their scores on this device stay until they do.
@MainActor
final class AccountStore {
    enum State: Equatable {
        case signedOut
        case signedIn(AccountUser)

        var user: AccountUser? { if case .signedIn(let u) = self { u } else { nil } }
    }

    let state: CurrentValueSubject<State, Never>
    let vault: TokenVault
    let device: DeviceInfo
    private let settings: SettingsStore
    private var bag = Set<AnyCancellable>()
    private static let userKey = "account.user"

    init(settings: SettingsStore) {
        self.settings = settings
        device = DeviceInfo(installID: Keychain.installID(), platform: "iOS",
                            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        vault = TokenVault(config: OMRServerConfig.parse(settings.value.serverAddress, device: device))
        let user = UserDefaults.standard.data(forKey: Self.userKey).flatMap { try? JSONDecoder().decode(AccountUser.self, from: $0) }
        state = CurrentValueSubject(user != nil && vault.hasSession ? .signedIn(user!) : .signedOut)
        let device = device
        settings.settings.map(\.serverAddress).removeDuplicates().sink { [vault] address in
            let config = OMRServerConfig.parse(address, device: device)
            Task { await vault.setConfig(config) }
        }.store(in: &bag)
        Task { [weak self] in
            await self?.vault.setOnSessionEnded { [weak self] in
                Task { @MainActor in self?.sessionEnded() }
            }
        }
    }

    var user: AccountUser? { state.value.user }

    /// The server, as this install talks to it; nil until an address is set.
    var config: OMRServerConfig? { OMRServerConfig.parse(settings.value.serverAddress, device: device) }

    private func client() throws -> AccountClient {
        guard let config else { throw ServerError(status: 0, code: "no_server", message: "Enter the server's address first.") }
        return AccountClient(config: config, auth: state.value.user == nil ? nil : vault)
    }

    // MARK: Signing in

    private func complete(_ result: SignInResult) async {
        await vault.store(result.tokens())
        setUser(result.user)
    }

    private func setUser(_ user: AccountUser) {
        if let data = try? JSONEncoder().encode(user) { UserDefaults.standard.set(data, forKey: Self.userKey) }
        state.send(.signedIn(user))
    }

    func continueAsGuest() async throws { await complete(try await client().continueAsGuest()) }

    func signInWithApple(identityToken: String, nonce: String, name: String) async throws {
        await complete(try await client().signInWithApple(identityToken: identityToken, nonce: nonce, name: name))
    }

    func signInWithGoogle(idToken: String) async throws { await complete(try await client().signInWithGoogle(idToken: idToken)) }

    func signUp(email: String, password: String, name: String) async throws {
        await complete(try await client().signUp(email: email, password: password, name: name))
    }

    func signIn(email: String, password: String) async throws {
        await complete(try await client().signIn(email: email, password: password))
    }

    func requestPasswordReset(email: String) async throws { try await client().requestPasswordReset(email: email) }

    /// Fetches the account again (another device may have added a sign-in method or confirmed the email).
    func refreshUser() async {
        guard user != nil, let me = try? await client().me() else { return }
        setUser(me)
    }

    // MARK: Signing out

    /// Ends the session here (and on the server). The caller clears this device's library.
    func signOut() async {
        if user != nil { try? await client().signOut() }
        await vault.clear()
        forget()
    }

    func deleteAccount() async throws {
        try await client().deleteAccount()
        await vault.clear()
        forget()
    }

    private func sessionEnded() {
        guard user != nil else { return }
        forget()
    }

    private func forget() {
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        state.send(.signedOut)
    }
}

/// The session's tokens: stored in the Keychain, renewed before they expire or when the server rejects
/// them, one renewal at a time (several requests failing together share it).
actor TokenVault: SessionProvider {
    private var tokens: SessionTokens?
    private var config: OMRServerConfig?
    private var renewal: Task<String?, Never>?
    private var onSessionEnded: (@Sendable () -> Void)?
    private static let account = "session"

    init(config: OMRServerConfig?) {
        self.config = config
        tokens = Keychain.read(account: Self.account).flatMap { try? JSONDecoder().decode(SessionTokens.self, from: Data($0.utf8)) }
    }

    nonisolated var hasSession: Bool { Keychain.read(account: Self.account) != nil }

    func setConfig(_ config: OMRServerConfig?) { self.config = config }
    func setOnSessionEnded(_ handler: @escaping @Sendable () -> Void) { onSessionEnded = handler }

    func store(_ tokens: SessionTokens) {
        self.tokens = tokens
        let json = (try? JSONEncoder().encode(tokens)).flatMap { String(data: $0, encoding: .utf8) }
        Keychain.write(json, account: Self.account)
    }

    func clear() {
        tokens = nil
        renewal?.cancel()
        renewal = nil
        Keychain.write(nil, account: Self.account)
    }

    func accessToken() async -> String? {
        guard let tokens else { return nil }
        // Renew a minute early rather than have a request bounce.
        if tokens.expires.timeIntervalSinceNow < 60 { return await renewAccessToken(rejected: tokens.accessToken) }
        return tokens.accessToken
    }

    func renewAccessToken(rejected: String) async -> String? {
        guard let current = tokens else { return nil }
        if current.accessToken != rejected { return current.accessToken }   // someone else already renewed it
        if let renewal { return await renewal.value }
        let task = Task<String?, Never> { await self.performRenewal(current.refreshToken) }
        renewal = task
        let token = await task.value
        renewal = nil
        return token
    }

    private func performRenewal(_ refreshToken: String) async -> String? {
        guard let config else { return nil }
        do {
            let result = try await AccountClient(config: config).refresh(refreshToken)
            store(result.tokens())
            return result.accessToken
        } catch let e as ServerError where e.status == 401 {
            // The session is over (signed out elsewhere, password changed, account deleted).
            clear()
            onSessionEnded?()
            return nil
        } catch {
            return nil   // offline: keep the tokens and try again later
        }
    }
}

extension Keychain {
    /// A random id for this install of the app, kept in the Keychain on this device only (not synced to
    /// other devices), so it survives reinstalling the app.
    static func installID() -> String {
        let account = "install-id"
        if let id = read(account: account) { return id }
        let id = UUID().uuidString
        write(id, account: account, thisDeviceOnly: true)
        return id
    }
}
