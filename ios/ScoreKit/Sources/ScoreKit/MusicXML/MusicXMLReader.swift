import Foundation

/// Reads `score-partwise` MusicXML (what Audiveris, MuseScore, Sibelius, Finale and Dorico export) into
/// a `Score`. Each part keeps one voice on one staff, its first: a cello part is a single line,
/// and double stops come through as chords. Second voices and lower staves of piano parts are dropped.
public enum MusicXMLReader {
    public static func read(_ data: Data) throws -> Score {
        let root = try XMLTree.parse(data)
        guard root.name == "score-partwise" else {
            throw root.name == "score-timewise" ? MusicXMLError.unsupported("timewise scores") : MusicXMLError.malformed("not a MusicXML score")
        }
        let title = root.string("work/work-title") ?? root.string("movement-title") ?? ""
        let composer = root.child("identification")?.children("creator").first { $0.attributes["type"] == "composer" }?
            .text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var names: [String: String] = [:]
        for sp in root.child("part-list")?.children("score-part") ?? [] {
            if let id = sp.attributes["id"] { names[id] = sp.string("part-name") ?? id }
        }
        let parts = root.children("part").map { node -> Part in
            let id = node.attributes["id"] ?? "P1"
            var reader = PartReader(node: node)
            return reader.read(id: id, name: names[id] ?? "Part")
        }.filter { !$0.measures.isEmpty }
        guard !parts.isEmpty else { throw MusicXMLError.empty }
        var score = Score(title: title, composer: composer, parts: parts, source: .musicXML)
        if score.title.isEmpty { inferTitle(root, into: &score) }
        if score.title.isEmpty { score.title = "Untitled" }
        return score
    }

    /// Recognised scans often lack `<work-title>`: OMR files the printed title as a large text direction
    /// over bar 1, or as a page credit. The largest such text with real words becomes the title (and stops
    /// being drawn as an expression mark over the music).
    static func inferTitle(_ root: XMLTree, into score: inout Score) {
        func letters(_ s: String) -> Int { s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count }
        var best: (text: String, size: Double)?
        let credits = root.children("credit").flatMap { $0.children("credit-words") }
        let firstMeasureWords = root.child("part")?.child("measure")?.children("direction")
            .flatMap { $0.children("direction-type") }.compactMap { $0.child("words") } ?? []
        for w in credits + firstMeasureWords {
            let text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let size = Double(w.attributes["font-size"] ?? "") ?? 0
            // Expression text ("dolce", "rit.") is small; titles are set large.
            guard letters(text) >= 4, size >= 12, TempoMarking.parse(text) == nil else { continue }
            if best == nil || size > best!.size { best = (text, size) }
        }
        guard let title = best?.text else { return }
        score.title = title
        guard !score.parts.isEmpty, !score.parts[0].measures.isEmpty else { return }
        score.parts[0].measures[0].items.removeAll { $0 == .text(title) }
    }
}

private struct PartReader {
    let node: XMLTree
    var divisions = 1
    /// The voice kept: the first one met on staff 1.
    var voice: String?
    var time = TimeSignature.common

    init(node: XMLTree) { self.node = node }

    mutating func read(id: String, name: String) -> Part {
        let measures = node.children("measure").enumerated().map { i, m in readMeasure(m, index: i) }
        return Part(id: id, name: name, measures: measures)
    }

