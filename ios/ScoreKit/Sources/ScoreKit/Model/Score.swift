import Foundation

/// Where an imported copy came from: the share code, its owner's name, and what it was called.
public struct ImportOrigin: Hashable, Codable, Sendable {
    public var code: String
    public var owner: String
    public var title: String?

    public init(code: String, owner: String, title: String? = nil) {
        self.code = code
        self.owner = owner
        self.title = title
    }
}

/// A whole piece. The app works with a single-staff part (the cello part) but the model keeps a list so a
/// MusicXML file with several parts round-trips and the user can pick which one to read.
public struct Score: Hashable, Codable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable { case manual, musicXML, omr }

    public var id: UUID
    public var title: String
    public var composer: String
    public var parts: [Part]
    public var source: Source
    public var created: Date
    public var modified: Date
    /// For a copy imported from someone's share: whose it was. Nil for everything else.
    public var importedFrom: ImportOrigin?

    public init(id: UUID = UUID(), title: String, composer: String = "", parts: [Part], source: Source = .manual,
                created: Date = Date(), modified: Date = Date()) {
        self.id = id
        self.title = title
        self.composer = composer
        self.parts = parts
        self.source = source
        self.created = created
        self.modified = modified
    }

    /// A blank cello score: `measures` empty bars of whole rests in the given meter.
    public static func blank(title: String = "Untitled", clef: Clef = .bass, key: KeySignature = .cMajor,
                             time: TimeSignature = .common, tempo: Tempo = .default, measures: Int = 4) -> Score {
        var bars: [Measure] = []
        for i in 0..<max(1, measures) {
            var m = Measure(number: i + 1)
            if i == 0 { m.attributes = MeasureAttributes(clef: clef, key: key, time: time, tempo: tempo) }
            m.items = [.note(NoteEvent(rest: .whole, measureRest: true))]
            bars.append(m)
        }
        return Score(title: title, parts: [Part(name: "Violoncello", measures: bars)])
    }
}

public struct Part: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// General MIDI program, 0-based (42 = Cello).
    public var midiProgram: Int
    public var measures: [Measure]

    public init(id: String = "P1", name: String, midiProgram: Int = 42, measures: [Measure]) {
        self.id = id
        self.name = name
        self.midiProgram = midiProgram
        self.measures = measures
    }
}

/// Changes of clef, key, meter or tempo that take effect at the start of a measure. nil fields carry over.
public struct MeasureAttributes: Hashable, Codable, Sendable {
    public var clef: Clef?
    public var key: KeySignature?
    public var time: TimeSignature?
    public var tempo: Tempo?

    public init(clef: Clef? = nil, key: KeySignature? = nil, time: TimeSignature? = nil, tempo: Tempo? = nil) {
        self.clef = clef
        self.key = key
        self.time = time
        self.tempo = tempo
    }

    public var isEmpty: Bool { clef == nil && key == nil && time == nil && tempo == nil }
}

/// The attributes in force at some point: every field resolved.
public struct ResolvedAttributes: Hashable, Sendable {
    public var clef: Clef
    public var key: KeySignature
    public var time: TimeSignature
    public var tempo: Tempo

    public static let initial = ResolvedAttributes(clef: .bass, key: .cMajor, time: .common, tempo: .default)

    public func applying(_ a: MeasureAttributes?) -> ResolvedAttributes {
        guard let a else { return self }
        return ResolvedAttributes(clef: a.clef ?? clef, key: a.key ?? key, time: a.time ?? time, tempo: a.tempo ?? tempo)
    }
}

public struct Measure: Hashable, Codable, Sendable, Identifiable {
    public enum Barline: String, Codable, Sendable { case regular, double, final, repeatStart, repeatEnd, repeatBoth }

    public var id: UUID
    public var number: Int
    public var attributes: MeasureAttributes?
    /// Notes, rests and zero-length directions in time order.
    public var items: [MeasureItem]
    public var barline: Barline
    /// A pickup (anacrusis): allowed to be shorter than the meter.
    public var isPickup: Bool

    public init(id: UUID = UUID(), number: Int, attributes: MeasureAttributes? = nil, items: [MeasureItem] = [],
                barline: Barline = .regular, isPickup: Bool = false) {
        self.id = id
        self.number = number
        self.attributes = attributes
        self.items = items
        self.barline = barline
        self.isPickup = isPickup
    }

    public var notes: [NoteEvent] { items.compactMap { if case .note(let n) = $0 { n } else { nil } } }

