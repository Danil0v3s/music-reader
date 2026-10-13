import XCTest
@testable import ScoreKit

final class SyncPlannerTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()
    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }
    func remote(_ id: UUID, _ modified: Double, deleted: Bool = false, original: Bool = false) -> RemoteScore {
        RemoteScore(id: id.uuidString, modified: modified, deleted: deleted, original: original ? "pdf" : nil)
    }

    func testNewOnEitherSideIsCopied() {
        let plan = SyncPlanner.plan(local: [a: .init(modified: t(100), hasOriginal: true)], tombstones: [:],
                                    remote: [remote(b, 50, original: true)])
        XCTAssertEqual(Set(plan), [.upload(a), .uploadOriginal(a), .download(b), .downloadOriginal(b)])
    }

    func testNewestEditWins() {
        let plan = SyncPlanner.plan(local: [a: .init(modified: t(200), hasOriginal: false), b: .init(modified: t(100), hasOriginal: false)],
                                    tombstones: [:], remote: [remote(a, 100), remote(b, 200)])
        XCTAssertEqual(Set(plan), [.upload(a), .download(b)])
    }

    func testTimesCompareToTheMillisecond() {
        // The same instant, as stored locally and as the server echoes it back.
        XCTAssertEqual(SyncPlanner.plan(local: [a: .init(modified: t(1_790_000_000.734), hasOriginal: false)], tombstones: [:],
                                        remote: [remote(a, 1_790_000_000.734)]), [])
        // Two edits within one second still order correctly.
        XCTAssertEqual(SyncPlanner.plan(local: [a: .init(modified: t(1_790_000_000.900), hasOriginal: false)], tombstones: [:],
                                        remote: [remote(a, 1_790_000_000.100)]), [.upload(a)])
    }

    func testDatesRoundTripExactly() {
        let now = LibraryDates.now()
        XCTAssertEqual(LibraryDates.date(LibraryDates.string(now)), now)
        let header = Double(String(format: "%.3f", now.timeIntervalSince1970))!
        XCTAssertEqual(LibraryDates.millis(header), LibraryDates.millis(now))
        XCTAssertNotNil(LibraryDates.date("2026-10-13T23:15:00Z"), "older whole-second files still load")
    }

    func testDeletionsTravelBothWays() {
        let plan = SyncPlanner.plan(local: [a: .init(modified: t(100), hasOriginal: false)], tombstones: [b: t(300)],
                                    remote: [remote(a, 200, deleted: true), remote(b, 250)])
        XCTAssertEqual(Set(plan), [.deleteLocal(a, at: t(200)), .deleteRemote(b, at: t(300))])
    }

    func testEditAfterDeletionElsewhereBringsItBack() {
        let plan = SyncPlanner.plan(local: [a: .init(modified: t(300), hasOriginal: false)], tombstones: [b: t(100)],
                                    remote: [remote(a, 200, deleted: true), remote(b, 250)])
        XCTAssertEqual(Set(plan), [.upload(a), .download(b)])
    }

    func testDeletedEverywhereIsQuiet() {
        XCTAssertEqual(SyncPlanner.plan(local: [:], tombstones: [a: t(100)], remote: [remote(a, 100, deleted: true)]), [])
        XCTAssertEqual(SyncPlanner.plan(local: [:], tombstones: [a: t(100)], remote: []), [])
    }

    func testMissingOriginalsAreFilledIn() {
        let plan = SyncPlanner.plan(local: [a: .init(modified: t(100), hasOriginal: true), b: .init(modified: t(100), hasOriginal: false)],
                                    tombstones: [:], remote: [remote(a, 100), remote(b, 100, original: true)])
        XCTAssertEqual(Set(plan), [.uploadOriginal(a), .downloadOriginal(b)])
    }

    func testCollectionsLastWriterWins() {
        XCTAssertEqual(SyncPlanner.planCollections(local: .distantPast, remote: nil), .none)
        XCTAssertEqual(SyncPlanner.planCollections(local: t(100), remote: nil), .upload)
        XCTAssertEqual(SyncPlanner.planCollections(local: .distantPast, remote: 100), .download)
        XCTAssertEqual(SyncPlanner.planCollections(local: t(200), remote: 100.5), .upload)
        XCTAssertEqual(SyncPlanner.planCollections(local: t(100.25), remote: 100.25), .none)
        XCTAssertEqual(SyncPlanner.planCollections(local: t(100.9), remote: 100.25), .upload, "same second, later edit")
    }
}

final class CollectionTests: XCTestCase {
    func library() -> ScoreLibrary {
        ScoreLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func testEditingCollections() {
        var doc = CollectionsDocument()
        let s1 = UUID(), s2 = UUID(), s3 = UUID()
        let book = doc.create(name: " Suzuki Book 1 ", scoreIds: [s1])
        doc.add([s2, s1, s3], to: book.id)
        XCTAssertEqual(doc.collection(book.id)?.name, "Suzuki Book 1")
        XCTAssertEqual(doc.collection(book.id)?.scoreIds, [s1, s2, s3], "no duplicates, order kept")
        doc.move(in: book.id, from: 2, to: 0)
        XCTAssertEqual(doc.collection(book.id)?.scoreIds, [s3, s1, s2])
        let exam = doc.create(name: "Exam", scoreIds: [s1])
        XCTAssertEqual(doc.containing(s1).map(\.id), [book.id, exam.id])
        doc.forget(s1)
        XCTAssertTrue(doc.containing(s1).isEmpty)
        doc.delete(exam.id)
        XCTAssertEqual(doc.collections.map(\.id), [book.id])
    }

    func testLibraryKeepsCollectionsAndTombstones() throws {
        let lib = library()
        let score = Score.blank(title: "Minuet")
        try lib.save(score)
        lib.updateCollections { $0.create(name: "Book 1", scoreIds: [score.id]) }
        XCTAssertGreaterThan(lib.collections.value.modified, .distantPast)

        var changes = 0
        let sub = lib.localChanges.sink { changes += 1 }
        lib.delete(score.id)
        XCTAssertEqual(changes, 2, "the delete and the collection edit it caused")
        XCTAssertNotNil(lib.tombstones[score.id])
        XCTAssertTrue(lib.collections.value.collections[0].scoreIds.isEmpty, "a deleted score leaves its collections")

        // Everything survives a reload, and the library's own files aren't mistaken for scores.
        let again = ScoreLibrary(directory: lib.directory)
        XCTAssertTrue(again.summaries.value.isEmpty)
        XCTAssertEqual(again.collections.value.collections.map(\.name), ["Book 1"])
        XCTAssertNotNil(again.tombstones[score.id])

        // Saving the score again (restored by sync) clears its tombstone, without counting as a local edit.
        try again.save(score, touch: false, origin: .sync)
        XCTAssertNil(again.tombstones[score.id])
        sub.cancel()
    }
}
