import XCTest
@testable import ScoreKit

final class MusicXMLTests: XCTestCase {
    func etude() throws -> Score {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "etude-in-d", withExtension: "musicxml", subdirectory: "Fixtures"))
        return try MusicXMLReader.read(Data(contentsOf: url))
    }

    func testReadsTheEtude() throws {
        let score = try etude()
        XCTAssertEqual(score.title, "Étude in D")
        XCTAssertEqual(score.composer, "Music Reader sample")
        let part = score.parts[0]
        XCTAssertEqual(part.measures.count, 12)
        let a = part.attributes(at: 0)
        XCTAssertEqual(a.key, KeySignature(fifths: 2))
        XCTAssertEqual(a.time, TimeSignature(3, 4))
        XCTAssertEqual(a.clef, .bass)
        XCTAssertEqual(a.tempo.bpm, 84)
        XCTAssertEqual(a.tempo.text, "Andante")
        // Every bar adds up to 3/4.
        for (i, m) in part.measures.enumerated() {
            XCTAssertEqual(m.fill(in: part.attributes(at: i).time), .complete, "measure \(i + 1)")
        }
        // Tenor clef from bar 7, back to bass in bar 11.
        XCTAssertEqual(part.attributes(at: 6).clef, .tenor)
        XCTAssertEqual(part.attributes(at: 10).clef, .bass)
        let first = part.measures[0].notes[0]
        XCTAssertEqual(first.pitches, [Pitch(.d, 3)])
        XCTAssertEqual(first.bowing, .down)
        XCTAssertEqual(first.fingerings, [0])
        XCTAssertTrue(part.measures[0].notes[1].slurStart)
        XCTAssertTrue(part.measures[7].notes[2].tieToNext)
        // Final double stop D3 + A3 with a fermata.
        let last = part.measures[11].notes[0]
        XCTAssertEqual(last.pitches, [Pitch(.d, 3), Pitch(.a, 3)])
        XCTAssertTrue(last.articulations.contains(.fermata))
        XCTAssertEqual(part.measures[11].barline, .final)
        XCTAssertTrue(part.measures[0].items.contains(.dynamic(.mp)))
        XCTAssertTrue(part.measures[4].items.contains(.wedge(.crescendo)))
        XCTAssertEqual(part.measures[5].notes[0].string, .a)
    }

    func testRoundTrip() throws {
        let score = try etude()
        let again = try MusicXMLReader.read(MusicXMLWriter.write(score))
        XCTAssertEqual(again.title, score.title)
        let a = score.parts[0], b = again.parts[0]
        XCTAssertEqual(a.measures.count, b.measures.count)
        for (ma, mb) in zip(a.measures, b.measures) {
            XCTAssertEqual(ma.notes.map(\.pitches), mb.notes.map(\.pitches))
            XCTAssertEqual(ma.notes.map(\.duration), mb.notes.map(\.duration))
            XCTAssertEqual(ma.notes.map(\.bowing), mb.notes.map(\.bowing))
            XCTAssertEqual(ma.notes.map(\.fingerings), mb.notes.map(\.fingerings))
            XCTAssertEqual(ma.notes.map(\.tieToNext), mb.notes.map(\.tieToNext))
            XCTAssertEqual(ma.barline, mb.barline)
        }
        XCTAssertEqual(a.resolvedAttributes, b.resolvedAttributes)
    }

    func testChordsVoicesAndTuplets() throws {
        let xml = """
        <score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Vc</part-name></score-part></part-list>
        <part id="P1"><measure number="1">
          <attributes><divisions>6</divisions><time><beats>2</beats><beat-type>4</beat-type></time><clef><sign>F</sign><line>4</line></clef></attributes>
          <note><pitch><step>G</step><octave>2</octave></pitch><duration>2</duration><voice>1</voice><type>eighth</type>
            <time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification></note>
          <note><pitch><step>A</step><octave>2</octave></pitch><duration>2</duration><voice>1</voice><type>eighth</type>
            <time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification></note>
          <note><pitch><step>B</step><octave>2</octave></pitch><duration>2</duration><voice>1</voice><type>eighth</type>
            <time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification></note>
          <note><pitch><step>C</step><octave>3</octave></pitch><duration>6</duration><voice>1</voice><type>quarter</type></note>
          <note><chord/><pitch><step>G</step><octave>3</octave></pitch><duration>6</duration><voice>1</voice><type>quarter</type></note>
          <backup><duration>12</duration></backup>
          <note><pitch><step>C</step><octave>2</octave></pitch><duration>12</duration><voice>2</voice><type>half</type></note>
        </measure></part></score-partwise>
        """
        let part = try MusicXMLReader.read(Data(xml.utf8)).parts[0]
        let notes = part.measures[0].notes
        XCTAssertEqual(notes.count, 4, "voice 2 is dropped, the chord tone joins its note")
        XCTAssertEqual(notes[0].duration.tuplet, .triplet)
        XCTAssertEqual(notes[3].pitches, [Pitch(.c, 3), Pitch(.g, 3)])
        XCTAssertEqual(part.measures[0].fill(in: TimeSignature(2, 4)), .complete)
    }

    /// What Audiveris writes for a photographed page: no work-title, the title as a big bold text direction
    /// over bar 1, and OCR noise as tiny credits.
    func testTitleFromRecognisedScan() throws {
        let xml = """
        <score-partwise version="4.0.3">
          <credit page="1"><credit-words default-x="485" default-y="438" font-size="9">-</credit-words></credit>
          <credit page="1"><credit-words default-x="589" default-y="159" font-size="8">4</credit-words></credit>
          <part-list><score-part id="P1"><part-name>Voice</part-name></score-part></part-list>
          <part id="P1"><measure number="1">
            <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>F</sign><line>4</line></clef></attributes>
            <direction placement="above"><direction-type><words font-size="14" font-weight="bold">Early one morning</words></direction-type></direction>
            <direction placement="above"><direction-type><words font-size="9" font-style="italic">dolce</words></direction-type></direction>
            <note><pitch><step>C</step><octave>3</octave></pitch><duration>4</duration><voice>1</voice><type>whole</type></note>
          </measure></part>
        </score-partwise>
        """
        let score = try MusicXMLReader.read(Data(xml.utf8))
        XCTAssertEqual(score.title, "Early one morning")
        let texts = score.parts[0].measures[0].items.compactMap { if case .text(let t) = $0 { t } else { nil } }
        XCTAssertEqual(texts, ["dolce"], "the title is no longer drawn over bar 1; smaller expression text stays")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try MusicXMLReader.read(Data("<html/>".utf8)))
        XCTAssertThrowsError(try MusicXMLReader.read(Data("not xml".utf8)))
    }
}

