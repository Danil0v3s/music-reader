import Foundation

/// The seven natural note letters. The raw value is the diatonic index within an octave (C = 0 … B = 6).
public enum Step: Int, Codable, CaseIterable, Sendable, Comparable {
    case c, d, e, f, g, a, b

    public var letter: String { ["C", "D", "E", "F", "G", "A", "B"][rawValue] }
    /// Semitones above C in the natural (unaltered) scale.
    public var semitone: Int { [0, 2, 4, 5, 7, 9, 11][rawValue] }
    /// Position on the line of fifths (F = -1, C = 0, G = 1 … B = 5). Spelling-aware tuning uses it.
    public var fifths: Int { [0, 2, 4, -1, 1, 3, 5][rawValue] }

    public init?(letter: String) {
        guard let i = ["C", "D", "E", "F", "G", "A", "B"].firstIndex(of: letter.uppercased()) else { return nil }
        self.init(rawValue: i)
    }

    public static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
}

/// A spelled pitch: letter, chromatic alteration and octave (scientific pitch notation, middle C = C4).
/// Spelling matters, and is never collapsed to a MIDI number: C♯ and D♭ sit on different staff positions,
/// take different accidentals and, in just or Pythagorean tuning, have different frequencies.
public struct Pitch: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var step: Step
    /// -2 = double flat … +2 = double sharp.
    public var alter: Int
    public var octave: Int

    public init(_ step: Step, _ octave: Int, alter: Int = 0) {
        self.step = step
        self.octave = octave
        self.alter = max(-2, min(2, alter))
    }

    /// MIDI note number (C4 = 60, A4 = 69).
    public var midi: Int { (octave + 1) * 12 + step.semitone + alter }

    /// Diatonic index counted in letter steps from C0: what decides the staff position.
    public var diatonic: Int { octave * 7 + step.rawValue }

    /// Position on the line of fifths: C = 0, G = 1, F♯ = 6, B♭ = -2.
    public var lineOfFifths: Int { step.fifths + 7 * alter }

    public var accidental: Accidental? { Accidental(alter: alter) }

    public var name: String { step.letter + (Accidental(alter: alter)?.symbol ?? "") }
    public var description: String { "\(name)\(octave)" }

    public static func < (a: Pitch, b: Pitch) -> Bool {
        a.midi != b.midi ? a.midi < b.midi : a.diatonic < b.diatonic
    }

    /// The pitch moved by `steps` letter names, keeping the octave consistent (B4 + 1 = C5). Alteration is dropped.
    public func movedDiatonically(_ steps: Int) -> Pitch {
        let d = diatonic + steps
        return Pitch(Step(rawValue: ((d % 7) + 7) % 7)!, Int(floor(Double(d) / 7)))
    }

    /// Builds a pitch from a diatonic index (as from a staff position) with an explicit alteration.
    public init(diatonic: Int, alter: Int = 0) {
        self.init(Step(rawValue: ((diatonic % 7) + 7) % 7)!, Int(floor(Double(diatonic) / 7)), alter: alter)
    }

    /// Spells a MIDI number in a key: sharps in sharp keys, flats in flat keys, diatonic notes first.
    public init(midi: Int, in key: KeySignature = KeySignature(fifths: 0)) {
        let pc = ((midi % 12) + 12) % 12
        let octaveBase = Int(floor(Double(midi) / 12)) - 1
        // A note in the scale wins: E♯ in C♯ major, C♭ in G♭ major.
        for step in Step.allCases {
            let alter = key.alter(for: step)
            let natural = step.semitone + alter
            if ((natural % 12) + 12) % 12 == pc {
                let octave = octaveBase + (natural < 0 ? 1 : natural >= 12 ? -1 : 0)
                self.init(step, octave, alter: alter)
                return
            }
        }
        // Chromatic: raise in sharp keys and C, lower in flat keys.
        let sharps: [(Step, Int)] = [(.c, 0), (.c, 1), (.d, 0), (.d, 1), (.e, 0), (.f, 0), (.f, 1), (.g, 0), (.g, 1), (.a, 0), (.a, 1), (.b, 0)]
        let flats: [(Step, Int)] = [(.c, 0), (.d, -1), (.d, 0), (.e, -1), (.e, 0), (.f, 0), (.g, -1), (.g, 0), (.a, -1), (.a, 0), (.b, -1), (.b, 0)]
        let (step, alter) = (key.fifths < 0 ? flats : sharps)[pc]
        self.init(step, octaveBase, alter: alter)
    }

    public static let middleC = Pitch(.c, 4)
    public static let a4 = Pitch(.a, 4)
}

/// The written accidental signs.
public enum Accidental: Int, Codable, CaseIterable, Sendable {
    case doubleFlat = -2, flat = -1, natural = 0, sharp = 1, doubleSharp = 2

    public init?(alter: Int) {
        guard alter != 0 else { return nil }
        self.init(rawValue: alter)
    }

    public var alter: Int { rawValue }
    public var symbol: String {
        switch self {
        case .doubleFlat: "𝄫"
        case .flat: "♭"
        case .natural: "♮"
        case .sharp: "♯"
        case .doubleSharp: "𝄪"
        }
    }
}

/// An interval between two spelled pitches, named the way theory names it: quality + diatonic number
/// (C–E♭ is a minor third, C–D♯ an augmented second, even though both span 3 semitones).
public struct Interval: Hashable, Sendable, CustomStringConvertible {
    public enum Quality: String, Sendable { case diminished = "d", minor = "m", perfect = "P", major = "M", augmented = "A" }

    /// 1 = unison, 3 = third, 8 = octave, 10 = tenth.
    public let number: Int
    public let quality: Quality
    public let semitones: Int

    public init(from a: Pitch, to b: Pitch) {
        let (lo, hi) = a <= b ? (a, b) : (b, a)
        number = hi.diatonic - lo.diatonic + 1
        semitones = hi.midi - lo.midi
        let simple = (number - 1) % 7  // 0 = unison … 6 = seventh
        let octaves = (number - 1) / 7
        let reference = [0, 2, 4, 5, 7, 9, 11][simple] + 12 * octaves
        let diff = semitones - reference
        let perfectClass = [0, 3, 4].contains(simple)
        if perfectClass {
            quality = diff < 0 ? .diminished : diff == 0 ? .perfect : .augmented
        } else {
            quality = diff < -1 ? .diminished : diff == -1 ? .minor : diff == 0 ? .major : .augmented
        }
    }

    public var description: String { "\(quality.rawValue)\(number)" }

    public var name: String {
        let q = switch quality {
        case .diminished: "diminished"
        case .minor: "minor"
        case .perfect: "perfect"
        case .major: "major"
        case .augmented: "augmented"
        }
        let n = switch number {
        case 1: "unison"
        case 2: "second"
        case 3: "third"
        case 4: "fourth"
        case 5: "fifth"
        case 6: "sixth"
        case 7: "seventh"
        case 8: "octave"
        default: "\(number)th"
        }
        return "\(q) \(n)"
    }
}
