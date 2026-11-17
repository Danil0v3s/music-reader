import AVFoundation
import Foundation

/// Describes a sampled instrument: one recording per note, string and dynamic, with loop points for
/// sustaining past the recording. Written by tools/SampleBuilder, read by the app (shared/sounds/<instrument>).
public struct SampleManifest: Codable, Sendable {
    public struct Note: Codable, Sendable, Hashable {
        public var file: String
        /// The written note (MIDI number).
        public var midi: Int
        /// 1 = A string … 4 = C string.
        public var string: Int
        /// "pp", "mf" or "ff".
        public var dynamic: String
        /// How far the recording sits from equal temperament at A = 440, in cents (measured).
        public var cents: Double
        /// Loop region in frames, inside the stable sustain.
        public var loopStart: Int
        public var loopEnd: Int
        public var frames: Int
        /// RMS of the sustain, for balancing.
        public var rms: Float

        public init(file: String, midi: Int, string: Int, dynamic: String, cents: Double, loopStart: Int, loopEnd: Int, frames: Int, rms: Float) {
            self.file = file
            self.midi = midi
            self.string = string
            self.dynamic = dynamic
            self.cents = cents
            self.loopStart = loopStart
            self.loopEnd = loopEnd
            self.frames = frames
            self.rms = rms
        }

        /// The recording's actual pitch.
        public var frequency: Double { 440 * pow(2, (Double(midi - 69) + cents / 100) / 12) }
    }

    public var instrument: String
    public var source: String
    public var license: String
    public var sampleRate: Double
    public var notes: [Note]

    public init(instrument: String, source: String, license: String, sampleRate: Double, notes: [Note]) {
        self.instrument = instrument
        self.source = source
        self.license = license
        self.sampleRate = sampleRate
        self.notes = notes
    }
}

/// A sampled instrument loaded into memory.
public final class SampleBank: @unchecked Sendable {
    public let manifest: SampleManifest
    let audio: [Int: [Float]]   // index into manifest.notes → samples

    public init(manifest: SampleManifest, audio: [Int: [Float]]) {
        self.manifest = manifest
        self.audio = audio
    }

