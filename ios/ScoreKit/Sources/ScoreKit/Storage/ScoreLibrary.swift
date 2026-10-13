import Combine
import Foundation

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
/// The index of summaries is kept in memory and published for the library screen.
public final class ScoreLibrary: @unchecked Sendable {
    public let directory: URL
    public let summaries: CurrentValueSubject<[ScoreSummary], Never>
    private let queue = DispatchQueue(label: "ScoreLibrary")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        summaries = CurrentValueSubject([])
        summaries.send(scan())
    }

    private func jsonURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    public func originalURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).pdf") }

    private func scan() -> [ScoreSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let score = try? decoder.decode(Score.self, from: data) else { return nil }
            return ScoreSummary(score, hasOriginal: FileManager.default.fileExists(atPath: originalURL(score.id).path))
        }.sorted { $0.modified > $1.modified }
    }

    public func load(_ id: UUID) throws -> Score {
        try decoder.decode(Score.self, from: Data(contentsOf: jsonURL(id)))
    }

    /// Saves (creating or replacing) a score; `original` stores the imported PDF next to it.
    public func save(_ score: Score, original: Data? = nil, touch: Bool = true) throws {
        var score = score
        if touch { score.modified = Date() }
        try queue.sync {
            try encoder.encode(score).write(to: jsonURL(score.id), options: .atomic)
            if let original { try original.write(to: originalURL(score.id), options: .atomic) }
        }
        var list = summaries.value.filter { $0.id != score.id }
        list.append(ScoreSummary(score, hasOriginal: FileManager.default.fileExists(atPath: originalURL(score.id).path)))
        summaries.send(list.sorted { $0.modified > $1.modified })
    }

    public func delete(_ id: UUID) {
        queue.sync {
            try? FileManager.default.removeItem(at: jsonURL(id))
            try? FileManager.default.removeItem(at: originalURL(id))
        }
        summaries.send(summaries.value.filter { $0.id != id })
    }

    public func duplicate(_ id: UUID) throws -> Score {
        var copy = try load(id)
        copy.id = UUID()
        copy.title += " (copy)"
        copy.created = Date()
        let original = try? Data(contentsOf: originalURL(id))
        try save(copy, original: original)
        return copy
    }
}
