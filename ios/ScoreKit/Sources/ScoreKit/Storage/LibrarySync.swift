import Foundation

// MARK: - Server API

/// A score as the server lists it.
public struct RemoteScore: Decodable, Sendable, Equatable {
    public let id: String
    public let modified: Double
    public let deleted: Bool
    public let title: String?
    public let composer: String?
    public let original: String?

    public init(id: String, modified: Double, deleted: Bool, title: String? = nil, composer: String? = nil, original: String? = nil) {
        self.id = id
        self.modified = modified
        self.deleted = deleted
        self.title = title
        self.composer = composer
        self.original = original
    }
}

public struct RemoteListing: Decodable, Sendable {
    public struct Collections: Decodable, Sendable { public let modified: Double? }
    public let scores: [RemoteScore]
    public let collections: Collections
}

/// Client for the server's `/library` endpoints (server/library_store.py).
public final class LibraryServer: Sendable {
    private let http: ServerHTTP

    public init(config: OMRServerConfig, session: URLSession = .shared) {
        http = ServerHTTP(config: config, session: session)
    }

    public func listing() async throws -> RemoteListing {
        try JSONDecoder().decode(RemoteListing.self, from: await http.send(http.request("library")))
    }

    public func score(_ id: UUID) async throws -> Data { try await http.send(http.request("library/scores/\(id.uuidString)")) }

    public func putScore(_ id: UUID, _ data: Data, modified: Date) async throws {
        var r = http.request("library/scores/\(id.uuidString)", method: "PUT", modified: modified)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        _ = try await http.send(r)
    }

    public func deleteScore(_ id: UUID, at date: Date) async throws {
        _ = try await http.send(http.request("library/scores/\(id.uuidString)", method: "DELETE", modified: date))
    }

    public func original(_ id: UUID) async throws -> Data { try await http.send(http.request("library/scores/\(id.uuidString)/original")) }

    public func putOriginal(_ id: UUID, _ data: Data) async throws {
        var r = http.request("library/scores/\(id.uuidString)/original", method: "PUT")
        r.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        r.timeoutInterval = 300
        _ = try await http.send(r)
    }

    public func collections() async throws -> Data { try await http.send(http.request("library/collections")) }

    public func putCollections(_ data: Data, modified: Date) async throws {
        var r = http.request("library/collections", method: "PUT", modified: modified)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        _ = try await http.send(r)
    }
}

/// Request building and error mapping shared by the server clients.
struct ServerHTTP: Sendable {
    let config: OMRServerConfig
    let session: URLSession

    func request(_ path: String, method: String = "GET", modified: Date? = nil) -> URLRequest {
        var r = URLRequest(url: config.baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 60
        if let token = config.token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let modified { r.setValue(String(format: "%.3f", modified.timeIntervalSince1970), forHTTPHeaderField: "X-Modified") }
        return r
    }

    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw OMRError.cancelled
        } catch {
            throw OMRError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw OMRError.unauthorised
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OMRError.rejected(message ?? "HTTP \(status)")
        }
    }
}

// MARK: - Planning

/// What sync does for one score. Times compare to the millisecond (see LibraryDates).
public enum SyncAction: Hashable, Sendable {
    case upload(UUID)
    case download(UUID)
    case deleteLocal(UUID, at: Date)
    case deleteRemote(UUID, at: Date)
    case uploadOriginal(UUID)
    case downloadOriginal(UUID)
}

public enum CollectionsSyncAction: Equatable, Sendable { case none, upload, download }

public enum SyncPlanner {
    public struct Local: Sendable {
        public var modified: Date
        public var hasOriginal: Bool
        public init(modified: Date, hasOriginal: Bool) { self.modified = modified; self.hasOriginal = hasOriginal }
    }

    static func seconds(_ d: Date) -> Int64 { LibraryDates.millis(d) }
    static func seconds(_ d: Double) -> Int64 { LibraryDates.millis(d) }

