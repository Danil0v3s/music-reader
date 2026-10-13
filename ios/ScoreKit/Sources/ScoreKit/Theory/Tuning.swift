import Foundation

/// How written pitches become frequencies. A cellist tunes the open strings in pure fifths and plays
/// expressively (leading tones high, Pythagorean), or adjusts thirds to sit pure in chords (just); the
/// piano is equal-tempered. The reference A is configurable (440 Hz, 442 in many orchestras, 415 baroque).
public struct Tuning: Hashable, Codable, Sendable {
    public enum System: String, Codable, CaseIterable, Sendable {
        case equal, pythagorean, just

        public var name: String {
            switch self {
            case .equal: "Equal temperament"
            case .pythagorean: "Pythagorean"
            case .just: "Just intonation"
            }
        }

        public var summary: String {
            switch self {
            case .equal: "Every semitone is 100 cents. The piano's tuning."
            case .pythagorean: "Built from pure 3:2 fifths. Sharps sit high, flats low. Melodic, like open strings."
            case .just: "Pure ratios to the key's tonic. Major thirds sit 14 cents low. Harmonic, for double stops."
            }
        }
    }

    public var referenceA4: Double
    public var system: System

    public init(referenceA4: Double = 440, system: System = .equal) {
        self.referenceA4 = referenceA4
        self.system = system
    }

    public static let standard = Tuning()

    /// Equal-tempered frequency of a MIDI number.
    public func equalFrequency(midi: Double) -> Double { referenceA4 * pow(2, (midi - 69) / 12) }

    /// The target frequency of a written pitch. Non-equal systems are anchored on the key's tonic,
    /// itself taken from equal temperament, so the reference A stays the reference.
    public func frequency(of pitch: Pitch, in key: KeySignature = .cMajor) -> Double {
        switch system {
        case .equal:
            return equalFrequency(midi: Double(pitch.midi))
        case .pythagorean:
            // Steps round the line of fifths from the tonic, each a pure 3:2, then folded into the right octave.
            let tonic = key.tonic
            let fifths = pitch.lineOfFifths - tonic.lineOfFifths
            return anchored(pitch: pitch, tonic: tonic, ratio: pow(1.5, Double(fifths)))
        case .just:
            let tonic = key.tonic
            let fifths = pitch.lineOfFifths - tonic.lineOfFifths
            return anchored(pitch: pitch, tonic: tonic, ratio: Self.justRatio(fifthsFromTonic: fifths))
        }
    }

    /// Places `ratio` (relative to the tonic, any octave) in the octave the written pitch is in.
    private func anchored(pitch: Pitch, tonic: Pitch, ratio: Double) -> Double {
        let tonicFreq = equalFrequency(midi: Double(tonic.midi))
        let target = equalFrequency(midi: Double(pitch.midi))
        var f = tonicFreq * ratio
        while f < target / sqrt(2) { f *= 2 }
        while f > target * sqrt(2) { f /= 2 }
        return f
    }

    /// 5-limit just ratios, chosen by spelling: the line-of-fifths distance from the tonic tells a major
    /// third (+4: 5/4) from a diminished fourth (-8: 32/25). Distances outside the table fall back to
    /// Pythagorean, which is what a player does with remote chromatic notes.
    static func justRatio(fifthsFromTonic n: Int) -> Double {
        switch n {
        case 0: 1                 // unison
        case 1: 3.0 / 2           // P5
        case -1: 4.0 / 3          // P4
        case 2: 9.0 / 8           // M2
        case -2: 16.0 / 9         // m7 (dominant seventh flavour: 16/9)
        case 3: 5.0 / 3           // M6
        case -3: 6.0 / 5          // m3
        case 4: 5.0 / 4           // M3
        case -4: 8.0 / 5          // m6
        case 5: 15.0 / 8          // M7 (leading tone)
        case -5: 16.0 / 15        // m2
        case 6: 45.0 / 32         // A4
        case -6: 64.0 / 45        // d5
        default: pow(1.5, Double(n))
        }
    }

    /// Cents from `reference` to `frequency` (positive = sharp). 100 cents = one equal-tempered semitone.
    public static func cents(_ frequency: Double, relativeTo reference: Double) -> Double {
        1200 * log2(frequency / reference)
    }

    /// The nearest equal-tempered note to a frequency and how far off it is, for the free tuner.
    public func nearest(to frequency: Double, in key: KeySignature = .cMajor) -> (pitch: Pitch, cents: Double) {
        let midi = 69 + 12 * log2(frequency / referenceA4)
        let pitch = Pitch(midi: Int(midi.rounded()), in: key)
        return (pitch, Self.cents(frequency, relativeTo: self.frequency(of: pitch, in: key)))
    }
}

/// The cello's open strings, tuned down from A in pure fifths.
public enum CelloString: Int, Codable, CaseIterable, Sendable {
    case a = 1, d = 2, g = 3, c = 4

    public var pitch: Pitch {
        switch self {
        case .a: Pitch(.a, 3)
        case .d: Pitch(.d, 3)
        case .g: Pitch(.g, 2)
        case .c: Pitch(.c, 2)
        }
    }

    /// The Roman numeral string indication printed in scores (I = A string).
    public var roman: String { ["I", "II", "III", "IV"][rawValue - 1] }

    /// Open-string frequency with pure 3:2 fifths below A3 = referenceA4 / 2 (C2 ≈ 65.19 Hz at A440,
    /// about 6 cents below equal temperament's 65.41).
    public func frequency(referenceA4: Double = 440) -> Double {
        referenceA4 / 2 / pow(1.5, Double(rawValue - 1))
    }

    /// The highest string whose open note is at or below the pitch: where a first-position fingering
    /// chart plays it. nil below the C string.
    public static func natural(for pitch: Pitch) -> CelloString? {
        allCases.first { pitch.midi >= $0.pitch.midi }
    }
}