    mutating func readMeasure(_ m: XMLTree, index: Int) -> Measure {
        var measure = Measure(number: Int(m.attributes["number"] ?? "") ?? index + 1)
        measure.isPickup = index == 0 && m.attributes["implicit"] == "yes"
        var attrs = MeasureAttributes()
        var sawNote = false
        // Notes of other voices are skipped; directions inside a skipped stretch are skipped too.
        var inOtherVoice = false

        for child in m.children {
            switch child.name {
            case "attributes":
                if let d = child.int("divisions"), d > 0 { divisions = d }
                let clef = readClef(child)
                if sawNote {
                    if let clef { measure.items.append(.clef(clef)) }
                } else {
                    attrs.clef = clef ?? attrs.clef
                }
                if let key = child.child("key"), let fifths = key.int("fifths") {
                    attrs.key = KeySignature(fifths: fifths, mode: key.string("mode") == "minor" ? .minor : .major)
                }
                if let t = child.child("time"), let ts = readTime(t) {
                    attrs.time = ts
                    time = ts
                }
            case "backup":
                inOtherVoice = true
            case "forward":
                // A forward inside the kept voice is an invisible rest; elsewhere it's another voice's spacing.
                if !inOtherVoice, let d = child.int("duration"), (child.string("voice") ?? voice) == voice {
                    for dur in NoteValue.decompose(Fraction(d, divisions * 4)) { measure.items.append(.note(NoteEvent(rest: dur))) }
                }
            case "direction":
                guard !inOtherVoice, (child.string("staff") ?? "1") == "1" else { continue }
                for item in readDirection(child) {
                    if case .tempo(let t) = item, !sawNote { attrs.tempo = t } else { measure.items.append(item) }
                }
            case "sound":
                if let bpm = child.attributes["tempo"].flatMap(Double.init), !sawNote, attrs.tempo == nil {
                    attrs.tempo = Tempo(bpm: bpm)
                }
            case "note":
                if (child.string("staff") ?? "1") != "1" { continue }
                let v = child.string("voice") ?? "1"
                if voice == nil { voice = v }
                if v != voice { continue }
                inOtherVoice = false
                readNote(child, into: &measure)
                sawNote = true
            case "barline":
                readBarline(child, into: &measure)
            default:
                break
            }
        }
        if !attrs.isEmpty { measure.attributes = attrs }
        // A lone whole-measure rest of the meter's length is a measure rest.
        if measure.notes.count == 1, measure.notes[0].isRest, measure.notes[0].duration.value == time.measureDuration {
            if let i = measure.items.firstIndex(where: { $0.note != nil }), var n = measure.items[i].note {
                n.isMeasureRest = true
                measure.items[i] = .note(n)
            }
        }
        if measure.notes.isEmpty { measure.items.append(.note(NoteEvent(rest: .whole, measureRest: true))) }
        return measure
    }

    func readClef(_ attributes: XMLTree) -> Clef? {
        let clefs = attributes.children("clef")
        guard let c = clefs.first(where: { ($0.attributes["number"] ?? "1") == "1" }) ?? clefs.first,
              let signText = c.string("sign"), let sign = Clef.Sign(rawValue: signText) else { return nil }
        let defaultLine = switch sign {
        case .g: 2
        case .f: 4
        case .c, .percussion: 3
        }
        return Clef(sign: sign, line: c.int("line") ?? defaultLine, octaveChange: c.int("clef-octave-change") ?? 0)
    }

    func readTime(_ t: XMLTree) -> TimeSignature? {
        if t.has("senza-misura") { return nil }
        // Additive meters ("3+2") are summed.
        guard let beatsText = t.string("beats"), let beatType = t.int("beat-type") else { return nil }
        let beats = beatsText.split(separator: "+").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
        guard beats > 0 else { return nil }
        let symbol: TimeSignature.Symbol = switch t.attributes["symbol"] {
        case "common": .common
        case "cut": .cut
        default: .normal
        }
        return TimeSignature(beats, beatType, symbol: symbol)
    }

    func readDirection(_ d: XMLTree) -> [MeasureItem] {
        var items: [MeasureItem] = []
        var words: [String] = []
        var metronome: Tempo?
        for dt in d.children("direction-type") {
            if let dyn = dt.child("dynamics") {
                for mark in dyn.children { if let v = Dynamic(rawValue: mark.name) { items.append(.dynamic(v)) } }
            }
            if let w = dt.child("words")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty { words.append(w) }
            if let wedge = dt.child("wedge")?.attributes["type"], let v = Wedge(rawValue: wedge) { items.append(.wedge(v)) }
            if let met = dt.child("metronome"), let unitName = met.string("beat-unit"),
               let kind = NoteValue.Kind(musicXMLName: unitName), let bpm = met.double("per-minute") {
                metronome = Tempo(bpm: bpm, beatUnit: NoteValue(kind, dots: met.children("beat-unit-dot").count))
            }
        }
        let soundTempo = d.child("sound")?.attributes["tempo"].flatMap(Double.init)
        let text = words.joined(separator: " ")
        let marking = TempoMarking.parse(text)
        if var tempo = metronome ?? soundTempo.map({ Tempo(bpm: $0) }) ?? marking.map({ Tempo(bpm: $0.typicalBPM) }) {
            if marking != nil || metronome != nil { tempo.text = text.isEmpty ? nil : text }
            items.append(.tempo(tempo))
        } else if !text.isEmpty {
            items.append(.text(text))
        }
        return items
    }