    /// Newest wins, per score. A deletion is a change like any other: deleting a score newer than the other
    /// side's copy removes it there; editing a score after it was deleted elsewhere brings it back.
    public static func plan(local: [UUID: Local], tombstones: [UUID: Date], remote: [RemoteScore]) -> [SyncAction] {
        var remoteById: [UUID: RemoteScore] = [:]
        for r in remote { if let id = UUID(uuidString: r.id) { remoteById[id] = r } }
        var actions: [SyncAction] = []
        let ids = Set(local.keys).union(tombstones.keys).union(remoteById.keys)
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let r = remoteById[id]
            if let l = local[id] {
                let lt = seconds(l.modified)
                guard let r else { actions.append(.upload(id)); if l.hasOriginal { actions.append(.uploadOriginal(id)) }; continue }
                let rt = seconds(r.modified)
                if r.deleted {
                    if rt >= lt { actions.append(.deleteLocal(id, at: Date(timeIntervalSince1970: r.modified))) }
                    else { actions.append(.upload(id)); if l.hasOriginal { actions.append(.uploadOriginal(id)) } }
                } else if lt > rt {
                    actions.append(.upload(id))
                    if l.hasOriginal && r.original == nil { actions.append(.uploadOriginal(id)) }
                } else if rt > lt {
                    actions.append(.download(id))
                    if r.original != nil && !l.hasOriginal { actions.append(.downloadOriginal(id)) }
                } else if l.hasOriginal && r.original == nil {
                    actions.append(.uploadOriginal(id))
                } else if !l.hasOriginal && r.original != nil {
                    actions.append(.downloadOriginal(id))
                }
            } else if let t = tombstones[id] {
                guard let r, !r.deleted else { continue }
                if seconds(t) >= seconds(r.modified) { actions.append(.deleteRemote(id, at: t)) }
                else { actions.append(.download(id)); if r.original != nil { actions.append(.downloadOriginal(id)) } }
            } else if let r, !r.deleted {
                actions.append(.download(id))
                if r.original != nil { actions.append(.downloadOriginal(id)) }
            }
        }
        return actions
    }

    public static func planCollections(local: Date, remote: Double?) -> CollectionsSyncAction {
        let lt = local == .distantPast ? nil : seconds(local)
        let rt = remote.map(seconds)
        switch (lt, rt) {
        case (nil, nil): return .none
        case (_?, nil): return .upload
        case (nil, _?): return .download
        case (let l?, let r?): return l > r ? .upload : r > l ? .download : .none
        }
    }
}

// MARK: - Running

public struct SyncReport: Equatable, Sendable {
    public var uploaded = 0
    public var downloaded = 0
    public var deletedHere = 0
    public var deletedThere = 0
    public var failures: [String] = []

    public var changed: Bool { uploaded + downloaded + deletedHere + deletedThere > 0 }
}

/// Brings the local library and the server's library to the same state.
public final class LibrarySync: Sendable {
    private let library: ScoreLibrary
    private let server: LibraryServer

    public init(library: ScoreLibrary, server: LibraryServer) {
        self.library = library
        self.server = server
    }

    public func run() async throws -> SyncReport {
        let listing = try await server.listing()
        let local = Dictionary(uniqueKeysWithValues: library.summaries.value.map { ($0.id, SyncPlanner.Local(modified: $0.modified, hasOriginal: $0.hasOriginal)) })
        var report = SyncReport()
        for action in SyncPlanner.plan(local: local, tombstones: library.tombstones, remote: listing.scores) {
            do {
                switch action {
                case .upload(let id):
                    guard let modified = local[id]?.modified else { continue }
                    try await server.putScore(id, library.encoded(id), modified: modified)
                    report.uploaded += 1
                case .download(let id):
                    let score = try library.decodeScore(await server.score(id))
                    try library.save(score, touch: false, origin: .sync)
                    report.downloaded += 1
                case .deleteLocal(let id, let at):
                    library.delete(id, at: at, origin: .sync)
                    report.deletedHere += 1
                case .deleteRemote(let id, let at):
                    try await server.deleteScore(id, at: at)
                    report.deletedThere += 1
                case .uploadOriginal(let id):
                    if let pdf = library.original(id) { try await server.putOriginal(id, pdf) }
                case .downloadOriginal(let id):
                    try library.saveOriginal(await server.original(id), for: id)
                }
            } catch {
                // One bad score shouldn't stop the rest; it's retried next time.
                report.failures.append("\(action): \(error.localizedDescription)")
            }
        }
        switch SyncPlanner.planCollections(local: library.collections.value.modified, remote: listing.collections.modified) {
        case .upload:
            try await server.putCollections(library.encodedCollections(), modified: library.collections.value.modified)
        case .download:
            library.replaceCollections(try library.decodeCollections(await server.collections()), origin: .sync)
        case .none:
            break
        }
        return report
    }
}
