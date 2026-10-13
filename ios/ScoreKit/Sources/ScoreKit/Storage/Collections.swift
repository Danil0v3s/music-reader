import Foundation

/// A named, ordered group of scores: a method book, an exam programme, this week's practice. A score can
/// be in several collections; deleting a collection never deletes its scores.
public struct ScoreCollection: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// In the order the user arranged them.
    public var scoreIds: [UUID]
    public var created: Date

    public init(id: UUID = UUID(), name: String, scoreIds: [UUID] = [], created: Date = Date()) {
        self.id = id
        self.name = name
        self.scoreIds = scoreIds
        self.created = created
    }
}

/// All collections, synced as one document (last writer wins): they're small and edited rarely, so merging
/// field by field isn't worth its complexity.
public struct CollectionsDocument: Hashable, Codable, Sendable {
    public var collections: [ScoreCollection]
    public var modified: Date

    public init(collections: [ScoreCollection] = [], modified: Date = .distantPast) {
        self.collections = collections
        self.modified = modified
    }

    public func collection(_ id: UUID) -> ScoreCollection? { collections.first { $0.id == id } }

    /// Collections containing a score, for its "In collections" menu.
    public func containing(_ scoreId: UUID) -> [ScoreCollection] { collections.filter { $0.scoreIds.contains(scoreId) } }

    // MARK: Editing (callers save the result through ScoreLibrary.updateCollections)

    @discardableResult
    public mutating func create(name: String, scoreIds: [UUID] = []) -> ScoreCollection {
        let c = ScoreCollection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), scoreIds: scoreIds)
        collections.append(c)
        return c
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let i = index(id) else { return }
        collections[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func delete(_ id: UUID) { collections.removeAll { $0.id == id } }

    /// Adds scores to the end of a collection, skipping any already in it.
    public mutating func add(_ scoreIds: [UUID], to id: UUID) {
        guard let i = index(id) else { return }
        for s in scoreIds where !collections[i].scoreIds.contains(s) { collections[i].scoreIds.append(s) }
    }

    public mutating func remove(_ scoreId: UUID, from id: UUID) {
        guard let i = index(id) else { return }
        collections[i].scoreIds.removeAll { $0 == scoreId }
    }

    public mutating func move(in id: UUID, from source: Int, to destination: Int) {
        guard let i = index(id), collections[i].scoreIds.indices.contains(source) else { return }
        let s = collections[i].scoreIds.remove(at: source)
        collections[i].scoreIds.insert(s, at: min(destination, collections[i].scoreIds.count))
    }

    /// Drops a deleted score from every collection.
    public mutating func forget(_ scoreId: UUID) {
        for i in collections.indices { collections[i].scoreIds.removeAll { $0 == scoreId } }
    }

    private func index(_ id: UUID) -> Int? { collections.firstIndex { $0.id == id } }
}
