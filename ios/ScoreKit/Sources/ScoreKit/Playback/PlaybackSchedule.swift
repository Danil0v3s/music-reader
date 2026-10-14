import Foundation

/// One sounding event on the timeline, in seconds from the start.
public struct ScheduledNote: Hashable, Sendable {
    public let noteId: UUID
    /// Where the note sits in the score (for following along).
    public let path: ItemPath
    public let start: Double
    /// Written length on the timeline (until the next event).
    public let length: Double
    /// How long it actually sounds (articulation shortens, ties lengthen). 0 for the continuation of a tie.
    public let sounding: Double
    public let pitches: [Pitch]
    /// Target frequencies under the chosen tuning, one per pitch.
    public let frequencies: [Double]
    /// 0…1.
    public let velocity: Double
    public let isGrace: Bool
    /// Slurred from the previous note: same bow stroke, so no new attack.
    public var legato: Bool = false

    public var end: Double { start + length }
    public var isRest: Bool { pitches.isEmpty }
}

public struct Beat: Hashable, Sendable {
    public let time: Double
    public let isDownbeat: Bool
    public let measure: Int
}

/// The score unrolled into time: repeats expanded, tempo changes applied, ties merged. What the synth
/// plays, what the metronome clicks, and what intonation practice compares the microphone against.
public struct PlaybackSchedule: Sendable {
    public let notes: [ScheduledNote]
    public let beats: [Beat]
    public let duration: Double
    /// Start time of each played measure (repeats make some measures appear twice).
    public let measureStarts: [(measure: Int, time: Double)]