final class EditingTests: XCTestCase {
    func testInsertReplacesMeasureRest() {
        var score = Score.blank(time: TimeSignature(3, 4), measures: 2)
        var part = score.parts[0]
        let path = part.insert(NoteEvent(duration: .quarter, pitches: [Pitch(.d, 3)]), at: ItemPath(measure: 0, item: 0))
        XCTAssertEqual(path, ItemPath(measure: 0, item: 0))
        XCTAssertEqual(part.measures[0].notes.count, 1)
        XCTAssertEqual(part.measures[0].fill(in: TimeSignature(3, 4)), .underfull(missing: Fraction(1, 2)))
        part.fillWithRests(measure: 0)
        XCTAssertEqual(part.measures[0].fill(in: TimeSignature(3, 4)), .complete)
        part.remove(at: ItemPath(measure: 0, item: 0))
        part.remove(at: ItemPath(measure: 0, item: 0))
        XCTAssertTrue(part.measures[0].notes[0].isMeasureRest, "an emptied bar gets its rest back")
        score.parts[0] = part
    }

    func testRemovingAMeasureKeepsAttributes() {
        var part = Score.blank(clef: .tenor, key: KeySignature(fifths: -1), measures: 3).parts[0]
        part.removeMeasure(at: 0)
        XCTAssertEqual(part.attributes(at: 0).clef, .tenor)
        XCTAssertEqual(part.attributes(at: 0).key.fifths, -1)
        XCTAssertEqual(part.measures.map(\.number), [1, 2])
    }

