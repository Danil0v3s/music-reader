import Foundation

/// Monophonic pitch detection with the YIN algorithm (de Cheveigné & Kawahara, 2002). It handles the
/// cello's strong, harmonic-rich low register, where plain autocorrelation or an FFT peak often jumps
/// an octave.
public struct PitchDetector: Sendable {
    public struct Reading: Hashable, Sendable {
        public let frequency: Double
        /// 0…1: how periodic the signal is (1 - YIN's aperiodicity). Below ~0.85 is noise or a bow change.
        public let confidence: Double
        /// RMS level of the buffer, to ignore silence.
        public let level: Double

        public init(frequency: Double, confidence: Double, level: Double) {
            self.frequency = frequency
            self.confidence = confidence
            self.level = level
        }
    }

    public let sampleRate: Double
    public let minFrequency: Double
    public let maxFrequency: Double
    public let threshold: Double
    public let minLevel: Double

    /// Defaults cover the cello (C2 ≈ 65 Hz up to the highest thumb-position notes) with headroom.
    public init(sampleRate: Double, minFrequency: Double = 55, maxFrequency: Double = 1600, threshold: Double = 0.12, minLevel: Double = 0.01) {
        self.sampleRate = sampleRate
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.threshold = threshold
        self.minLevel = minLevel
    }

    /// Samples needed for the lowest frequency (two periods). 2048 at 44.1 kHz reaches ~43 Hz.
    public var preferredBufferSize: Int {
        var n = 1024
        while Double(n) < 2.2 * sampleRate / minFrequency { n *= 2 }
        return n
    }

    public func detect(_ samples: [Float]) -> Reading? {
        let n = samples.count
        guard n >= 64 else { return nil }
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let level = Double(sqrt(sumSquares / Float(n)))
        guard level >= minLevel else { return nil }

        let maxTau = min(n / 2, Int(sampleRate / minFrequency))
        let minTau = max(2, Int(sampleRate / maxFrequency))
        guard maxTau > minTau + 2 else { return nil }
        let w = n - maxTau

        // 1. Difference function d(τ) = Σ (x[j] - x[j+τ])².
        var d = [Float](repeating: 0, count: maxTau + 1)
        samples.withUnsafeBufferPointer { x in
            for tau in 1...maxTau {
                var sum: Float = 0
                for j in 0..<w {
                    let diff = x[j] - x[j + tau]
                    sum += diff * diff
                }
                d[tau] = sum
            }
        }
        // 2. Cumulative mean normalised difference d'(τ).
        var cmnd = [Float](repeating: 1, count: maxTau + 1)
        var running: Float = 0
        for tau in 1...maxTau {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }
        // 3. First dip under the threshold, then walk to its local minimum; else the global minimum.
        var tauEstimate = -1
        var tau = minTau
        while tau <= maxTau {
            if cmnd[tau] < Float(threshold) {
                while tau + 1 <= maxTau, cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                tauEstimate = tau
                break
            }
            tau += 1
        }
        if tauEstimate < 0 {
            guard let best = (minTau...maxTau).min(by: { cmnd[$0] < cmnd[$1] }), cmnd[best] < 0.35 else { return nil }
            tauEstimate = best
        }
        // 4. Parabolic interpolation for sub-sample accuracy (a cent is ~0.06% of the period).
        var refined = Double(tauEstimate)
        if tauEstimate > 1, tauEstimate < maxTau {
            let s0 = Double(cmnd[tauEstimate - 1]), s1 = Double(cmnd[tauEstimate]), s2 = Double(cmnd[tauEstimate + 1])
            let denom = 2 * (2 * s1 - s2 - s0)
            if abs(denom) > 1e-12 { refined += (s2 - s0) / denom }
        }
        let frequency = sampleRate / refined
        guard frequency >= minFrequency, frequency <= maxFrequency else { return nil }
        return Reading(frequency: frequency, confidence: max(0, 1 - Double(cmnd[tauEstimate])), level: level)
    }
}