    /// The event sounding at `time`, if any (rests included).
    public func note(at time: Double) -> ScheduledNote? {
        var lo = 0, hi = notes.count - 1, found: ScheduledNote?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if notes[mid].start <= time { found = notes[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let f = found, time < f.end else { return nil }
        return f
    }

    /// Where playback should start to begin at a measure (its first occurrence).
    public func time(ofMeasure index: Int) -> Double {
        measureStarts.first { $0.measure >= index }?.time ?? 0
    }

    /// - Parameters:
    ///   - tempoScale: practice speed, 0.5 = half tempo.
    ///   - from: measure to start at (earlier measures are skipped, but their tempo and dynamics still apply).
    ///   - through: last measure to play (inclusive); notes held past it are cut at its barline.
    public static func build(part: Part, tuning: Tuning = .standard, tempoScale: Double = 1, from startMeasure: Int = 0,
                             through endMeasure: Int? = nil, expandRepeats: Bool = true) -> PlaybackSchedule {
        let attrs = part.resolvedAttributes
        let order = expandRepeats ? playOrder(part) : Array(part.measures.indices)

        var notes: [ScheduledNote] = []
        var beats: [Beat] = []
        var starts: [(Int, Double)] = []
        var t = 0.0
        var tempo = attrs.first?.tempo ?? .default
        var velocity = Dynamic.mf.velocity
        var wedge: Wedge?
        // A tie's first note absorbs the following notes' lengths.
        var tieHead: Int?
        // Inside a slur (after its first note): the bow keeps moving.
        var inSlur = false

        for mi in order {
            let measure = part.measures[mi]
            let a = attrs[mi]
            if let mt = measure.attributes?.tempo { tempo = mt }
            let counting = mi >= startMeasure && mi <= (endMeasure ?? .max)
            let measureStart = t
            if counting { starts.append((mi, t)) }

            for (ii, item) in measure.items.enumerated() {
                switch item {
                case .tempo(let newTempo): tempo = newTempo
                case .dynamic(let d): if !d.isAccent { velocity = d.velocity; wedge = nil }
                case .wedge(let w): wedge = w == .stop ? nil : w
                case .note(let n):
                    let spw = tempo.secondsPerWholeNote / tempoScale
                    if n.isGrace {
                        guard counting, !n.isRest else { continue }
                        notes.append(ScheduledNote(noteId: n.id, path: ItemPath(measure: mi, item: ii), start: t, length: 0.07, sounding: 0.07,
                                                   pitches: n.pitches, frequencies: n.pitches.map { tuning.frequency(of: $0, in: a.key) },
                                                   velocity: velocity * 0.8, isGrace: true))
                        continue
                    }
                    let value = n.isMeasureRest ? a.time.measureDuration : n.duration.value
                    var length = value.double * spw
                    if n.articulations.contains(.fermata) { length *= 1.75 }
                    if counting {
                        var v = velocity
                        for art in n.articulations { v += art.velocityBoost }
                        if let accent = measure.items[..<ii].reversed().prefix(while: { $0.note == nil }).compactMap({ item -> Dynamic? in
                            if case .dynamic(let d) = item, d.isAccent { d } else { nil }
                        }).first { v = max(v, accent.velocity) }
                        let slurred = inSlur || n.slurStart || n.slurStop
                        let factor = n.articulations.map(\.lengthFactor).min() ?? (slurred ? 1.0 : 0.92)
                        let continuesTie = tieHead.map { notes[$0].pitches == n.pitches } ?? false
                        if continuesTie, let head = tieHead {
                            // Extend the head; this note only marks the timeline.
                            let h = notes[head]
                            notes[head] = ScheduledNote(noteId: h.noteId, path: h.path, start: h.start, length: h.length, sounding: t + length * factor - h.start,
                                                        pitches: h.pitches, frequencies: h.frequencies, velocity: h.velocity, isGrace: false)
                        }
                        notes.append(ScheduledNote(noteId: n.id, path: ItemPath(measure: mi, item: ii), start: t, length: length,
                                                   sounding: continuesTie ? 0 : length * (n.tieToNext ? 1 : factor),
                                                   pitches: n.pitches, frequencies: n.pitches.map { tuning.frequency(of: $0, in: a.key) },
                                                   velocity: min(1, v), isGrace: false))
                        notes[notes.count - 1].legato = inSlur && !n.isRest
                        if n.slurStart { inSlur = true }
                        if n.slurStop { inSlur = false }
                        if n.tieToNext, !n.isRest { if !continuesTie { tieHead = notes.count - 1 } } else { tieHead = nil }
                        // Hairpins move the level note by note.
                        if wedge == .crescendo { velocity = min(1, velocity + 0.03) }
                        if wedge == .diminuendo { velocity = max(0.1, velocity - 0.03) }
                    }
                    t = counting ? t + length : t
                default: break
                }
            }

            // Metronome beats across what the measure actually holds (a pickup counts back from the barline).
            if counting {
                let spw = tempo.secondsPerWholeNote / tempoScale
                let filled = measure.notes.contains { $0.isMeasureRest } ? a.time.measureDuration : measure.filled
                let beat = a.time.beatDuration
                let full = a.time.measureDuration
                let skipped = max(Fraction.zero, full - filled)
                var pos = Fraction.zero
                var index = 0
                while pos < full {
                    if pos >= skipped || filled == .zero {
                        beats.append(Beat(time: measureStart + (pos - skipped).double * spw, isDownbeat: index == 0, measure: mi))
                    }
                    pos += beat
                    index += 1
                }
            }
        }
        if endMeasure != nil {
            notes = notes.map { n in
                guard n.start + n.sounding > t else { return n }
                var cut = ScheduledNote(noteId: n.noteId, path: n.path, start: n.start, length: n.length, sounding: max(0, t - n.start),
                                        pitches: n.pitches, frequencies: n.frequencies, velocity: n.velocity, isGrace: n.isGrace)
                cut.legato = n.legato
                return cut
            }
        }
        return PlaybackSchedule(notes: notes, beats: beats.filter { $0.time >= 0 }, duration: t, measureStarts: starts)
    }

    /// Bars `range` on their own, for practising a passage on repeat: written order (no repeat jumps), the
    /// tempo and dynamics in force where it starts, and its timeline starting at 0.
    public static func loop(part: Part, measures range: ClosedRange<Int>, tuning: Tuning = .standard, tempoScale: Double = 1) -> PlaybackSchedule {
        build(part: part, tuning: tuning, tempoScale: tempoScale, from: range.lowerBound, through: range.upperBound, expandRepeats: false)
    }

    /// Measure indices in performance order: a backward repeat jumps once to the last forward repeat (or the start).
    static func playOrder(_ part: Part) -> [Int] {
        var order: [Int] = []
        var i = 0
        var repeatStart = 0
        var taken = Set<Int>()
        while i < part.measures.count {
            let m = part.measures[i]
            if m.barline == .repeatStart || m.barline == .repeatBoth { repeatStart = i }
            order.append(i)
            if (m.barline == .repeatEnd || m.barline == .repeatBoth), !taken.contains(i) {
                taken.insert(i)
                i = repeatStart
                continue
            }
            if m.barline == .repeatEnd || m.barline == .repeatBoth { repeatStart = i + 1 }
            i += 1
        }
        return order
    }
}