    /// Loads `manifest.json` and every note file from a folder (AAC, AIFF or WAV).
    public static func load(from directory: URL) throws -> SampleBank {
        var manifest = try JSONDecoder().decode(SampleManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        var audio: [Int: [Float]] = [:]
        for (i, note) in manifest.notes.enumerated() {
            let samples = try readMono(directory.appendingPathComponent(note.file))
            manifest.notes[i].loopStart = alignedLoopStart(samples, loopStart: note.loopStart, loopEnd: note.loopEnd, sampleRate: manifest.sampleRate)
            audio[i] = levelled(samples, loopStart: manifest.notes[i].loopStart, loopEnd: note.loopEnd, sampleRate: manifest.sampleRate)
        }
        return SampleBank(manifest: manifest, audio: audio)
    }

    /// The loop start moved (by up to 20 ms) to where the waveform best matches the loop's end, so the
    /// crossfade at the jump back joins two stretches in phase instead of partly cancelling.
    static func alignedLoopStart(_ samples: [Float], loopStart: Int, loopEnd: Int, sampleRate: Double) -> Int {
        let span = Int(0.03 * sampleRate), reach = Int(0.02 * sampleRate)
        guard loopEnd < samples.count, loopStart - span - reach >= 0, loopEnd - span > loopStart + reach else { return loopStart }
        // The end of the loop, which the jump leaves, against the stretch just before each candidate start.
        let endSlice = Array(samples[(loopEnd - span)..<loopEnd])
        let endEnergy = endSlice.reduce(0) { $0 + $1 * $1 }
        var best = loopStart, bestScore = -Float.infinity
        for start in stride(from: loopStart - reach, through: loopStart + reach, by: 4) {
            var dot: Float = 0, energy: Float = 0
            for k in 0..<span {
                let v = samples[start - span + k]
                dot += v * endSlice[k]; energy += v * v
            }
            let score = dot / max(1e-9, (energy * endEnergy).squareRoot())
            if score > bestScore { bestScore = score; best = start }
        }
        return best
    }

    /// Evens out each recorded stroke after its bite. The players' strokes dip and swell in their first half
    /// second (42 of the 92 recordings dip more than 3 dB) and swell again inside the sustain loop, so notes
    /// sounded like a second stroke: quarters (above all slurred ones, which start 0.11 s in, inside the dip)
    /// and long notes when the loop jumped back. From `attack` on, the level follows the sustain level (where
    /// the loop begins); the first `attack` seconds, the bow's bite, are left as recorded.
    static func levelled(_ samples: [Float], loopStart: Int, loopEnd: Int, sampleRate: Double, attack: Double = 0.05) -> [Float] {
        let window = Int(0.04 * sampleRate)
        let start = Int(attack * sampleRate)
        guard start < loopStart, loopEnd < samples.count, loopEnd - loopStart > 4 * window else { return samples }
        func rms(around c: Int) -> Float {
            let lo = max(0, c - window / 2), hi = min(samples.count, c + window / 2)
            var sum: Float = 0
            for i in lo..<hi { sum += samples[i] * samples[i] }
            return sqrt(sum / Float(max(1, hi - lo)))
        }
        let target: Float = {
            let a = loopStart, b = min(samples.count, loopStart + Int(0.1 * sampleRate))
            var sum: Float = 0
            for i in a..<b { sum += samples[i] * samples[i] }
            return sqrt(sum / Float(max(1, b - a)))
        }()
        guard target > 1e-4 else { return samples }
        // Gain on a coarse grid (every 10 ms), smoothed over 50 ms and interpolated: it follows the swell
        // without touching the waveform's detail or fluttering. At most +12 / -6 dB.
        let hop = Int(0.01 * sampleRate)
        var raw: [Float] = []
        var c = start
        while c <= loopEnd + hop {
            raw.append(min(4, max(0.5, target / max(rms(around: c), 1e-4))))
            c += hop
        }
        let gains = raw.indices.map { k -> Float in
            let lo = max(0, k - 2), hi = min(raw.count - 1, k + 2)
            return raw[lo...hi].reduce(0, +) / Float(hi - lo + 1)
        }
        // The correction comes in over 40 ms after the bite, so the attack joins the levelled body smoothly.
        let ramp = Float(0.04 * sampleRate)
        var out = samples
        for i in start..<min(samples.count, loopEnd + hop) {
            let f = Float(i - start) / Float(hop)
            let k = min(gains.count - 2, Int(f))
            let g = gains[k] + (gains[k + 1] - gains[k]) * (f - Float(k))
            let r = min(1, Float(i - start) / ramp)
            out[i] *= 1 + (g - 1) * r
        }
        return out
    }

    public static func readMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
                                   channels: file.processingFormat.channelCount, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength), channels = Int(format.channelCount)
        guard let data = buffer.floatChannelData else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: n)) }
        return (0..<n).map { i in (0..<channels).reduce(Float(0)) { $0 + data[$1][i] } / Float(channels) }
    }

    /// The best recording for a pitch: the same note on the preferred string and dynamic, else the closest
    /// note (fewest semitones of re-pitching), then the nearest dynamic.
    func choose(midi: Int, string preferred: Int?, dynamic: String) -> Int? {
        let order = ["pp", "mf", "ff"]
        let wanted = order.firstIndex(of: dynamic) ?? 1
        var best: (index: Int, cost: Int)?
        for (i, n) in manifest.notes.enumerated() where audio[i] != nil {
            let dynCost = abs((order.firstIndex(of: n.dynamic) ?? 1) - wanted)
            let stringCost = preferred.map { n.string == $0 ? 0 : 1 } ?? 0
            let cost = abs(n.midi - midi) * 100 + dynCost * 10 + stringCost
            if best == nil || cost < best!.cost { best = (i, cost) }
        }
        return best?.index
    }
}

