import Foundation

// MARK: - Key signature

/// A key signature as its position on the circle of fifths (+n sharps / -n flats) plus the mode.
public struct KeySignature: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Mode: String, Codable, Sendable, CaseIterable { case major, minor }

    /// -7 (C♭ major / A♭ minor) … +7 (C♯ major / A♯ minor).
    public var fifths: Int
    public var mode: Mode

    public init(fifths: Int, mode: Mode = .major) {
        self.fifths = max(-7, min(7, fifths))
        self.mode = mode
    }

    /// The order sharps are added: F C G D A E B (flats are the reverse).
    public static let sharpOrder: [Step] = [.f, .c, .g, .d, .a, .e, .b]
    public static let flatOrder: [Step] = [.b, .e, .a, .d, .g, .c, .f]

    /// The steps the signature alters, in the order they're written.
    public var alteredSteps: [Step] {
        fifths >= 0 ? Array(Self.sharpOrder.prefix(fifths)) : Array(Self.flatOrder.prefix(-fifths))
    }

    /// The alteration the signature applies to `step`: +1, -1 or 0.
    public func alter(for step: Step) -> Int {
        alteredSteps.contains(step) ? (fifths > 0 ? 1 : -1) : 0
    }

    /// The tonic: the major tonic is `fifths` steps round the circle from C; the relative minor sits 3 steps further.
    public var tonic: Pitch {
        let position = fifths + (mode == .minor ? 3 : 0)
        let steps: [Step] = [.f, .c, .g, .d, .a, .e, .b]
        let index = ((position + 1) % 7 + 7) % 7
        let alter = Int(floor(Double(position + 1) / 7))
        return Pitch(steps[index], 4, alter: alter)
    }

    /// The seven scale degrees from the tonic upwards (natural minor for minor keys).
    public var scale: [Pitch] {
        let t = tonic
        return (0..<7).map { i in
            let p = t.movedDiatonically(i)
            return Pitch(p.step, p.octave, alter: alter(for: p.step))
        }
    }

    public var name: String { "\(tonic.name) \(mode.rawValue)" }
    public var description: String { name }

    public static let cMajor = KeySignature(fifths: 0)
}

// MARK: - Clef

/// A clef: which pitch a sign fixes on which staff line. Cellists read three: bass, tenor and treble.
public struct Clef: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Sign: String, Codable, Sendable { case g = "G", f = "F", c = "C", percussion = "percussion" }

    public var sign: Sign
    /// Staff line the sign sits on, 1 = bottom line.
    public var line: Int
    /// Octave transposition (-1 for the octave-down treble some editions use for tenor voice).
    public var octaveChange: Int

    public init(sign: Sign, line: Int, octaveChange: Int = 0) {
        self.sign = sign
        self.line = line
        self.octaveChange = octaveChange
    }

    public static let treble = Clef(sign: .g, line: 2)
    public static let bass = Clef(sign: .f, line: 4)
    public static let tenor = Clef(sign: .c, line: 4)
    public static let alto = Clef(sign: .c, line: 3)

    /// The clefs offered in the editor, in the order a cellist meets them.
    public static let common: [Clef] = [.bass, .tenor, .treble, .alto]

    /// The pitch the clef's sign names (G4, F3 or C4), before octave transposition.
    private var referencePitch: Pitch {
        switch sign {
        case .g: Pitch(.g, 4)
        case .f: Pitch(.f, 3)
        case .c, .percussion: Pitch(.c, 4)
        }
    }

    /// Diatonic index of the pitch on the bottom line (E4 in treble, G2 in bass, D3 in tenor).
    public var bottomLineDiatonic: Int {
        referencePitch.diatonic + 7 * octaveChange - (line - 1) * 2
    }

    /// Staff position of a pitch: 0 = bottom line, 1 = first space, 8 = top line; negative = below the staff.
    public func staffStep(of pitch: Pitch) -> Int { pitch.diatonic - bottomLineDiatonic }

    /// The natural pitch written at a staff position.
    public func pitch(atStaffStep step: Int) -> Pitch { Pitch(diatonic: bottomLineDiatonic + step) }

    /// Staff steps of the key signature's accidentals, in writing order. Tenor clef places its sharps
    /// low (F♯ in the first space) instead of copying treble's shape, as engraving convention requires.
    public func keySignatureSteps(_ key: KeySignature) -> [Int] {
        let treblesharps = [8, 5, 9, 6, 3, 7, 4]
        let trebleFlats = [4, 7, 3, 6, 2, 5, 1]
        let (sharps, flats): ([Int], [Int])
        switch (sign, line) {
        case (.f, 4): (sharps, flats) = (treblesharps.map { $0 - 2 }, trebleFlats.map { $0 - 2 })
        case (.c, 3): (sharps, flats) = (treblesharps.map { $0 - 1 }, trebleFlats.map { $0 - 1 })
        case (.c, 4): (sharps, flats) = ([2, 6, 3, 7, 4, 8, 5], trebleFlats.map { $0 + 1 })
        default:
            // Other clefs: keep treble's pattern, shifted by the clef's offset folded into one octave.
            let shift = (((Clef.treble.bottomLineDiatonic - bottomLineDiatonic) % 7) + 7) % 7
            let fold: (Int) -> Int = { s in let v = s + shift; return v > 9 ? v - 7 : v }
            (sharps, flats) = (treblesharps.map(fold), trebleFlats.map(fold))
        }
        return key.fifths >= 0 ? Array(sharps.prefix(key.fifths)) : Array(flats.prefix(-key.fifths))
    }

    public var name: String {
        switch (sign, line) {
        case (.g, 2): octaveChange == -1 ? "Treble 8vb" : "Treble"
        case (.f, 4): "Bass"
        case (.c, 4): "Tenor"
        case (.c, 3): "Alto"
        case (.c, 1): "Soprano"
        case (.c, 2): "Mezzo-soprano"
        case (.f, 3): "Baritone"
        default: "\(sign.rawValue) clef, line \(line)"
        }
    }

    public var description: String { name }
}

