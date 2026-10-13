import XCTest
@testable import ScoreKit

final class TheoryTests: XCTestCase {
    func testPitchNumbers() {
        XCTAssertEqual(Pitch.middleC.midi, 60)
        XCTAssertEqual(Pitch.a4.midi, 69)
        XCTAssertEqual(Pitch(.c, 2).midi, 36, "cello C string")
        XCTAssertEqual(Pitch(.b, 3, alter: 1).midi, 60, "B♯3 sounds as middle C")
        XCTAssertEqual(Pitch(.c, 4, alter: -1).midi, 59)
        XCTAssertEqual(Pitch(.f, 4, alter: 1).description, "F♯4")
    }

    func testSpellingFollowsKey() {
        XCTAssertEqual(Pitch(midi: 66, in: KeySignature(fifths: 2)), Pitch(.f, 4, alter: 1))
        XCTAssertEqual(Pitch(midi: 70, in: KeySignature(fifths: -1)), Pitch(.b, 4, alter: -1))
        XCTAssertEqual(Pitch(midi: 65, in: KeySignature(fifths: 7)), Pitch(.e, 4, alter: 1), "E♯ in C♯ major")
        XCTAssertEqual(Pitch(midi: 71, in: KeySignature(fifths: -6)), Pitch(.c, 5, alter: -1), "C♭ in G♭ major")
        XCTAssertEqual(Pitch(midi: 61, in: .cMajor), Pitch(.c, 4, alter: 1))
    }

    func testDiatonicMovement() {
        XCTAssertEqual(Pitch(.b, 4).movedDiatonically(1), Pitch(.c, 5))
        XCTAssertEqual(Pitch(.c, 4).movedDiatonically(-1), Pitch(.b, 3))
        let n = NoteEvent(duration: .quarter, pitches: [Pitch(.e, 4)])
        XCTAssertEqual(n.movedDiatonically(1, in: KeySignature(fifths: 2)).pitches, [Pitch(.f, 4, alter: 1)], "stays in D major")
    }

    func testIntervalsAreNamedBySpelling() {
        XCTAssertEqual(Interval(from: Pitch(.c, 4), to: Pitch(.e, 4, alter: -1)).description, "m3")
        XCTAssertEqual(Interval(from: Pitch(.c, 4), to: Pitch(.d, 4, alter: 1)).description, "A2")
        XCTAssertEqual(Interval(from: Pitch(.c, 2), to: Pitch(.g, 2)).description, "P5")
        XCTAssertEqual(Interval(from: Pitch(.b, 3), to: Pitch(.f, 4)).description, "d5")
        XCTAssertEqual(Interval(from: Pitch(.c, 3), to: Pitch(.e, 4)).description, "M10")
        XCTAssertEqual(Interval(from: Pitch(.c, 4), to: Pitch(.c, 5)).name, "perfect octave")
    }

    func testKeys() {
        XCTAssertEqual(KeySignature(fifths: 2).name, "D major")
        XCTAssertEqual(KeySignature(fifths: -3, mode: .minor).name, "C minor")
        XCTAssertEqual(KeySignature(fifths: 6).name, "F♯ major")
        XCTAssertEqual(KeySignature(fifths: -6).name, "G♭ major")
        XCTAssertEqual(KeySignature(fifths: 3).alteredSteps, [.f, .c, .g])
        XCTAssertEqual(KeySignature(fifths: -2).alter(for: .e), -1)
        XCTAssertEqual(KeySignature(fifths: 2).scale.map(\.name), ["D", "E", "F♯", "G", "A", "B", "C♯"])
    }

    func testClefStaffPositions() {
        XCTAssertEqual(Clef.treble.staffStep(of: Pitch(.e, 4)), 0)
        XCTAssertEqual(Clef.bass.staffStep(of: Pitch(.g, 2)), 0)
        XCTAssertEqual(Clef.bass.staffStep(of: Pitch(.a, 3)), 8, "A3 on the top line of the bass staff")
        XCTAssertEqual(Clef.tenor.staffStep(of: Pitch(.c, 4)), 6, "tenor clef: middle C on the fourth line")
        XCTAssertEqual(Clef.alto.staffStep(of: Pitch(.c, 4)), 4)
        XCTAssertEqual(Clef.bass.staffStep(of: Pitch(.c, 2)), -4, "C string: two ledger lines below")
        XCTAssertEqual(Clef.tenor.pitch(atStaffStep: 0), Pitch(.d, 3))
    }

    func testKeySignaturePlacement() {
        XCTAssertEqual(Clef.treble.keySignatureSteps(KeySignature(fifths: 2)), [8, 5])
        XCTAssertEqual(Clef.bass.keySignatureSteps(KeySignature(fifths: 2)), [6, 3])
        XCTAssertEqual(Clef.tenor.keySignatureSteps(KeySignature(fifths: 2)), [2, 6], "tenor clef places F♯ low")
        XCTAssertEqual(Clef.bass.keySignatureSteps(KeySignature(fifths: -3)), [2, 5, 1])
    }

    func testNoteValues() {
        XCTAssertEqual(NoteValue.quarter.value, Fraction(1, 4))
        XCTAssertEqual(NoteValue(.quarter, dots: 1).value, Fraction(3, 8))
        XCTAssertEqual(NoteValue(.half, dots: 2).value, Fraction(7, 8))
        XCTAssertEqual(NoteValue(.eighth, tuplet: .triplet).value, Fraction(1, 12))
        XCTAssertEqual(NoteValue(.eighth, tuplet: .triplet).value * 3, Fraction(1, 4), "three triplet eighths fill a beat")
        XCTAssertEqual(NoteValue.decompose(Fraction(3, 4)), [NoteValue(.half, dots: 1)])
        XCTAssertEqual(NoteValue.decompose(Fraction(5, 8)), [NoteValue(.half), NoteValue(.eighth)])
    }

