import Foundation

/// Which accidentals are printed, by common-practice rules: the key signature applies to every octave;
/// an accidental lasts until the barline for that letter in that octave; a later note that goes back
/// needs a natural (or the key's sign); a note tied over from the previous one isn't re-marked.
public enum AccidentalRules {
    /// note id → (pitch index → accidental to print).
    public static func displayed(in measure: Measure, key: KeySignature,
                                 tiedFromPrevious: Set<UUID> = []) -> [UUID: [Int: Accidental]] {
        var current: [Int: Int] = [:]  // diatonic index → alteration in force
        var out: [UUID: [Int: Accidental]] = [:]
        var previous: NoteEvent?
        for note in measure.notes {
            defer { previous = note }
            guard !note.isRest else { continue }
            let tied = tiedFromPrevious.contains(note.id) || (previous?.tieToNext == true)
            for (i, p) in note.pitches.enumerated() {
                let inForce = current[p.diatonic] ?? key.alter(for: p.step)
                let tiedSame = tied && (previous?.pitches.contains(p) ?? tiedFromPrevious.contains(note.id))
                if (p.alter != inForce && !tiedSame) || note.forcedAccidentals.contains(i) {
                    out[note.id, default: [:]][i] = Accidental(rawValue: p.alter) ?? .natural
                }
                current[p.diatonic] = p.alter
            }
        }
        return out
    }

    /// Ids of notes tied over from the previous measure's last note, per measure index.
    public static func tiedAcrossBarlines(_ part: Part) -> [Int: Set<UUID>] {
        var out: [Int: Set<UUID>] = [:]
        for i in part.measures.indices.dropFirst() {
            if let last = part.measures[i - 1].notes.last, last.tieToNext, let first = part.measures[i].notes.first {
                out[i] = [first.id]
            }
        }
        return out
    }
}