    mutating func readNote(_ n: XMLTree, into measure: inout Measure) {
        let isChordTone = n.has("chord")
        let pitch: Pitch? = n.child("pitch").flatMap { p in
            guard let stepText = p.string("step"), let step = Step(letter: stepText), let octave = p.int("octave") else { return nil }
            return Pitch(step, octave, alter: p.int("alter") ?? 0)
        }
        let cautionary = n.child("accidental").map { $0.attributes["cautionary"] == "yes" || $0.attributes["parentheses"] == "yes" } ?? false

        // A chord tone joins the previous note event.
        if isChordTone, let pitch, let last = measure.items.lastIndex(where: { $0.note != nil }), var prev = measure.items[last].note {
            prev.pitches.append(pitch)
            prev.pitches.sort()
            if cautionary, let i = prev.pitches.firstIndex(of: pitch) { prev.forcedAccidentals.insert(i) }
            readNotations(n, into: &prev)
            measure.items[last] = .note(prev)
            return
        }

        var note = NoteEvent(duration: readDuration(n), pitches: pitch.map { [$0] } ?? [], isGrace: n.has("grace"))
        if n.child("rest")?.attributes["measure"] == "yes" { note.isMeasureRest = true }
        if cautionary { note.forcedAccidentals = [0] }
        note.tieToNext = n.children("tie").contains { $0.attributes["type"] == "start" }
        readNotations(n, into: &note)
        measure.items.append(.note(note))
    }

    func readDuration(_ n: XMLTree) -> NoteValue {
        let tuplet: NoteValue.Tuplet? = n.child("time-modification").flatMap { tm in
            guard let a = tm.int("actual-notes"), let b = tm.int("normal-notes"), a > 0, b > 0 else { return nil }
            return NoteValue.Tuplet(actual: a, normal: b)
        }
        if let typeName = n.string("type"), let kind = NoteValue.Kind(musicXMLName: typeName) {
            return NoteValue(kind, dots: n.children("dot").count, tuplet: tuplet)
        }
        // No <type> (some exporters, measure rests): derive from <duration>.
        let value = Fraction(n.int("duration") ?? divisions * 4, divisions * 4)
        return NoteValue.from(value: value) ?? NoteValue.decompose(value).first ?? .quarter
    }

    func readNotations(_ n: XMLTree, into note: inout NoteEvent) {
        for notations in n.children("notations") {
            for slur in notations.children("slur") {
                switch slur.attributes["type"] {
                case "start": note.slurStart = true
                case "stop": note.slurStop = true
                default: break
                }
            }
            if notations.has("fermata") { note.articulations.insert(.fermata) }
            if let arts = notations.child("articulations") {
                for a in arts.children {
                    switch a.name {
                    case "staccato": note.articulations.insert(.staccato)
                    case "staccatissimo": note.articulations.insert(.staccatissimo)
                    case "accent": note.articulations.insert(.accent)
                    case "tenuto": note.articulations.insert(.tenuto)
                    case "strong-accent": note.articulations.insert(.marcato)
                    case "spiccato": note.articulations.insert(.spiccato)
                    default: break
                    }
                }
            }
            if let tech = notations.child("technical") {
                if tech.has("down-bow") { note.bowing = .down }
                if tech.has("up-bow") { note.bowing = .up }
                if tech.has("harmonic") { note.harmonic = true }
                if tech.has("thumb-position") { note.fingerings.append(5) }
                for f in tech.children("fingering") { if let v = Int(f.text.trimmingCharacters(in: .whitespaces)) { note.fingerings.append(v) } }
                if let s = tech.int("string") { note.string = CelloString(rawValue: s) }
            }
        }
    }

    func readBarline(_ b: XMLTree, into measure: inout Measure) {
        let location = b.attributes["location"] ?? "right"
        let repeatDir = b.child("repeat")?.attributes["direction"]
        if location == "left", repeatDir == "forward" {
            measure.barline = measure.barline == .repeatEnd ? .repeatBoth : .repeatStart
        } else if location == "right" {
            if repeatDir == "backward" {
                measure.barline = measure.barline == .repeatStart ? .repeatBoth : .repeatEnd
            } else {
                switch b.string("bar-style") {
                case "light-light": measure.barline = .double
                case "light-heavy": measure.barline = .final
                default: break
                }
            }
        }
    }
}