    func testSetAttributesDropsRedundantChanges() {
        var part = Score.blank(measures: 3).parts[0]
        part.setAttributes(at: 1) { $0.clef = .bass }
        XCTAssertNil(part.measures[1].attributes, "bass is already in force")
        part.setAttributes(at: 2) { $0.clef = .tenor }
        XCTAssertEqual(part.attributes(at: 2).clef, .tenor)
    }

    func testMidMeasureClefCarriesOver() {
        var part = Score.blank(measures: 2).parts[0]
        part.measures[0].items = [.note(NoteEvent(duration: .half, pitches: [Pitch(.d, 3)])), .clef(.tenor),
                                  .note(NoteEvent(duration: .half, pitches: [Pitch(.d, 4)]))]
        XCTAssertEqual(part.attributes(at: 1).clef, .tenor)
        XCTAssertEqual(part.clef(at: ItemPath(measure: 0, item: 2)), .tenor)
    }
}

final class PlaybackTests: XCTestCase {
    func testScheduleTimesAndTies() throws {
        let score = try MusicXMLTests().etude()
        let schedule = PlaybackSchedule.build(part: score.parts[0])
        let beat = 60.0 / 84
        // 12 bars × 3 beats, plus the fermata stretching the last bar by 3/4.
        XCTAssertEqual(schedule.duration, (36 + 3 * 0.75) * beat, accuracy: 1e-6)
        XCTAssertEqual(schedule.beats.count, 36)
        XCTAssertTrue(schedule.beats[0].isDownbeat && !schedule.beats[1].isDownbeat && schedule.beats[3].isDownbeat)
        // The tied G4 (bar 8 → bar 9) sounds once, across both notes.
        let g8 = try XCTUnwrap(schedule.notes.first { $0.path == ItemPath(measure: 7, item: 2) })
        let g9 = try XCTUnwrap(schedule.notes.first { $0.path.measure == 8 && $0.pitches == [Pitch(.g, 4)] })
        XCTAssertEqual(g9.sounding, 0)
        XCTAssertGreaterThan(g8.sounding, g8.length)
        XCTAssertEqual(schedule.note(at: 0.1)?.pitches, [Pitch(.d, 3)])
    }

    func testSlurredNotesContinueTheBow() throws {
        let part = try MusicXMLTests().etude().parts[0]
        let schedule = PlaybackSchedule.build(part: part)
        // Bar 1: D3, then F♯3–A3 under a slur. Only A3 continues a stroke; D3 and F♯3 start new ones.
        let bar1 = schedule.notes.filter { $0.path.measure == 0 }
        XCTAssertEqual(bar1.map(\.legato), [false, false, true])
        XCTAssertEqual(bar1[1].sounding, bar1[1].length, accuracy: 1e-9, "a slurred note is held to the next")
    }

    func testHalfSpeed() throws {
        let part = try MusicXMLTests().etude().parts[0]
        let full = PlaybackSchedule.build(part: part).duration
        XCTAssertEqual(PlaybackSchedule.build(part: part, tempoScale: 0.5).duration, full * 2, accuracy: 1e-6)
    }

    func testRepeatsArePlayedTwice() {
        var part = Score.blank(measures: 4).parts[0]
        part.measures[1].barline = .repeatStart
        part.measures[2].barline = .repeatEnd
        XCTAssertEqual(PlaybackSchedule.playOrder(part), [0, 1, 2, 1, 2, 3])
        part.measures[1].barline = .regular
        XCTAssertEqual(PlaybackSchedule.playOrder(part), [0, 1, 2, 0, 1, 2, 3], "no forward repeat: back to the start")
    }

