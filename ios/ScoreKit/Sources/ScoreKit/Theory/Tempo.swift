import Foundation

/// A tempo: beats per minute counted in `beatUnit` (♩ = 72, or ♩. = 60 in 6/8), with an optional
/// Italian marking ("Allegro moderato").
public struct Tempo: Hashable, Codable, Sendable, CustomStringConvertible {
    public var bpm: Double
    public var beatUnit: NoteValue
    public var text: String?

    public init(bpm: Double, beatUnit: NoteValue = .quarter, text: String? = nil) {
        self.bpm = max(10, min(400, bpm))
        self.beatUnit = beatUnit
        self.text = text
    }

    /// Seconds a whole note lasts at this tempo; every note's length scales from it.
    public var secondsPerWholeNote: Double { 60.0 / bpm / beatUnit.value.double }

    public func seconds(for value: Fraction) -> Double { value.double * secondsPerWholeNote }

    /// Quarter-note BPM, whatever the beat unit (♩. = 60 → ♩ = 90).
    public var quarterBPM: Double { bpm * beatUnit.quarters }

    /// The conventional marking for this speed, when no text is given.
    public var marking: TempoMarking { TempoMarking.closest(toQuarterBPM: quarterBPM) }

    public var description: String { "\(text.map { $0 + " " } ?? "")\(beatUnit.kind.name) = \(Int(bpm.rounded()))" }

    public static let `default` = Tempo(bpm: 80)
}

/// The standard Italian tempo terms with their customary metronome ranges (quarter-note BPM). Ranges overlap
/// and vary by tradition; these follow the common modern metronome markings.
public enum TempoMarking: String, CaseIterable, Sendable {
    case grave = "Grave"
    case largo = "Largo"
    case lento = "Lento"
    case larghetto = "Larghetto"
    case adagio = "Adagio"
    case andante = "Andante"
    case andantino = "Andantino"
    case moderato = "Moderato"
    case allegretto = "Allegretto"
    case allegro = "Allegro"
    case vivace = "Vivace"
    case presto = "Presto"
    case prestissimo = "Prestissimo"

    public var range: ClosedRange<Double> {
        switch self {
        case .grave: 25...45
        case .largo: 40...60
        case .lento: 45...60
        case .larghetto: 60...66
        case .adagio: 66...76
        case .andante: 76...108
        case .andantino: 80...108
        case .moderato: 108...120
        case .allegretto: 112...120
        case .allegro: 120...156
        case .vivace: 156...176
        case .presto: 168...200
        case .prestissimo: 200...240
        }
    }

    public var typicalBPM: Double { (range.lowerBound + range.upperBound) / 2 }

    /// The marking whose range centre is nearest (primary terms only, so 100 reads "Andante", not "Andantino").
    public static func closest(toQuarterBPM bpm: Double) -> TempoMarking {
        let primary: [TempoMarking] = [.grave, .largo, .adagio, .andante, .moderato, .allegro, .vivace, .presto, .prestissimo]
        return primary.min { abs($0.typicalBPM - bpm) < abs($1.typicalBPM - bpm) } ?? .moderato
    }

    /// Finds a marking inside free text ("Allegro ma non troppo" → allegro), for scores that give words but no BPM.
    public static func parse(_ text: String) -> TempoMarking? {
        let lower = text.lowercased()
        // Longer names first so "Allegretto" doesn't match "Allegro", nor "Andantino" "Andante".
        return allCases.sorted { $0.rawValue.count > $1.rawValue.count }.first { lower.contains($0.rawValue.lowercased()) }
    }
}