    /// Sum of the measure's note and rest values (grace notes take no time).
    public var filled: Fraction { notes.filter { !$0.isGrace }.reduce(.zero) { $0 + $1.duration.value } }

    public func fill(in time: TimeSignature) -> MeasureFill {
        // A whole-measure rest fills any meter.
        if notes.count == 1, notes[0].isMeasureRest { return .complete }
        let diff = filled - time.measureDuration
        if diff.isZero { return .complete }
        if diff < .zero { return isPickup ? .complete : .underfull(missing: .zero - diff) }
        return .overfull(excess: diff)
    }
}

public enum MeasureFill: Hashable, Sendable {
    case complete
    case underfull(missing: Fraction)
    case overfull(excess: Fraction)
}

/// One entry in a measure. Directions sit before the note they apply to and take no time.
public enum MeasureItem: Hashable, Codable, Sendable {
    case note(NoteEvent)
    case clef(Clef)
    case dynamic(Dynamic)
    case wedge(Wedge)
    case tempo(Tempo)
    case text(String)

    public var note: NoteEvent? { if case .note(let n) = self { n } else { nil } }
}

// MARK: - Notes

/// A note, a chord (cello double/triple stops) or a rest: one rhythmic event with zero or more pitches.
public struct NoteEvent: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var duration: NoteValue
    /// Empty for a rest. Several for a double stop, lowest first.
    public var pitches: [Pitch]
    /// Accidentals the source printed explicitly (courtesy/cautionary), by pitch index.
    public var forcedAccidentals: Set<Int>
    public var isGrace: Bool
    /// A rest that fills the whole measure whatever the meter (centred, whole-rest glyph).
    public var isMeasureRest: Bool
    /// Tied into the next note of the same pitch.
    public var tieToNext: Bool
    public var slurStart: Bool
    public var slurStop: Bool
    public var articulations: Set<Articulation>
    public var bowing: Bowing?
    /// Left-hand fingers, one per pitch where given: 0 = open string, 1–4 fingers, 5 = thumb (cello thumb position).
    public var fingerings: [Int]
    public var string: CelloString?
    public var harmonic: Bool

    public init(id: UUID = UUID(), duration: NoteValue, pitches: [Pitch], isGrace: Bool = false) {
        self.id = id
        self.duration = duration
        self.pitches = pitches.sorted()
        self.forcedAccidentals = []
        self.isGrace = isGrace
        self.isMeasureRest = false
        self.tieToNext = false
        self.slurStart = false
        self.slurStop = false
        self.articulations = []
        self.bowing = nil
        self.fingerings = []
        self.string = nil
        self.harmonic = false
    }

    public init(id: UUID = UUID(), rest duration: NoteValue, measureRest: Bool = false) {
        self.init(id: id, duration: duration, pitches: [])
        self.isMeasureRest = measureRest
    }

    public var isRest: Bool { pitches.isEmpty }
}

public enum Articulation: String, Codable, CaseIterable, Sendable {
    case staccato, staccatissimo, accent, tenuto, marcato, fermata, spiccato

    /// Portion of the written value that sounds (staccato is roughly half).
    public var lengthFactor: Double {
        switch self {
        case .staccato, .spiccato: 0.5
        case .staccatissimo: 0.3
        case .tenuto: 1.0
        case .accent, .marcato, .fermata: 0.9
        }
    }

    public var velocityBoost: Double {
        switch self {
        case .accent: 0.18
        case .marcato: 0.25
        default: 0
        }
    }
}

/// Bow direction: ⊓ down-bow (frog to tip), V up-bow.
public enum Bowing: String, Codable, CaseIterable, Sendable { case down, up }

public enum Dynamic: String, Codable, CaseIterable, Sendable {
    case ppp, pp, p, mp, mf, f, ff, fff, fp, sf, sfz, fz

    /// Playback loudness 0…1, a gentle curve so pp is still audible.
    public var velocity: Double {
        switch self {
        case .ppp: 0.18
        case .pp: 0.26
        case .p: 0.36
        case .mp: 0.48
        case .mf: 0.6
        case .f: 0.74
        case .ff: 0.86
        case .fff: 0.96
        case .fp: 0.74
        case .sf, .sfz, .fz: 0.9
        }
    }

    /// Accent-type marks change one note, not the level that follows.
    public var isAccent: Bool { [.sf, .sfz, .fz, .fp].contains(self) }
}

public enum Wedge: String, Codable, Sendable { case crescendo, diminuendo, stop }
