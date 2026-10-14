import AVFoundation
import Foundation
import ScoreKit

// Turns the University of Iowa cello recordings (2012 set: one bowed note per file, per string,
// "Cello.arco.ff.sulG.A2.stereo.aif") into short looped samples plus shared/sounds/cello/manifest.json.
//
//   swift run -c release SampleBuilder <folder of unzipped .aif files> <output folder>
//
// Every note's pitch is checked against its file name with ScoreKit's PitchDetector and its tuning measured
// in cents (the app re-pitches to the exact target, so the measurement matters more than the take). Each is
// trimmed to start at the attack, kept for the attack plus a sustain, given loop points a whole number of
// cycles apart in the steady part, and written as AAC.
//
// (The 2001 set has three dynamics but is recorded as chromatic runs whose notes can't be separated reliably:
// bow changes split notes and the pitch drifts between strokes. The 2012 set is fortissimo only; the app
// scales it for softer dynamics.)

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: SampleBuilder <input folder> <output folder>")
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let keep = 2.6          // seconds kept per note (attack + sustain); longer notes loop
let fadeOut = 0.08
let letters = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
let strings = ["sulA": 1, "sulD": 2, "sulG": 3, "sulC": 4]

/// "Gb2" → 42.
func midi(_ s: String) -> Int? {
    guard let letter = s.first.flatMap({ letters[String($0)] }) else { return nil }
    var rest = s.dropFirst()
    var alter = 0
    if rest.first == "b" { alter = -1; rest = rest.dropFirst() } else if rest.first == "#" { alter = 1; rest = rest.dropFirst() }
    guard let octave = Int(rest) else { return nil }
    return (octave + 1) * 12 + letter + alter
}

/// Where the note starts: the first 10 ms frame within 40 dB of the loudest.
func onset(_ x: [Float], sr: Double) -> Int {
    let hop = Int(sr * 0.01)
    let rms = stride(from: 0, to: x.count, by: hop).map { i -> Float in
        let e = x[i..<min(i + hop, x.count)]
        return sqrt(e.reduce(0) { $0 + $1 * $1 } / Float(max(e.count, 1)))
    }
    let threshold = (rms.max() ?? 0) * 0.01
    let first = rms.firstIndex { $0 >= threshold } ?? 0
    return max(0, first * hop - Int(0.01 * sr))
}

/// The median pitch of the steady middle of the note, as a fractional MIDI number.
func measure(_ x: ArraySlice<Float>, sr: Double) -> Double? {
    let detector = PitchDetector(sampleRate: sr, minFrequency: 55, maxFrequency: 1100, minLevel: 0.002)
    let n = detector.preferredBufferSize
    let a = x.startIndex + x.count / 4, b = x.startIndex + x.count * 3 / 4 - n
    guard b > a else { return nil }
    var readings: [Double] = []
    for i in stride(from: a, to: b, by: max(1, (b - a) / 15)) {
        if let r = detector.detect(Array(x[i..<i + n])), r.confidence > 0.85 { readings.append(69 + 12 * log2(r.frequency / 440)) }
    }
    guard readings.count >= 3 else { return nil }
    readings.sort()
    return readings[readings.count / 2]
}

/// A rising zero crossing near `frame`.
func zeroCrossing(near frame: Int, in x: [Float]) -> Int {
    for d in 0..<2000 {
        for i in [frame + d, frame - d] where i > 0 && i < x.count && x[i - 1] < 0 && x[i] >= 0 { return i }
    }
    return frame
}

