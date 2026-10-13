import Foundation

/// Renders a schedule to mono PCM: a bowed-string tone (a band-limited sawtooth-like spectrum with a
/// soft bow attack and delayed vibrato) and, separately, metronome clicks. Rendering the whole piece up
/// front keeps playback sample-accurate and the audio thread free of logic.
public struct Synth: Sendable {
    public let sampleRate: Double

    public init(sampleRate: Double = 44100) { self.sampleRate = sampleRate }

    /// Harmonic amplitudes of a bowed string, roughly 1/n with the cello's body resonance lifting 2–4.
    static let spectrum: [Float] = [1, 0.8, 0.62, 0.5, 0.36, 0.28, 0.22, 0.17, 0.13, 0.1, 0.08, 0.06, 0.05, 0.04]
    static let tableSize = 2048

    /// Single-cycle tables with fewer harmonics for higher notes, so nothing aliases above Nyquist.
    private static let tables: [(harmonics: Int, table: [Float])] = {
        func make(_ harmonics: Int) -> [Float] {
            var t = [Float](repeating: 0, count: tableSize + 1)
            for i in 0...tableSize {
                let phase = Double(i) / Double(tableSize) * 2 * .pi
                var v = 0.0
                for h in 0..<harmonics { v += Double(spectrum[h]) * sin(phase * Double(h + 1)) }
                t[i] = Float(v)
            }
            let peak = t.map(abs).max() ?? 1
            return t.map { $0 / peak }
        }
        return [14, 8, 4, 2, 1].map { ($0, make($0)) }
    }()

    /// - Parameter leadIn: seconds of silence before the music (a count-in).
    public func renderMusic(_ schedule: PlaybackSchedule, from start: Double = 0, leadIn: Double = 0) -> [Float] {
        let total = Int((schedule.duration - start + leadIn + 0.6) * sampleRate)
        var out = [Float](repeating: 0, count: max(total, 1))
        let attack = 0.035, release = 0.09
        for note in schedule.notes where note.sounding > 0 && !note.isRest && note.end > start {
            let begin = note.start - start + leadIn
            guard begin >= -0.001 else { continue }
            let amp = Float(pow(note.velocity, 1.4)) * 0.32 / Float(sqrt(Double(note.frequencies.count)))
            for f in note.frequencies {
                let chosen = table(for: f)
                let first = Int(begin * sampleRate)
                let length = Int((note.sounding + release) * sampleRate)
                var phase = 0.0
                for i in 0..<length {
                    let idx = first + i
                    guard idx >= 0, idx < out.count else { break }
                    let t = Double(i) / sampleRate
                    // Vibrato fades in after the bow settles.
                    let vibratoDepth = note.isGrace ? 0 : min(1, max(0, (t - 0.28) / 0.4)) * 0.0058  // ≈ ±10 cents
                    let freq = f * (1 + vibratoDepth * sin(2 * .pi * 5.3 * t))
                    phase += freq / sampleRate
                    phase -= floor(phase)
                    let pos = phase * Double(Self.tableSize)
                    let j = Int(pos)
                    let frac = Float(pos - Double(j))
                    let sample = chosen[j] + (chosen[j + 1] - chosen[j]) * frac
                    var env: Double
                    if t < attack { env = t / attack }
                    else if t < note.sounding { env = 1 - 0.15 * min(1, (t - attack) / 0.15) }
                    else { env = 0.85 * max(0, 1 - (t - note.sounding) / release) }
                    out[idx] += sample * amp * Float(env)
                }
            }
        }
        // Gentle saturation keeps loud chords from clipping.
        for i in out.indices { out[i] = tanhf(out[i] * 1.2) / 1.2 }
        return out
    }

    /// The richest table whose top harmonic (with vibrato headroom) stays under Nyquist.
    private func table(for frequency: Double) -> [Float] {
        (Self.tables.first { frequency * 1.01 * Double($0.harmonics) < sampleRate * 0.45 } ?? Self.tables.last!).table
    }

    /// Clicks on every beat (accented downbeats) plus `countIn` beats before the music.
    public func renderClicks(_ schedule: PlaybackSchedule, from start: Double = 0, countIn: [Double] = []) -> [Float] {
        let leadIn = countIn.first.map { -$0 } ?? 0
        let total = Int((schedule.duration - start + leadIn + 0.6) * sampleRate)
        var out = [Float](repeating: 0, count: max(total, 1))
        func click(at time: Double, accent: Bool) {
            let first = Int(time * sampleRate)
            let freq = accent ? 1760.0 : 1320.0
            let amp: Float = accent ? 0.55 : 0.38
            for i in 0..<Int(0.03 * sampleRate) {
                let idx = first + i
                guard idx >= 0, idx < out.count else { break }
                let t = Double(i) / sampleRate
                out[idx] += Float(sin(2 * .pi * freq * t) * exp(-t * 160)) * amp
            }
        }
        for (i, t) in countIn.enumerated() { click(at: t + leadIn, accent: i == 0) }
        for b in schedule.beats where b.time >= start - 0.001 { click(at: b.time - start + leadIn, accent: b.isDownbeat) }
        return out
    }

    /// A sustained reference tone (the tuner's drone), about a second long and loopable: it holds a whole
    /// number of cycles, so the loop point is seamless and the pitch is exact.
    public func renderDrone(frequency: Double) -> [Float] {
        let cycles = max(1, frequency.rounded())
        let count = Int((cycles * sampleRate / frequency).rounded())
        let table = table(for: frequency)
        return (0..<count).map { i in
            let phase = (Double(i) * frequency / sampleRate).truncatingRemainder(dividingBy: 1)
            let pos = phase * Double(Self.tableSize)
            let j = Int(pos)
            return (table[j] + (table[j + 1] - table[j]) * Float(pos - Double(j))) * 0.25
        }
    }
}