// MARK: - Time signature

public struct TimeSignature: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Symbol: String, Codable, Sendable { case normal, common, cut }

    public var beats: Int
    public var beatType: Int
    public var symbol: Symbol

    public init(_ beats: Int, _ beatType: Int, symbol: Symbol = .normal) {
        self.beats = beats
        self.beatType = beatType
        self.symbol = symbol
    }

    public static let common = TimeSignature(4, 4, symbol: .common)
    public static let cut = TimeSignature(2, 2, symbol: .cut)

    /// What a full measure holds, as a fraction of a whole note (3/4 → 3/4, 6/8 → 3/4).
    public var measureDuration: Fraction { Fraction(beats, beatType) }

    /// Compound meters (6/8, 9/8, 12/8) are felt in dotted beats of three.
    public var isCompound: Bool { beats % 3 == 0 && beats > 3 && beatType >= 8 }

    /// The felt beat: a dotted quarter in 6/8, a quarter in 3/4, a half in 2/2.
    public var beatDuration: Fraction {
        isCompound ? Fraction(3, beatType) : Fraction(1, beatType)
    }

    public var beatsPerMeasure: Int { isCompound ? beats / 3 : beats }

    public var description: String { "\(beats)/\(beatType)" }
}

// MARK: - NoteValue

/// A written note value: its type, augmentation dots and an optional tuplet ratio.
public struct NoteValue: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Kind: Int, Codable, CaseIterable, Sendable, Comparable {
        case breve = -1, whole = 0, half = 1, quarter = 2, eighth = 3, sixteenth = 4, thirtySecond = 5, sixtyFourth = 6

        /// Undotted value as a fraction of a whole note.
        public var value: Fraction { rawValue < 0 ? Fraction(2) : Fraction(1, 1 << rawValue) }
        /// Flags or beams the value carries (eighth = 1).
        public var beams: Int { max(0, rawValue - 2) }
        public var hasStem: Bool { rawValue >= 1 }

        public var musicXMLName: String {
            switch self {
            case .breve: "breve"
            case .whole: "whole"
            case .half: "half"
            case .quarter: "quarter"
            case .eighth: "eighth"
            case .sixteenth: "16th"
            case .thirtySecond: "32nd"
            case .sixtyFourth: "64th"
            }
        }

        public init?(musicXMLName: String) {
            guard let k = Kind.allCases.first(where: { $0.musicXMLName == musicXMLName }) else { return nil }
            self = k
        }

        public var name: String {
            switch self {
            case .breve: "Breve"
            case .whole: "Whole"
            case .half: "Half"
            case .quarter: "Quarter"
            case .eighth: "Eighth"
            case .sixteenth: "16th"
            case .thirtySecond: "32nd"
            case .sixtyFourth: "64th"
            }
        }

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// `actual` notes in the time of `normal`: a triplet is 3:2.
    public struct Tuplet: Hashable, Codable, Sendable {
        public var actual: Int
        public var normal: Int
        public init(actual: Int, normal: Int) { self.actual = actual; self.normal = normal }
        public static let triplet = Tuplet(actual: 3, normal: 2)
    }

    public var kind: Kind
    public var dots: Int
    public var tuplet: Tuplet?

    public init(_ kind: Kind, dots: Int = 0, tuplet: Tuplet? = nil) {
        self.kind = kind
        self.dots = max(0, min(3, dots))
        self.tuplet = tuplet
    }

    /// Sounding length as a fraction of a whole note: each dot adds half the previous value.
    public var value: Fraction {
        var v = kind.value
        var add = kind.value
        for _ in 0..<dots {
            add = add * Fraction(1, 2)
            v += add
        }
        if let t = tuplet { v = v * Fraction(t.normal, t.actual) }
        return v
    }

    /// Length in quarter-note beats, the unit tempo is usually given in.
    public var quarters: Double { value.double * 4 }

    /// The simplest undotted/dotted value that equals `value` exactly, if any (used to read MusicXML
    /// notes that only give a `<duration>`).
    public static func from(value: Fraction) -> NoteValue? {
        for kind in Kind.allCases {
            for dots in 0...2 {
                let d = NoteValue(kind, dots: dots)
                if d.value == value { return d }
            }
        }
        for kind in Kind.allCases {
            let d = NoteValue(kind, tuplet: .triplet)
            if d.value == value { return d }
        }
        return nil
    }

    /// Splits an arbitrary length into a list of writable values (largest first), for filling gaps with rests.
    public static func decompose(_ value: Fraction) -> [NoteValue] {
        var remaining = value
        var out: [NoteValue] = []
        while remaining > .zero {
            guard let kind = Kind.allCases.first(where: { $0.value <= remaining && $0 != .breve }) else { break }
            var d = NoteValue(kind)
            if NoteValue(kind, dots: 1).value <= remaining { d = NoteValue(kind, dots: 1) }
            out.append(d)
            remaining -= d.value
        }
        return out
    }

    public var description: String {
        kind.name + String(repeating: ".", count: dots) + (tuplet.map { " (\($0.actual):\($0.normal))" } ?? "")
    }

    public static let whole = NoteValue(.whole)
    public static let half = NoteValue(.half)
    public static let quarter = NoteValue(.quarter)
    public static let eighth = NoteValue(.eighth)
    public static let sixteenth = NoteValue(.sixteenth)
}
