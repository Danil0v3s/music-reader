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

final class SampleBankTests: XCTestCase {
    /// The real sample set in shared/sounds/cello.
    func bank() throws -> SampleBank {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Tests/ScoreKitTests
            .deletingLastPathComponent().deletingLastPathComponent()             // ScoreKit
            .deletingLastPathComponent().deletingLastPathComponent()             // repo
        return try SampleBank.load(from: root.appendingPathComponent("shared/sounds/cello"))
    }

    func schedule(_ pitches: [Pitch], key: KeySignature = .cMajor, tuning: Tuning = .standard) -> PlaybackSchedule {
        var m = Measure(number: 1)
        m.attributes = MeasureAttributes(clef: .bass, key: key, time: TimeSignature(4, 4), tempo: Tempo(bpm: 60))
        m.items = [.note(NoteEvent(duration: .whole, pitches: pitches))]
        return PlaybackSchedule.build(part: Part(name: "Vc", measures: [m]), tuning: tuning)
    }

    func pitch(of audio: [Float], at seconds: Double) -> Double? {
        let start = Int(seconds * 44100)
        return PitchDetector(sampleRate: 44100).detect(Array(audio[start..<start + 4096]))?.frequency
    }

    func testCoversTheCelloRange() throws {
        let b = try bank()
        let notes = Set(b.manifest.notes.map(\.midi))
        XCTAssertTrue(notes.contains(36), "open C string")
        XCTAssertGreaterThanOrEqual(notes.count, 40)
        XCTAssertTrue(b.manifest.notes.allSatisfy { $0.loopStart < $0.loopEnd && $0.loopEnd <= $0.frames })
    }

    func testRecordedNotesPlayAtTheExactTargetPitch() throws {
        let b = try bank()
        let synth = Synth(sampleRate: 44100)
        // A3 at A = 440, sampled from a take that isn't exactly 220 Hz, and well past the recording's length
        // (3.5 s into a 4 s note), so through the loop.
        let audio = synth.renderSampled(schedule([Pitch(.a, 3)]), bank: b)
        for t in [0.8, 3.5] {
            let f = try XCTUnwrap(pitch(of: audio, at: t))
            // Notes are corrected by their median pitch; the recorded player drifts a few cents within a note,
            // which stays below what the ear can tell apart (~5 ¢).
            XCTAssertEqual(Tuning.cents(f, relativeTo: 220), 0, accuracy: 5, "at \(t) s")
        }
    }

    func testFollowsTheTuningSystem() throws {
        let b = try bank()
        // E3 in C major, just intonation: a pure third above C, 13.7 ¢ below equal temperament.
        let just = Tuning(system: .just)
        let audio = Synth(sampleRate: 44100).renderSampled(schedule([Pitch(.e, 3)], tuning: just), bank: b)
        let f = try XCTUnwrap(pitch(of: audio, at: 1.0))
        XCTAssertEqual(Tuning.cents(f, relativeTo: Tuning.standard.frequency(of: Pitch(.e, 3))), -13.7, accuracy: 5)
    }
}
