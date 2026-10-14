import Combine
import Foundation
import ScoreKit
import Security

/// User preferences. Everything is in UserDefaults except the server token, which goes in the Keychain.
struct AppSettings: Codable, Equatable {
    var serverAddress: String = ""
    var tuning = Tuning.standard
    var thresholds = IntonationAssessment.Thresholds()
    var metronome = false
    var countIn = true
    /// Staff space in points: how big the music is drawn.
    var staffSpace: Double = 8
    /// Keep the library (scores, originals, collections) on the server and in step across devices.
    var syncLibrary = true
    /// Play with the recorded cello (University of Iowa samples) rather than the synthesised tone.
    var recordedCello = true

    init() {}

    // Settings saved before a field existed still decode, taking that field's default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        serverAddress = try c.decodeIfPresent(String.self, forKey: .serverAddress) ?? d.serverAddress
        tuning = try c.decodeIfPresent(Tuning.self, forKey: .tuning) ?? d.tuning
        thresholds = try c.decodeIfPresent(IntonationAssessment.Thresholds.self, forKey: .thresholds) ?? d.thresholds
        metronome = try c.decodeIfPresent(Bool.self, forKey: .metronome) ?? d.metronome
        countIn = try c.decodeIfPresent(Bool.self, forKey: .countIn) ?? d.countIn
        staffSpace = try c.decodeIfPresent(Double.self, forKey: .staffSpace) ?? d.staffSpace
        syncLibrary = try c.decodeIfPresent(Bool.self, forKey: .syncLibrary) ?? d.syncLibrary
        recordedCello = try c.decodeIfPresent(Bool.self, forKey: .recordedCello) ?? d.recordedCello
    }
}

@MainActor
final class SettingsStore {
    let settings: CurrentValueSubject<AppSettings, Never>
    private let defaults: UserDefaults
    private let key = "settings.v1"
    private let keychainAccount = "omr-token"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        settings = CurrentValueSubject(stored ?? AppSettings())
    }

    var value: AppSettings { settings.value }

    func update(_ change: (inout AppSettings) -> Void) {
        var s = settings.value
        change(&s)
        guard s != settings.value else { return }
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
        settings.send(s)
    }

    var token: String? {
        get { Keychain.read(account: keychainAccount) }
        set { Keychain.write(newValue, account: keychainAccount) }
    }

    /// The recognition server, or nil when none is configured.
    var omrConfig: OMRServerConfig? { OMRServerConfig.parse(value.serverAddress, token: token) }
}

enum Keychain {
    private static let service = "br.com.firstsoft.musicreader"

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
