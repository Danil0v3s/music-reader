import Combine
import Foundation
import ScoreKit

/// Keeps the library in step with the server: on launch, on returning to the app, a few seconds after a
/// local edit, and on pull-to-refresh. One run at a time; an edit during a run schedules another.
@MainActor
final class SyncService {
    enum Status: Equatable {
        case off
        case idle(lastSynced: Date?)
        case syncing
        case failed(String)
    }

    let status = CurrentValueSubject<Status, Never>(.off)
    private let library: ScoreLibrary
    private let settings: SettingsStore
    private let account: AccountStore
    private var running: Task<Void, Never>?
    private var pending = false
    private var debounce: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    /// Forgets when it last synced (signing out: the next account starts fresh).
    func reset() {
        debounce?.cancel()
        lastSynced = nil
        refreshStatus()
    }

    private var lastSynced: Date? {
        get { UserDefaults.standard.object(forKey: "lastSynced") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastSynced") }
    }

    init(library: ScoreLibrary, settings: SettingsStore, account: AccountStore) {
        self.library = library
        self.settings = settings
        self.account = account
        library.localChanges.receive(on: DispatchQueue.main).sink { [weak self] in self?.scheduleSoon() }.store(in: &bag)
        settings.settings.map { ($0.syncLibrary, $0.serverAddress) }.removeDuplicates { $0 == $1 }.dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncNow() }.store(in: &bag)
        // Signing in (or switching accounts) syncs straight away.
        account.state.map(\.user?.id).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncNow() }.store(in: &bag)
        refreshStatus()
    }

    private var enabled: Bool { settings.value.syncLibrary && account.user != nil && account.config != nil }

    private func refreshStatus() {
        if !enabled { status.send(.off) } else if status.value == .off { status.send(.idle(lastSynced: lastSynced)) }
    }

    /// A few seconds after the last edit, so typing a title or entering notes isn't a sync per change.
    func scheduleSoon() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    /// Starts a sync (or queues one after the current run). Returns when this request's run is done.
    @discardableResult
    func syncNow() -> Task<Void, Never>? {
        refreshStatus()
        guard enabled, let config = account.config else { return nil }
        if running != nil {
            pending = true
            return running
        }
        status.send(.syncing)
        let sync = LibrarySync(library: library, server: LibraryServer(config: config, auth: account.vault))
        let task = Task { [weak self] in
            let result: Result<SyncReport, Error>
            do { result = .success(try await sync.run()) } catch { result = .failure(error) }
            guard let self else { return }
            self.running = nil
            switch result {
            case .success(let report):
                self.lastSynced = Date()
                self.status.send(report.failures.isEmpty ? .idle(lastSynced: self.lastSynced)
                                                         : .failed("\(report.failures.count) score(s) couldn't sync; will retry."))
            case .failure(let error):
                self.status.send(.failed(error.localizedDescription))
            }
            if self.pending {
                self.pending = false
                self.syncNow()
            }
        }
        running = task
        return task
    }
}
