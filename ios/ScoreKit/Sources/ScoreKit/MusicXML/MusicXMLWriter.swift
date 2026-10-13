import Foundation

/// Writes a `Score` as MusicXML 4.0 `score-partwise`, so a score made or corrected here opens in
/// MuseScore, Dorico, Sibelius or Finale.
public enum MusicXMLWriter {
    /// 480 per quarter covers every value down to 64th notes, including triplets and quintuplets.
    static let divisions = 480

    public static func write(_ score: Score) -> Data {
        var x = XMLBuilder()
        x.raw("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>")
        x.raw("<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">")
        x.open("score-partwise", ["version": "4.0"])
        x.open("work"); x.leaf("work-title", score.title); x.close()
        x.open("identification")
        if !score.composer.isEmpty { x.leaf("creator", score.composer, ["type": "composer"]) }
        x.open("encoding"); x.leaf("software", "Music Reader"); x.close()
        x.close()
        x.open("part-list")
        for part in score.parts {
            x.open("score-part", ["id": part.id])
            x.leaf("part-name", part.name)
            x.open("score-instrument", ["id": "\(part.id)-I1"]); x.leaf("instrument-name", part.name); x.close()
            x.open("midi-instrument", ["id": "\(part.id)-I1"]); x.leaf("midi-program", "\(part.midiProgram + 1)"); x.close()
            x.close()
        }
        x.close()
        for part in score.parts { writePart(part, to: &x) }
        x.close()
        return Data(x.output.utf8)
    }

    private static func writePart(_ part: Part, to x: inout XMLBuilder) {
        x.open("part", ["id": part.id])
        let resolved = part.resolvedAttributes
        let tied = AccidentalRules.tiedAcrossBarlines(part)
        for (i, m) in part.measures.enumerated() {
            let shown = AccidentalRules.displayed(in: m, key: resolved[i].key, tiedFromPrevious: tied[i] ?? [])
            var attrs: [String: String] = ["number": "\(m.number)"]
            if m.isPickup { attrs["implicit"] = "yes" }
            x.open("measure", attrs)
            if m.barline == .repeatStart || m.barline == .repeatBoth {
                x.open("barline", ["location": "left"]); x.leaf("bar-style", "heavy-light"); x.empty("repeat", ["direction": "forward"]); x.close()
            }
            if i == 0 || m.attributes.map({ $0.clef != nil || $0.key != nil || $0.time != nil }) == true {
                x.open("attributes")
                if i == 0 { x.leaf("divisions", "\(divisions)") }
                let a = i == 0 ? MeasureAttributes(clef: resolved[0].clef, key: resolved[0].key, time: resolved[0].time) : m.attributes!
                if let key = a.key { x.open("key"); x.leaf("fifths", "\(key.fifths)"); x.leaf("mode", key.mode.rawValue); x.close() }
                if let t = a.time {
                    x.open("time", t.symbol == .normal ? [:] : ["symbol": t.symbol.rawValue])
                    x.leaf("beats", "\(t.beats)"); x.leaf("beat-type", "\(t.beatType)"); x.close()
                }
                if let c = a.clef { writeClef(c, to: &x) }
                x.close()
            }
            if let tempo = (i == 0 ? resolved[0].tempo : m.attributes?.tempo) { writeTempo(tempo, to: &x) }
            let measureLength = resolved[i].time.measureDuration
            for item in m.items {
                switch item {
                case .note(let n): writeNote(n, measureLength: measureLength, accidentals: shown[n.id] ?? [:], to: &x)
                case .clef(let c): x.open("attributes"); writeClef(c, to: &x); x.close()
                case .dynamic(let d):
                    x.open("direction", ["placement": "below"]); x.open("direction-type"); x.open("dynamics"); x.empty(d.rawValue)
                    x.close(); x.close(); x.close()
                case .wedge(let w):
                    x.open("direction", ["placement": "below"]); x.open("direction-type"); x.empty("wedge", ["type": w.rawValue])
                    x.close(); x.close()
                case .tempo(let t): writeTempo(t, to: &x)
                case .text(let s):
                    x.open("direction", ["placement": "above"]); x.open("direction-type"); x.leaf("words", s); x.close(); x.close()
                }
            }
            switch m.barline {
            case .double: x.open("barline", ["location": "right"]); x.leaf("bar-style", "light-light"); x.close()
            case .final: x.open("barline", ["location": "right"]); x.leaf("bar-style", "light-heavy"); x.close()
            case .repeatEnd, .repeatBoth:
                x.open("barline", ["location": "right"]); x.leaf("bar-style", "light-heavy"); x.empty("repeat", ["direction": "backward"]); x.close()
            case .regular, .repeatStart: break
            }
            x.close()
        }
        x.close()
    }

    private static func writeClef(_ c: Clef, to x: inout XMLBuilder) {
        x.open("clef"); x.leaf("sign", c.sign.rawValue); x.leaf("line", "\(c.line)")
        if c.octaveChange != 0 { x.leaf("clef-octave-change", "\(c.octaveChange)") }
        x.close()
    }

    private static func writeTempo(_ t: Tempo, to x: inout XMLBuilder) {
        x.open("direction", ["placement": "above"])
        if let text = t.text, !text.isEmpty { x.open("direction-type"); x.leaf("words", text, ["font-weight": "bold"]); x.close() }
        x.open("direction-type"); x.open("metronome")
        x.leaf("beat-unit", t.beatUnit.kind.musicXMLName)
        for _ in 0..<t.beatUnit.dots { x.empty("beat-unit-dot") }
        x.leaf("per-minute", format(t.bpm))
        x.close(); x.close()
        x.empty("sound", ["tempo": format(t.quarterBPM)])
        x.close()
    }

    private static func writeNote(_ n: NoteEvent, measureLength: Fraction, accidentals: [Int: Accidental], to x: inout XMLBuilder) {
        let value = n.isMeasureRest ? measureLength : n.duration.value
        let ticks = value.num * divisions * 4 / value.den
        let pitches: [Pitch?] = n.isRest ? [nil] : n.pitches
        for (i, p) in pitches.enumerated() {
            x.open("note")
            if n.isGrace { x.empty("grace") }
            if i > 0 { x.empty("chord") }
            if let p {
                x.open("pitch"); x.leaf("step", p.step.letter)
                if p.alter != 0 { x.leaf("alter", "\(p.alter)") }
                x.leaf("octave", "\(p.octave)"); x.close()
            } else {
                x.empty("rest", n.isMeasureRest ? ["measure": "yes"] : [:])
            }
            if !n.isGrace { x.leaf("duration", "\(ticks)") }
            if n.tieToNext { x.empty("tie", ["type": "start"]) }
            x.leaf("voice", "1")
            if !n.isMeasureRest {
                x.leaf("type", n.duration.kind.musicXMLName)
                for _ in 0..<n.duration.dots { x.empty("dot") }
            }
            if let shown = accidentals[i] {
                let name = switch shown {
                case .doubleFlat: "flat-flat"
                case .flat: "flat"
                case .sharp: "sharp"
                case .doubleSharp: "double-sharp"
                case .natural: "natural"
                }
                x.leaf("accidental", name, n.forcedAccidentals.contains(i) ? ["cautionary": "yes"] : [:])
            }
            if let t = n.duration.tuplet {
                x.open("time-modification"); x.leaf("actual-notes", "\(t.actual)"); x.leaf("normal-notes", "\(t.normal)"); x.close()
            }
            // Notations go on the first chord tone only.
            if i == 0 { writeNotations(n, to: &x) } else if n.tieToNext { x.open("notations"); x.empty("tied", ["type": "start"]); x.close() }
            x.close()
        }
    }

    private static func writeNotations(_ n: NoteEvent, to x: inout XMLBuilder) {
        let arts = n.articulations.subtracting([.fermata])
        let hasTech = n.bowing != nil || !n.fingerings.isEmpty || n.string != nil || n.harmonic
        guard n.tieToNext || n.slurStart || n.slurStop || !n.articulations.isEmpty || hasTech else { return }
        x.open("notations")
        if n.tieToNext { x.empty("tied", ["type": "start"]) }
        if n.slurStop { x.empty("slur", ["type": "stop", "number": "1"]) }
        if n.slurStart { x.empty("slur", ["type": "start", "number": "1"]) }
        if n.articulations.contains(.fermata) { x.empty("fermata", ["type": "upright"]) }
        if !arts.isEmpty {
            x.open("articulations")
            for a in arts.sorted(by: { $0.rawValue < $1.rawValue }) { x.empty(a == .marcato ? "strong-accent" : a.rawValue) }
            x.close()
        }
        if hasTech {
            x.open("technical")
            if let b = n.bowing { x.empty(b == .down ? "down-bow" : "up-bow") }
            if n.harmonic { x.empty("harmonic") }
            for f in n.fingerings { if f == 5 { x.empty("thumb-position") } else { x.leaf("fingering", "\(f)") } }
            if let s = n.string { x.leaf("string", "\(s.rawValue)") }
            x.close()
        }
        x.close()
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.2f", v)
    }
}

/// Indented XML text output with escaping.
struct XMLBuilder {
    private(set) var output = ""
    private var stack: [String] = []

    mutating func raw(_ s: String) { output += s + "\n" }
    mutating func open(_ name: String, _ attrs: [String: String] = [:]) {
        line("<\(name)\(attributes(attrs))>")
        stack.append(name)
    }
    mutating func close() { let n = stack.removeLast(); line("</\(n)>") }
    mutating func leaf(_ name: String, _ text: String, _ attrs: [String: String] = [:]) {
        line("<\(name)\(attributes(attrs))>\(escape(text))</\(name)>")
    }
    mutating func empty(_ name: String, _ attrs: [String: String] = [:]) { line("<\(name)\(attributes(attrs))/>") }

    private mutating func line(_ s: String) { output += String(repeating: "  ", count: stack.count) + s + "\n" }
    private func attributes(_ a: [String: String]) -> String {
        a.keys.sorted().map { " \($0)=\"\(escape(a[$0]!))\"" }.joined()
    }
    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
