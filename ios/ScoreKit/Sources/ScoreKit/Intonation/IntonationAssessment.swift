import Foundation

/// How in tune one note was, from the microphone readings taken while it should have been sounding.
public struct NoteIntonation: Hashable, Sendable {
    public enum Rating: String, Sendable {
        /// Within ±10 cents: about as close as a trained ear can tell apart.
        case inTune
        /// 10–25 cents: audibly off against a piano or open string.
        case close
        /// More than 25 cents: clearly out of tune.
        case off
        /// Nearer another note than the written one (> 50 cents).
        case wrongNote
        /// No usable pitch was heard.
        case missed
    }

    public let noteId: UUID
    public let target: Pitch
    /// Median deviation from the target (robust to the bow's attack and noise).
    public let cents: Double
    /// Spread of the readings (standard deviation, cents): high means a wobbly or sliding pitch.
    public let spread: Double
    public let samples: Int
    /// The pitch actually heard, when it wasn't the written one.
    public let heard: Pitch?
    public let rating: Rating

    public var direction: String {
        switch rating {
        case .missed: return "not heard"
        case .wrongNote: return "played \(heard?.description ?? "another note")"
        default: return abs(cents) < 3 ? "centred" : cents > 0 ? "\(Int(cents.rounded())) ¢ sharp" : "\(Int((-cents).rounded())) ¢ flat"
        }
    }
}

/// Collects pitch readings per note and turns them into ratings, during a practice run.
public struct IntonationAssessment: Sendable {
    public struct Thresholds: Hashable, Codable, Sendable {
        public var inTune: Double
        public var close: Double
        public init(inTune: Double = 10, close: Double = 25) { self.inTune = inTune; self.close = close }
    }

    public let tuning: Tuning
    public let key: KeySignature
    public var thresholds: Thresholds
    private var readings: [UUID: [Double]] = [:]   // note id → heard frequencies
    private var targets: [UUID: (Pitch, Double)] = [:]

    public init(tuning: Tuning, key: KeySignature, thresholds: Thresholds = Thresholds()) {
        self.tuning = tuning
        self.key = key
        self.thresholds = thresholds
    }

    /// Records a reading for a note. For a double stop, the reading is compared with the nearest of its pitches.
    public mutating func add(_ frequency: Double, for note: ScheduledNote) {
        guard !note.pitches.isEmpty else { return }
        let (i, _) = note.frequencies.enumerated().min { abs(Tuning.cents(frequency, relativeTo: $0.1)) < abs(Tuning.cents(frequency, relativeTo: $1.1)) }!
        targets[note.noteId] = (note.pitches[i], note.frequencies[i])
        readings[note.noteId, default: []].append(frequency)
    }

    public mutating func expect(_ note: ScheduledNote) {
        guard let p = note.pitches.first, targets[note.noteId] == nil else { return }
        targets[note.noteId] = (p, note.frequencies[0])
    }

    public func result(for id: UUID) -> NoteIntonation? {
        guard let (pitch, target) = targets[id] else { return nil }
        let heard = readings[id] ?? []
        // Drop the first readings: the bow's attack scrapes before the string speaks.
        let settled = heard.count > 4 ? Array(heard.dropFirst(heard.count / 5)) : heard
        guard !settled.isEmpty else {
            return NoteIntonation(noteId: id, target: pitch, cents: 0, spread: 0, samples: 0, heard: nil, rating: .missed)
        }
        let cents = settled.map { Tuning.cents($0, relativeTo: target) }.sorted()
        let median = cents[cents.count / 2]
        let mean = cents.reduce(0, +) / Double(cents.count)
        let spread = sqrt(cents.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(cents.count))
        let rating: NoteIntonation.Rating
        var heardPitch: Pitch?
        if abs(median) > 50 {
            rating = .wrongNote
            let f = target * pow(2, median / 1200)
            heardPitch = tuning.nearest(to: f, in: key).pitch
        } else if abs(median) <= thresholds.inTune {
            rating = .inTune
        } else if abs(median) <= thresholds.close {
            rating = .close
        } else {
            rating = .off
        }
        return NoteIntonation(noteId: id, target: pitch, cents: median, spread: spread, samples: settled.count, heard: heardPitch, rating: rating)
    }

    public var results: [NoteIntonation] { targets.keys.compactMap(result(for:)) }

    /// Share of assessed notes rated in tune, 0…1.
    public var score: Double {
        let r = results.filter { $0.rating != .missed }
        guard !r.isEmpty else { return 0 }
        return Double(r.filter { $0.rating == .inTune }.count) / Double(r.count)
    }

    /// Average signed deviation of the assessed notes: a consistent lean sharp or flat (often the hand frame).
    public var tendency: Double {
        let r = results.filter { $0.rating != .missed && $0.rating != .wrongNote }
        guard !r.isEmpty else { return 0 }
        return r.map(\.cents).reduce(0, +) / Double(r.count)
    }
}