    func testMeters() {
        XCTAssertEqual(TimeSignature(6, 8).beatDuration, Fraction(3, 8))
        XCTAssertEqual(TimeSignature(6, 8).beatsPerMeasure, 2)
        XCTAssertEqual(TimeSignature(3, 4).beatsPerMeasure, 3)
        XCTAssertFalse(TimeSignature(3, 8).isCompound)
    }

    func testTempo() {
        XCTAssertEqual(Tempo(bpm: 60).secondsPerWholeNote, 4, accuracy: 1e-9)
        XCTAssertEqual(Tempo(bpm: 60, beatUnit: NoteValue(.quarter, dots: 1)).quarterBPM, 90, accuracy: 1e-9)
        XCTAssertEqual(Tempo(bpm: 132).marking, .allegro)
        XCTAssertEqual(Tempo(bpm: 70).marking, .adagio)
        XCTAssertEqual(TempoMarking.parse("Allegretto grazioso"), .allegretto)
        XCTAssertEqual(TempoMarking.parse("Allegro ma non troppo"), .allegro)
    }

    func testMeasureFill() {
        var m = Measure(number: 1, items: [.note(NoteEvent(duration: .half, pitches: [Pitch(.d, 3)]))])
        XCTAssertEqual(m.fill(in: TimeSignature(3, 4)), .underfull(missing: Fraction(1, 4)))
        m.items.append(.note(NoteEvent(duration: .half, pitches: [Pitch(.e, 3)])))
        XCTAssertEqual(m.fill(in: TimeSignature(3, 4)), .overfull(excess: Fraction(1, 4)))
        m.isPickup = true
        m.items.removeLast()
        XCTAssertEqual(m.fill(in: TimeSignature(3, 4)), .complete, "a pickup may be short")
    }

    func testAccidentalRules() {
        let key = KeySignature(fifths: 2)
        let a = NoteEvent(duration: .quarter, pitches: [Pitch(.f, 3)])       // F♮ against the key: natural
        let b = NoteEvent(duration: .quarter, pitches: [Pitch(.f, 3)])       // same bar: carries, no sign
        let c = NoteEvent(duration: .quarter, pitches: [Pitch(.f, 3, alter: 1)])  // back to F♯: needs a sharp
        let d = NoteEvent(duration: .quarter, pitches: [Pitch(.f, 4, alter: 1)])  // other octave: key applies
        let m = Measure(number: 1, items: [a, b, c, d].map { .note($0) })
        let shown = AccidentalRules.displayed(in: m, key: key)
        XCTAssertEqual(shown[a.id], [0: .natural])
        XCTAssertNil(shown[b.id])
        XCTAssertEqual(shown[c.id], [0: .sharp])
        XCTAssertNil(shown[d.id])
    }
}

final class TuningTests: XCTestCase {
    func testEqualTemperament() {
        let t = Tuning.standard
        XCTAssertEqual(t.frequency(of: .a4), 440, accuracy: 1e-9)
        XCTAssertEqual(t.frequency(of: Pitch(.a, 3)), 220, accuracy: 1e-9)
        XCTAssertEqual(t.frequency(of: Pitch(.c, 2)), 65.406, accuracy: 0.001)
        XCTAssertEqual(Tuning(referenceA4: 442).frequency(of: .a4), 442, accuracy: 1e-9)
    }

    func testJustThirdsAreLow() {
        let just = Tuning(system: .just)
        let key = KeySignature(fifths: 0)
        let cents = Tuning.cents(just.frequency(of: Pitch(.e, 4), in: key), relativeTo: Tuning.standard.frequency(of: Pitch(.e, 4)))
        XCTAssertEqual(cents, -13.69, accuracy: 0.01, "a pure major third is ~14 cents below equal temperament")
        XCTAssertEqual(just.frequency(of: Pitch(.c, 4), in: key), Tuning.standard.frequency(of: Pitch(.c, 4)), accuracy: 1e-9)
    }

    func testPythagoreanSharpsHighFlatsLow() {
        let p = Tuning(system: .pythagorean)
        let key = KeySignature.cMajor
        let fSharp = Tuning.cents(p.frequency(of: Pitch(.f, 4, alter: 1), in: key), relativeTo: Tuning.standard.frequency(of: Pitch(.f, 4, alter: 1)))
        let gFlat = Tuning.cents(p.frequency(of: Pitch(.g, 4, alter: -1), in: key), relativeTo: Tuning.standard.frequency(of: Pitch(.g, 4, alter: -1)))
        XCTAssertGreaterThan(fSharp, gFlat, "F♯ sits above G♭ in Pythagorean tuning")
        XCTAssertEqual(fSharp - gFlat, 23.46, accuracy: 0.01, "the Pythagorean comma")
    }

    func testCelloOpenStringsInFifths() {
        XCTAssertEqual(CelloString.a.frequency(), 220, accuracy: 1e-9)
        XCTAssertEqual(CelloString.d.frequency(), 146.667, accuracy: 0.001)
        XCTAssertEqual(CelloString.c.frequency(), 65.185, accuracy: 0.001)
        XCTAssertEqual(CelloString.natural(for: Pitch(.e, 3)), .d)
        XCTAssertEqual(CelloString.natural(for: Pitch(.c, 2)), .c)
        XCTAssertNil(CelloString.natural(for: Pitch(.b, 1)))
    }

    func testNearest() {
        let (p, c) = Tuning.standard.nearest(to: 442)
        XCTAssertEqual(p, .a4)
        XCTAssertEqual(c, 7.85, accuracy: 0.01)
    }
}