    func testPickupBeatsCountFromTheBarline() {
        var part = Score.blank(time: TimeSignature(3, 4), measures: 2).parts[0]
        part.measures[0].isPickup = true
        part.measures[0].items = [.note(NoteEvent(duration: .quarter, pitches: [Pitch(.a, 2)]))]
        let s = PlaybackSchedule.build(part: part)
        XCTAssertEqual(s.beats.filter { $0.measure == 0 }.count, 1)
        XCTAssertFalse(s.beats[0].isDownbeat, "the upbeat is the third beat")
    }
}

final class PitchDetectionTests: XCTestCase {
    /// A bowed-string-like tone: sawtooth harmonics with a weak fundamental.
    func tone(_ f: Double, sampleRate: Double = 44100, count: Int = 4096) -> [Float] {
        (0..<count).map { i in
            let t = Double(i) / sampleRate
            var v = 0.0
            for h in 1...8 { v += sin(2 * .pi * f * Double(h) * t) / Double(h) * (h == 1 ? 0.5 : 1) }
            return Float(v * 0.2)
        }
    }

    func testDetectsCelloRange() throws {
        let d = PitchDetector(sampleRate: 44100)
        for f in [65.406, 98.0, 146.83, 220.0, 440.0, 880.0] {
            let r = try XCTUnwrap(d.detect(tone(f)), "\(f) Hz")
            XCTAssertEqual(Tuning.cents(r.frequency, relativeTo: f), 0, accuracy: 2, "\(f) Hz")
            XCTAssertGreaterThan(r.confidence, 0.85)
        }
    }

    func testSilenceAndNoise() {
        let d = PitchDetector(sampleRate: 44100)
        XCTAssertNil(d.detect([Float](repeating: 0, count: 4096)))
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<4096).map { _ in Float.random(in: -0.3...0.3, using: &rng) }
        if let r = d.detect(noise) { XCTAssertLessThan(r.confidence, 0.85) }
    }

    func testAssessment() {
        let note = ScheduledNote(noteId: UUID(), path: ItemPath(measure: 0, item: 0), start: 0, length: 1, sounding: 1,
                                 pitches: [.a4], frequencies: [440], velocity: 0.6, isGrace: false)
        var a = IntonationAssessment(tuning: .standard, key: .cMajor)
        for _ in 0..<10 { a.add(440 * pow(2, 18.0 / 1200), for: note) }
        let r = a.result(for: note.noteId)
        XCTAssertEqual(r?.rating, .close)
        XCTAssertEqual(r?.cents ?? 0, 18, accuracy: 0.01)
        XCTAssertEqual(r?.direction, "18 ¢ sharp")

        var wrong = IntonationAssessment(tuning: .standard, key: .cMajor)
        for _ in 0..<10 { wrong.add(466.16, for: note) }
        XCTAssertEqual(wrong.result(for: note.noteId)?.rating, .wrongNote)
        XCTAssertEqual(wrong.result(for: note.noteId)?.heard, Pitch(.a, 4, alter: 1))
    }
}

final class LayoutTests: XCTestCase {
    func testLaysOutTheEtude() throws {
        let score = try MusicXMLTests().etude()
        let layout = LayoutEngine.layout(score, options: LayoutOptions(staffSpace: 8, width: 390))
        XCTAssertGreaterThan(layout.systems.count, 1, "12 bars don't fit one phone-width line")
        XCTAssertEqual(layout.measures.count, 12)
        XCTAssertEqual(Set(layout.measures.map(\.index)), Set(0..<12))
        for sys in layout.systems { XCTAssertLessThanOrEqual(sys.x1, 390) }
        // Every note and rest is hit-testable.
        let notes = score.parts[0].measures.flatMap(\.notes)
        XCTAssertEqual(Set(layout.noteFrames.keys), Set(notes.map(\.id)))
        // Systems stack downwards.
        XCTAssertTrue(zip(layout.systems, layout.systems.dropFirst()).allSatisfy { $0.staffTop < $1.staffTop })
    }