func writeAAC(_ samples: [Float], sr: Double, to url: URL) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
    .filter { $0.lastPathComponent.hasPrefix("Cello.arco.") && ["aif", "aiff"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

struct Cut { var note: SampleManifest.Note; var samples: [Float] }
var cuts: [Cut] = []
var problems: [String] = []

for url in files {
    // Cello.arco.ff.sulG.A2.stereo.aif
    let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".").map(String.init)
    guard parts.count >= 5, let string = strings[parts[3]], let written = midi(parts[4]) else {
        problems.append("\(url.lastPathComponent): unexpected name"); continue
    }
    let dynamic = parts[2]
    let x = try SampleBank.readMono(url)
    let sr = try AVAudioFile(forReading: url).fileFormat.sampleRate
    let start = onset(x, sr: sr)
    let end = min(x.count, start + Int(keep * sr))
    guard end - start > Int(0.8 * sr), let measured = measure(x[start..<end], sr: sr) else {
        problems.append("\(url.lastPathComponent): too short or no steady pitch"); continue
    }
    let cents = (measured - Double(written)) * 100
    // Up to 3/4 of a semitone off still re-pitches naturally; further and the take is likely mislabelled.
    guard abs(cents) < 75 else {
        problems.append("\(url.lastPathComponent): named \(parts[4]) but sounds \(String(format: "%.2f", measured)) (skipped)"); continue
    }
    var s = Array(x[start..<end])
    if sr != 44100 { problems.append("\(url.lastPathComponent): \(sr) Hz (expected 44100)") }
    let fade = Int(fadeOut * sr)
    for i in 0..<min(fade, s.count) { s[s.count - 1 - i] *= Float(i) / Float(fade) }
    // Loop in the steady part, from ~40% to ~85% of the kept length, a whole number of cycles long.
    let period = sr / (440 * pow(2, (measured - 69) / 12))
    let ls = zeroCrossing(near: Int(Double(s.count) * 0.4), in: s)
    let cycles = max(1, Int((Double(s.count) * 0.85 - Double(ls)) / period))
    let le = zeroCrossing(near: ls + Int((Double(cycles) * period).rounded()), in: s)
    let sustain = s[ls..<le]
    let rms = sqrt(sustain.reduce(0) { $0 + $1 * $1 } / Float(max(sustain.count, 1)))
    let file = "\(parts[3].dropFirst(3))-\(dynamic)-\(written).m4a"
    cuts.append(Cut(note: .init(file: file, midi: written, string: string, dynamic: dynamic, cents: cents,
                                loopStart: ls, loopEnd: le, frames: s.count, rms: rms), samples: s))
}

guard !cuts.isEmpty else {
    print("No notes found.\n  " + problems.joined(separator: "\n  "))
    exit(1)
}
// Balance: every note to the same sustain loudness (the takes vary), then one gain so the loudest peak is 0.9.
let targetRMS = cuts.map(\.note.rms).sorted()[cuts.count / 2]
var balanced = cuts.map { cut -> Cut in
    var c = cut
    let g = targetRMS / max(cut.note.rms, 1e-6)
    c.samples = cut.samples.map { $0 * g }
    c.note.rms = targetRMS
    return c
}
let peak = balanced.flatMap(\.samples).map(abs).max() ?? 1
let gain = 0.9 / peak
var manifestNotes: [SampleManifest.Note] = []
for i in balanced.indices {
    balanced[i].samples = balanced[i].samples.map { $0 * gain }
    try writeAAC(balanced[i].samples, sr: 44100, to: output.appendingPathComponent(balanced[i].note.file))
    var n = balanced[i].note
    n.rms *= gain
    manifestNotes.append(n)
}
let manifest = SampleManifest(
    instrument: "Violoncello (arco)",
    source: "University of Iowa Electronic Music Studios, Musical Instrument Samples: cello (2012), theremin.music.uiowa.edu/MIS.html",
    license: "Free to use for any project, without restrictions (University of Iowa EMS). Trimmed, looped, balanced and encoded for Music Reader.",
    sampleRate: 44100, notes: manifestNotes.sorted { ($0.midi, $0.string) < ($1.midi, $1.string) })
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"))

let c = manifestNotes.map(\.cents).sorted()
print("\(manifestNotes.count) samples from \(files.count) files; recordings' tuning: median \(String(format: "%+.1f", c[c.count / 2])) ¢, " +
      "range \(String(format: "%+.1f", c.first ?? 0)) to \(String(format: "%+.1f", c.last ?? 0)) ¢")
let covered = Set(manifestNotes.map(\.midi))
print("Covers MIDI \(covered.min() ?? 0)–\(covered.max() ?? 0); gaps: \(Array(Set((covered.min() ?? 0)...(covered.max() ?? 0)).subtracting(covered)).sorted())")
if !problems.isEmpty { print("\nNotes:\n  " + problems.joined(separator: "\n  ")) }