extension Synth {
    /// Renders with recorded cello notes: each written note plays its own recording, nudged to the exact
    /// target frequency of the chosen tuning, looped to sustain. To sound played rather than triggered:
    /// slurred notes continue the bow (no new attack), vibrato blooms after the note speaks, softer dynamics
    /// are darker as well as quieter, and the string decays naturally when the bow stops.
    public func renderSampled(_ schedule: PlaybackSchedule, bank: SampleBank, from start: Double = 0, leadIn: Double = 0) -> [Float] {
        let total = Int((schedule.duration - start + leadIn + 1.0) * sampleRate)
        var out = [Float](repeating: 0, count: max(total, 1))
        // Long enough that the join in a sustained note can't be heard.
        let crossfade = Int(0.12 * bank.manifest.sampleRate)
        let releaseTime = 0.09          // the string's decay after the bow stops (time constant)
        let releaseLength = Int(0.45 * sampleRate)
        let legatoSkip = 0.11           // a slurred note starts past the recorded bow attack…
        let legatoFadeIn = 0.05         // …and fades in under the previous note's decay
        for note in schedule.notes where note.sounding > 0 && !note.isRest && note.end > start {
            let begin = note.start - start + leadIn
            guard begin >= -0.001 else { continue }
            let dynamic = note.velocity < 0.42 ? "pp" : note.velocity < 0.72 ? "mf" : "ff"
            let nominal: Double = dynamic == "pp" ? 0.32 : dynamic == "mf" ? 0.6 : 0.88
            let gain = Float(min(1.4, max(0.6, note.velocity / nominal))) / Float(sqrt(Double(note.pitches.count))) * 0.9
            // Bowing softer takes out high harmonics, not just level: a gentle low-pass that opens with the dynamic.
            let cutoff = 1500 + 7500 * pow(note.velocity, 2)
            let alpha = Float(1 - exp(-2 * Double.pi * cutoff / sampleRate))
            // Vibrato: a player lets it bloom after the note speaks; none on short or grace notes.
            let vibrato = !note.isGrace && note.sounding > 0.35
            for (pi, pitch) in note.pitches.enumerated() {
                let string = CelloString.natural(for: pitch)?.rawValue
                guard let index = bank.choose(midi: pitch.midi, string: string, dynamic: dynamic),
                      let src = bank.audio[index] else { continue }
                let info = bank.manifest.notes[index]
                let baseStep = note.frequencies[pi] / info.frequency * bank.manifest.sampleRate / sampleRate
                let loopStart = Double(info.loopStart), loopEnd = Double(info.loopEnd)
                let loopLength = loopEnd - loopStart
                let canLoop = loopLength > Double(crossfade * 2) && loopEnd < Double(src.count - 1)
                let first = Int(begin * sampleRate)
                let soundingFrames = Int(note.sounding * sampleRate)
                let length = soundingFrames + releaseLength
                var pos = note.legato ? min(legatoSkip * bank.manifest.sampleRate, loopStart) : 0
                var filtered: Float = 0
                let phase = Double(pi) * 0.7    // double-stop voices don't vibrate in lockstep
                for i in 0..<length {
                    let idx = first + i
                    guard idx >= 0, idx < out.count else { break }
                    if canLoop, pos >= loopEnd { pos -= loopLength }
                    guard pos < Double(src.count - 1) else { break }
                    var s = Self.read(src, pos)
                    // Approaching the loop end, fade into the matching point at the loop start.
                    // The two ends are levelled to the same loudness but only partly in phase: a straight
                    // crossfade dips in the middle and an equal-power one bulges, so this is halfway between.
                    if canLoop, pos > loopEnd - Double(crossfade) {
                        let b = Float((pos - (loopEnd - Double(crossfade))) / Double(crossfade)), a = 1 - b
                        s = (s * a + Self.read(src, pos - loopLength) * b) / pow(a * a + b * b, 0.25)
                    }
                    filtered += alpha * (s - filtered)
                    let t = Double(i) / sampleRate
                    var env: Float = 1
                    if note.legato, t < legatoFadeIn { env = Float(t / legatoFadeIn) }
                    if i >= soundingFrames { env *= Float(exp(-Double(i - soundingFrames) / sampleRate / releaseTime)) }
                    out[idx] += filtered * gain * env
                    var step = baseStep
                    if vibrato {
                        let depth = min(1, max(0, (t - 0.22) / 0.4)) * 0.0055      // up to about ±9.5 cents
                        step *= 1 + depth * sin(2 * .pi * 5.4 * t + phase)
                    }
                    pos += step
                }
            }
        }
        for i in out.indices { out[i] = tanhf(out[i] * 1.1) / 1.1 }
        return out
    }

    static func read(_ src: [Float], _ pos: Double) -> Float {
        let j = Int(pos)
        let f = Float(pos - Double(j))
        return src[j] + (src[min(j + 1, src.count - 1)] - src[j]) * f
    }
}
