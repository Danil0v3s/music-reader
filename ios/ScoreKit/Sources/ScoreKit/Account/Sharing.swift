import Foundation

/// A code someone made for one of their scores or collections.
public struct Share: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case score, collection }
    /// "ABCD-EFGH".
    public let code: String
    /// The link to send: opens the app on the share (or a page about it in a browser).
    public let url: String
    public let kind: Kind
    public let id: String
    public let title: String?
    /// How many people imported a copy.
    public let imports: Int
}

/// Shared music, as someone with the code sees it: read-only, notation only.
public struct SharedItem: Sendable {
    public let kind: Share.Kind
    public let code: String
    public let title: String
    public let owner: String
    /// The score (a shared score).
    public let score: Score?
    /// The scores, in the collection's order (a shared collection).
    public let scores: [Score]
}

/// What importing made: the new scores' ids, and the new collection's (for a shared collection).
public struct ImportedShare: Decodable, Sendable {
    public let scores: [String]
    public let collection: String?

    public var scoreIds: [UUID] { scores.compactMap(UUID.init(uuidString:)) }
    public var collectionId: UUID? { collection.flatMap(UUID.init(uuidString:)) }
}

/// Sharing (server/shares.py): making codes for my music, and opening and importing other people's.
public final class ShareClient: Sendable {
    private let http: ServerHTTP

    public init(config: OMRServerConfig, auth: any SessionProvider, session: URLSession = .shared) {
        http = ServerHTTP(config: config, session: session, auth: auth)
    }

    /// The code for one of my scores or collections (the same one each time while it's shared).
    public func share(_ kind: Share.Kind, id: UUID) async throws -> Share {
        try JSONDecoder().decode(Share.self, from: await http.send(http.json("shares", ["kind": kind.rawValue, "id": id.uuidString])))
    }

    public func myShares() async throws -> [Share] {
        struct List: Decodable { let shares: [Share] }
        return try JSONDecoder().decode(List.self, from: await http.send(http.request("shares"))).shares
    }

    public func stopSharing(_ code: String) async throws {
        _ = try await http.send(http.request("shares/\(Self.normalise(code))", method: "DELETE"))
    }

    public func open(_ code: String) async throws -> SharedItem {
        var r = http.request("s/\(Self.normalise(code))")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await http.send(r)
        struct Wire: Decodable {
            struct Collection: Decodable { let name: String; let scores: [Score] }
            let kind: Share.Kind
            let code: String
            let title: String?
            let owner: String
            let score: Score?
            let collection: Collection?
        }
        let w = try LibraryDates.decoder().decode(Wire.self, from: data)
        return SharedItem(kind: w.kind, code: w.code, title: w.title ?? w.score?.title ?? "Shared music", owner: w.owner,
                          score: w.score, scores: w.collection?.scores ?? (w.score.map { [$0] } ?? []))
    }

    /// Copies the shared music into my library on the server; sync brings it to this device.
    public func importCopy(_ code: String) async throws -> ImportedShare {
        try JSONDecoder().decode(ImportedShare.self, from: await http.send(http.json("s/\(Self.normalise(code))/import", [:])))
    }

    /// "abcd-efgh", " ABCDEFGH " → "ABCDEFGH".
    public static func normalise(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A share code inside text: a typed code, or a link (…/s/CODE, musicreader://share/CODE).
    public static func code(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            let last = url.host == "share" ? url.lastPathComponent : url.pathComponents.last ?? ""
            let candidate = normalise(last == "/" ? (url.host ?? "") : last)
            return candidate.count == 8 ? candidate : nil
        }
        let candidate = normalise(trimmed)
        return candidate.count == 8 ? candidate : nil
    }
}