    func testHitTestMapsToPitch() throws {
        let score = Score.blank(clef: .bass, measures: 2)
        let layout = LayoutEngine.layout(score, options: LayoutOptions(width: 600))
        let sys = layout.systems[0]
        let m0 = layout.measures[0]
        // The top line of the bass staff is A3.
        let hit = try XCTUnwrap(layout.hit(CGPoint(x: m0.frame.midX, y: sys.y(ofStep: 8)), part: score.parts[0]))
        XCTAssertEqual(hit.measure, 0)
        XCTAssertEqual(hit.pitch, Pitch(.a, 3))
    }

    func testBeamsFollowTheBeat() {
        var part = Score.blank(time: TimeSignature(6, 8), measures: 1).parts[0]
        part.measures[0].items = (0..<6).map { _ in .note(NoteEvent(duration: .eighth, pitches: [Pitch(.d, 3)])) }
        let score = Score(title: "t", parts: [part])
        let layout = LayoutEngine.layout(score, options: LayoutOptions(width: 600))
        let beams = layout.primitives.filter { if case .polygon = $0 { true } else { false } }
        XCTAssertEqual(beams.count, 2, "6/8 is beamed in two groups of three")
    }
}

final class OMRConfigTests: XCTestCase {
    func testParsesAddresses() {
        XCTAssertEqual(OMRServerConfig.parse("192.168.1.20")?.baseURL.absoluteString, "http://192.168.1.20:8765")
        XCTAssertEqual(OMRServerConfig.parse("omr.local:9000")?.baseURL.absoluteString, "http://omr.local:9000")
        XCTAssertEqual(OMRServerConfig.parse("https://omr.example.com/")?.baseURL.absoluteString, "https://omr.example.com")
        XCTAssertNil(OMRServerConfig.parse("  "))
        XCTAssertNil(OMRServerConfig.parse("token", token: "")?.token)
    }
}

final class LibraryTests: XCTestCase {
    func testSaveLoadDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = ScoreLibrary(directory: dir)
        let score = Score.blank(title: "Scales", key: KeySignature(fifths: 1))
        try lib.save(score, original: Data("%PDF".utf8))
        XCTAssertEqual(lib.summaries.value.map(\.title), ["Scales"])
        XCTAssertTrue(lib.summaries.value[0].hasOriginal)
        XCTAssertEqual(try lib.load(score.id).parts, score.parts)
        XCTAssertEqual(ScoreLibrary(directory: dir).summaries.value.count, 1, "found again on a fresh scan")
        lib.delete(score.id)
        XCTAssertTrue(lib.summaries.value.isEmpty)
    }
}

final class SynthTests: XCTestCase {
    func testRendersAudibleInRangeAudio() throws {
        let part = try MusicXMLTests().etude().parts[0]
        let schedule = PlaybackSchedule.build(part: part)
        let synth = Synth(sampleRate: 22050)
        let music = synth.renderMusic(schedule)
        XCTAssertEqual(Double(music.count) / 22050, schedule.duration + 0.6, accuracy: 0.01)
        XCTAssertLessThanOrEqual(music.map(abs).max() ?? 2, 1)
        XCTAssertGreaterThan(music.map(abs).max() ?? 0, 0.05)
        let clicks = synth.renderClicks(schedule, countIn: [-2, -1])
        XCTAssertGreaterThan(clicks.count, music.count, "count-in adds lead time")
    }

    func testDroneIsInTune() throws {
        let synth = Synth(sampleRate: 44100)
        let f = CelloString.c.frequency()
        let drone = synth.renderDrone(frequency: f)
        let r = try XCTUnwrap(PitchDetector(sampleRate: 44100).detect(Array(drone.prefix(4096))))
        XCTAssertEqual(Tuning.cents(r.frequency, relativeTo: f), 0, accuracy: 1.5)
    }
}
