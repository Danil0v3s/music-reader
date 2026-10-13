import Combine
import Foundation

/// Modification times are kept to the millisecond: two edits within a second must still order correctly for
/// sync. `now()` rounds to whole milliseconds so the stored, uploaded and compared values are all identical.
public enum LibraryDates {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    public static func now() -> Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000) }
    public static func string(_ d: Date) -> String { withFraction.string(from: d) }
    /// Reads both forms: older files were written with whole seconds.
    public static func date(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
    /// The comparison key sync uses.
    public static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    public static func millis(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }
}

/// What the library list shows, without loading every score.
public struct ScoreSummary: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var composer: String
    public var source: Score.Source
    public var measures: Int
    public var key: KeySignature
    public var time: TimeSignature
    public var modified: Date
    public var hasOriginal: Bool

    init(_ score: Score, hasOriginal: Bool) {
        id = score.id
        title = score.title
        composer = score.composer
        source = score.source
        let part = score.parts.first
        measures = part?.measures.count ?? 0
        let a = part.map { $0.attributes(at: 0) } ?? .initial
        key = a.key
        time = a.time
        modified = score.modified
        self.hasOriginal = hasOriginal
    }
}

/// Scores on disk: `<id>.json` (the score) and, for imports, `<id>.pdf` (the original, for comparison).
/// Alongside them, `_collections.json` (the collections document) and `_tombstones.json` (when each deleted
/// score was deleted, so sync can tell "deleted here" from "never had it").
/// The summaries and collections are kept in memory and published for the screens.
public final class ScoreLibrary: @unchecked Sendable {
    /// Who made a change. Local edits notify `localChanges` (which drives sync); changes sync applies don't.
    public enum Origin: Sendable { case local, sync }

    public let directory: URL
    public let summaries: CurrentValueSubject<[ScoreSummary], Never>
    public let collections: CurrentValueSubject<CollectionsDocument, Never>
    /// Fires after any local edit to scores or collections.
    public let localChanges = PassthroughSubject<Void, Never>()
    private(set) public var tombstones: [UUID: Date]

    private let queue = DispatchQueue(label: "ScoreLibrary")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(LibraryDates.string(date))
        }
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = LibraryDates.date(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return date
        }
        return d
    }()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        summaries = CurrentValueSubject([])
        collections = CurrentValueSubject(CollectionsDocument())
        tombstones = [:]
        summaries.send(scan())
        if let data = try? Data(contentsOf: collectionsURL), let doc = try? decoder.decode(CollectionsDocument.self, from: data) {
            collections.send(doc)
        }
        if let data = try? Data(contentsOf: tombstonesURL), let t = try? decoder.decode([UUID: Date].self, from: data) {
            tombstones = t
        }
    }

    private func jsonURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    public func originalURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).pdf") }
    private var collectionsURL: URL { directory.appendingPathComponent("_collections.json") }
    private var tombstonesURL: URL { directory.appendingPathComponent("_tombstones.json") }

    private func scan() -> [ScoreSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), let score = try? decoder.decode(Score.self, from: data) else { return nil }
                return ScoreSummary(score, hasOriginal: FileManager.default.fileExists(atPath: originalURL(score.id).path))
            }.sorted { $0.modified > $1.modified }
    }

    // MARK: Scores

    public func load(_ id: UUID) throws -> Score {
        try decoder.decode(Score.self, from: Data(contentsOf: jsonURL(id)))
    }

    /// The score's file as stored (what sync uploads).
    public func encoded(_ id: UUID) throws -> Data { try Data(contentsOf: jsonURL(id)) }

    public func original(_ id: UUID) -> Data? { try? Data(contentsOf: originalURL(id)) }

    /// Saves (creating or replacing) a score; `original` stores the imported PDF next to it. `touch` stamps
    /// it modified now (an edit); sync passes false to keep the server's time.
    public func save(_ score: Score, original: Data? = nil, touch: Bool = true, origin: Origin = .local) throws {
        var score = score
        if touch { score.modified = LibraryDates.now() }
        try queue.sync {
            try encoder.encode(score).write(to: jsonURL(score.id), options: .atomic)
            if let original { try original.write(to: originalURL(score.id), options: .atomic) }
        }
        if tombstones.removeValue(forKey: score.id) != nil { saveTombstones() }
        var list = summaries.value.filter { $0.id != score.id }
        list.append(ScoreSummary(score, hasOriginal: FileManager.default.fileExists(atPath: originalURL(score.id).path)))
        summaries.send(list.sorted { $0.modified > $1.modified })
        if origin == .local { localChanges.send() }
    }

    /// Stores an original PDF for a score already in the library (sync fetching it later than the score).
    public func saveOriginal(_ data: Data, for id: UUID) throws {
        try queue.sync { try data.write(to: originalURL(id), options: .atomic) }
        summaries.send(summaries.value.map { s in
            var s = s
            if s.id == id { s.hasOriginal = true }
            return s
        })
    }

    /// Deletes a score and its original, remembers when (for sync), and drops it from every collection.
    public func delete(_ id: UUID, at date: Date = Date(), origin: Origin = .local) {
        queue.sync {
            try? FileManager.default.removeItem(at: jsonURL(id))
            try? FileManager.default.removeItem(at: originalURL(id))
        }
        tombstones[id] = date
        saveTombstones()
        summaries.send(summaries.value.filter { $0.id != id })
        if collections.value.containing(id).isEmpty == false {
            updateCollections(touch: origin == .local, origin: origin) { $0.forget(id) }
        }
        if origin == .local { localChanges.send() }
    }

    public func duplicate(_ id: UUID) throws -> Score {
        var copy = try load(id)
        copy.id = UUID()
        copy.title += " (copy)"
        copy.created = Date()
        try save(copy, original: original(id))
        for c in collections.value.containing(id) { updateCollections { $0.add([copy.id], to: c.id) } }
        return copy
    }

    private func saveTombstones() {
        let t = tombstones
        queue.sync { try? encoder.encode(t).write(to: tombstonesURL, options: .atomic) }
    }

    // MARK: Collections

    /// Applies an edit to the collections document and saves it. `touch` stamps it modified now.
    public func updateCollections(touch: Bool = true, origin: Origin = .local, _ edit: (inout CollectionsDocument) -> Void) {
        var doc = collections.value
        edit(&doc)
        if touch { doc.modified = LibraryDates.now() }
        replaceCollections(doc, origin: origin)
    }

    /// Replaces the whole document (sync downloading the server's copy).
    public func replaceCollections(_ doc: CollectionsDocument, origin: Origin) {
        // Ids of scores that no longer exist here are kept: they may still be downloading.
        queue.sync { try? encoder.encode(doc).write(to: collectionsURL, options: .atomic) }
        collections.send(doc)
        if origin == .local { localChanges.send() }
    }

    public func encodedCollections() throws -> Data { try encoder.encode(collections.value) }

    public func decodeCollections(_ data: Data) throws -> CollectionsDocument { try decoder.decode(CollectionsDocument.self, from: data) }
    public func decodeScore(_ data: Data) throws -> Score { try decoder.decode(Score.self, from: data) }
}
