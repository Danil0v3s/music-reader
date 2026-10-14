import CoreGraphics
import Foundation

/// What to draw. The layout says what and where; the app decides colours (selection, playback,
/// intonation) through `owner` without relaying out.
public enum Primitive: Sendable {
    /// A Bravura glyph string drawn with its origin (baseline-left, or centred when `centered`) at `at`.
    case glyph(String, at: CGPoint, size: CGFloat, centered: Bool, owner: UUID?)
    case line(from: CGPoint, to: CGPoint, width: CGFloat, owner: UUID?)
    /// Filled quadrilateral (beams).
    case polygon([CGPoint], owner: UUID?)
    /// Ties and slurs: a filled crescent between two cubic curves.
    case curve(from: CGPoint, to: CGPoint, height: CGFloat, thickness: CGFloat, owner: UUID?)
    case text(String, at: CGPoint, size: CGFloat, style: TextStyle, anchor: TextAnchor)

    public enum TextStyle: Sendable { case regular, bold, italic, title }
    public enum TextAnchor: Sendable { case left, center, right }
}

public struct LayoutOptions: Hashable, Sendable {
    /// Distance between two staff lines, in points. 7–9 reads well on a phone.
    public var staffSpace: CGFloat
    public var width: CGFloat
    public var margin: CGFloat
    public var showHeader: Bool

    public init(staffSpace: CGFloat = 8, width: CGFloat, margin: CGFloat = 16, showHeader: Bool = true) {
        self.staffSpace = staffSpace
        self.width = width
        self.margin = margin
        self.showHeader = showHeader
    }
}

/// One line of music: its staff position and the measures it holds.
public struct SystemGeometry: Sendable {
    public var measures: Range<Int>
    /// y of the top staff line.
    public var staffTop: CGFloat
    public var staffSpace: CGFloat
    public var x0: CGFloat
    public var x1: CGFloat
    /// The band (including room above and below the staff) that taps map to this system.
    public var band: ClosedRange<CGFloat>

    /// y of a staff step (0 = bottom line, 8 = top line).
    public func y(ofStep step: Int) -> CGFloat { staffTop + CGFloat(8 - step) * staffSpace / 2 }
    /// The staff step nearest a y coordinate.
    public func step(atY y: CGFloat) -> Int { 8 - Int(((y - staffTop) / (staffSpace / 2)).rounded()) }
}

public struct MeasureGeometry: Sendable {
    public var index: Int
    public var system: Int
    public var frame: CGRect
    /// Where notes start (after any clef/key/time prefix): taps left of it insert at the start.
    public var contentX: CGFloat
    /// x of each item's notehead (directions take the x of the note they precede), by item index.
    public var itemX: [Int: CGFloat]
    public var clef: Clef
}

/// Where a tap landed in musical terms.
public struct StaffHit: Hashable, Sendable {
    public var measure: Int
    /// Item index a new note would be inserted at.
    public var insertIndex: Int
    public var step: Int
    public var pitch: Pitch
    /// A note whose head is under the finger, if any.
    public var noteId: UUID?
}

public struct ScoreLayout: Sendable {
    public var size: CGSize
    public var primitives: [Primitive]
    public var systems: [SystemGeometry]
    public var measures: [MeasureGeometry]
    public var noteFrames: [UUID: CGRect]

    /// Turns a point into a measure, insertion point and pitch, for the editor.
    public func hit(_ p: CGPoint, part: Part) -> StaffHit? {
        guard let sysIndex = systems.firstIndex(where: { $0.band.contains(p.y) })
                ?? systems.indices.min(by: { abs(systems[$0].staffTop - p.y) < abs(systems[$1].staffTop - p.y) }) else { return nil }
        let sys = systems[sysIndex]
        let inSystem = measures.filter { $0.system == sysIndex }
        guard let m = inSystem.first(where: { $0.frame.minX <= p.x && p.x < $0.frame.maxX })
                ?? (p.x < (inSystem.first?.frame.minX ?? 0) ? inSystem.first : inSystem.last) else { return nil }
        let step = max(-8, min(16, sys.step(atY: p.y)))
        let items = part.measures[m.index].items
        // Insert before the first note whose head is right of the tap.
        let insert = items.indices.first { i in items[i].note != nil && (m.itemX[i] ?? .infinity) > p.x - sys.staffSpace * 0.6 } ?? items.count
        let clef = part.clef(at: ItemPath(measure: m.index, item: insert))
        let natural = clef.pitch(atStaffStep: step)
        let key = part.attributes(at: m.index).key
        let pitch = Pitch(natural.step, natural.octave, alter: key.alter(for: natural.step))
        let tolerance = sys.staffSpace * 0.9
        let note = noteFrames.first { $0.value.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p) }?.key
        return StaffHit(measure: m.index, insertIndex: insert, step: step, pitch: pitch, noteId: note)
    }
}

// MARK: - Engine

public enum LayoutEngine {
    public static func layout(_ score: Score, partIndex: Int = 0, options: LayoutOptions) -> ScoreLayout {
        var builder = Builder(score: score, part: score.parts[min(partIndex, score.parts.count - 1)], options: options)
        return builder.run()
    }
}

/// Per-measure spacing: fixed widths (accidentals, padding) and springs that stretch to justify a line.
private struct MeasureMetrics {
    var fixed: CGFloat
    var spring: CGFloat
    /// Width of a clef/key/time change printed at the start of this measure (when not at a line start).
    var change: CGFloat
}

private struct Builder {
    let score: Score
    let part: Part
    let o: LayoutOptions
    let s: CGFloat
    let resolved: [ResolvedAttributes]
    let accidentals: [Int: [UUID: [Int: Accidental]]]

    var out: [Primitive] = []
    var noteFrames: [UUID: CGRect] = [:]
    var systems: [SystemGeometry] = []
    var measureGeos: [MeasureGeometry] = []

    /// Notes waiting for the next system (tie/slur continuations).
    var openTies: [(from: CGPoint, up: Bool, owner: UUID)] = []
    var openSlur: (from: CGPoint, above: Bool, owner: UUID)?
    var openWedge: (x: CGFloat, kind: Wedge)?

    init(score: Score, part: Part, options: LayoutOptions) {
        self.score = score
        self.part = part
        self.o = options
        self.s = options.staffSpace
        self.resolved = part.resolvedAttributes
        let tied = AccidentalRules.tiedAcrossBarlines(part)
        var acc: [Int: [UUID: [Int: Accidental]]] = [:]
        for (i, m) in part.measures.enumerated() {
            acc[i] = AccidentalRules.displayed(in: m, key: resolved[i].key, tiedFromPrevious: tied[i] ?? [])
        }
        self.accidentals = acc
    }

    // MARK: Spacing

    func spring(_ n: NoteEvent) -> CGFloat {
        if n.isGrace { return 1.6 * s }
        if n.isMeasureRest { return 6 * s }
        let q = n.duration.quarters
        return (3.2 * pow(q, 0.6) + 1.0) * s
    }

    func fixedWidth(_ n: NoteEvent, measure i: Int) -> CGFloat {
        var w: CGFloat = 0
        if let acc = accidentals[i]?[n.id], !acc.isEmpty {
            let widest = acc.values.map { SMuFL.accidentalWidth($0) }.max() ?? 1
            w += CGFloat(widest + 0.3) * s * (acc.count > 1 ? 1.8 : 1)
        }
        w += CGFloat(n.duration.dots) * 0.6 * s
        if n.pitches.count > 1, hasSecond(n.pitches) { w += 1.2 * s }
        return w
    }

    func keyWidth(_ key: KeySignature) -> CGFloat { CGFloat(abs(key.fifths)) * 1.0 * s + (key.fifths == 0 ? 0 : 0.6 * s) }
    func clefW() -> CGFloat { 3.2 * s }
    func timeW() -> CGFloat { 2.6 * s }

    func metrics(_ i: Int) -> MeasureMetrics {
        let m = part.measures[i]
        var fixed: CGFloat = 1.2 * s  // left padding
        var springs: CGFloat = 0
        for item in m.items {
            switch item {
            case .note(let n):
                fixed += fixedWidth(n, measure: i)
                springs += spring(n)
            case .clef:
                fixed += 2.4 * s
            default: break
            }
        }
        // An unfinished bar keeps room for what's missing, so there's space to write into.
        if case .underfull(let missing) = m.fill(in: resolved[i].time) {
            springs += (3.2 * pow(missing.double * 4, 0.6) + 1.0) * s
        }
        fixed += 0.6 * s  // right padding before the barline
        if m.barline == .repeatEnd || m.barline == .repeatBoth { fixed += 1.2 * s }
        if m.barline == .repeatStart || m.barline == .repeatBoth { fixed += 1.2 * s }
        var change: CGFloat = 0
        if i > 0, let a = m.attributes {
            if a.clef != nil { change += 2.6 * s }
            if let k = a.key, k != resolved[i - 1].key { change += keyWidth(k) + CGFloat(abs(resolved[i - 1].key.fifths)) * 0.8 * s * (k.fifths == 0 ? 1 : 0) }
            if a.time != nil { change += timeW() }
        }
        return MeasureMetrics(fixed: fixed, spring: springs, change: change)
    }

    /// Width of the clef + key (+ time on the first line or when it changes) at the start of a line.
    func linePrefix(at i: Int) -> CGFloat {
        let a = resolved[i]
        var w = 0.8 * s + clefW() + keyWidth(a.key)
        if i == 0 || part.measures[i].attributes?.time != nil { w += timeW() }
        return w
    }

    // MARK: Run

    mutating func run() -> ScoreLayout {
        let metrics = part.measures.indices.map(metrics)
        let x0 = o.margin
        let x1 = o.width - o.margin
        var y = o.margin

        if o.showHeader {
            out.append(.text(score.title, at: CGPoint(x: o.width / 2, y: y + 3 * s), size: 2.8 * s, style: .title, anchor: .center))
            y += 4.5 * s
            if !score.composer.isEmpty {
                out.append(.text(score.composer, at: CGPoint(x: x1, y: y + 1.5 * s), size: 1.6 * s, style: .regular, anchor: .right))
                y += 2.5 * s
            }
        }

        // Greedy line breaking on natural widths.
        var lines: [Range<Int>] = []
        var start = 0
        while start < part.measures.count {
            let available = x1 - x0 - linePrefix(at: start)
            var used: CGFloat = 0
            var end = start
            while end < part.measures.count {
                let m = metrics[end]
                let w = m.fixed + m.spring + (end == start ? 0 : m.change)
                if end > start, used + w > available { break }
                used += w
                end += 1
            }
            lines.append(start..<end)
            start = end
        }

        for (li, line) in lines.enumerated() {
            let (above, below) = extents(line)
            let staffTop = y + above
            let prefix = linePrefix(at: line.lowerBound)
            let available = x1 - x0 - prefix
            let fixedSum = line.reduce(CGFloat(0)) { $0 + metrics[$1].fixed + ($1 == line.lowerBound ? 0 : metrics[$1].change) }
            let springSum = line.reduce(CGFloat(0)) { $0 + metrics[$1].spring }
            var k = springSum > 0 ? (available - fixedSum) / springSum : 1
            let isLast = li == lines.count - 1
            // Don't stretch a short last line across the page.
            if isLast, fixedSum + springSum < available * 0.7 { k = 1 }
            k = max(k, 0.5)

            let geo = SystemGeometry(measures: line, staffTop: staffTop, staffSpace: s, x0: x0,
                                     x1: isLast && k == 1 ? x0 + prefix + fixedSum + springSum : x1,
                                     band: (staffTop - above)...(staffTop + 4 * s + below))
            systems.append(geo)
            drawSystem(geo, index: systems.count - 1, metrics: metrics, stretch: k, firstLine: li == 0)
            y = staffTop + 4 * s + below
        }

        return ScoreLayout(size: CGSize(width: o.width, height: y + o.margin), primitives: out, systems: systems,
                           measures: measureGeos, noteFrames: noteFrames)
    }

    /// Room needed above and below a line's staff for ledger-line notes, bowings and dynamics.
    func extents(_ line: Range<Int>) -> (CGFloat, CGFloat) {
        var high = 8, low = 0
        var marks: CGFloat = 0
        var dynamics = false, tempo = false
        for i in line {
            var clef = resolved[i].clef
            if part.measures[i].attributes?.tempo != nil { tempo = true }
            for item in part.measures[i].items {
                switch item {
                case .clef(let c): clef = c
                case .note(let n):
                    for p in n.pitches {
                        let st = clef.staffStep(of: p)
                        high = max(high, st + (n.duration.kind.hasStem && st < 4 ? 7 : 0))
                        low = min(low, st - (n.duration.kind.hasStem && st >= 4 ? 7 : 0))
                    }
                    var h: CGFloat = 0
                    if n.articulations.contains(.fermata) { h += 2 }
                    if n.bowing != nil { h += 2.7 }
                    h += 1.5 * CGFloat(n.fingerings.count)
                    if n.string != nil { h += 1.5 }
                    marks = max(marks, h * s)
                case .dynamic, .wedge: dynamics = true
                case .tempo, .text: tempo = true
                }
            }
        }
        let above = max(CGFloat(high - 8) / 2 * s, 0) + marks + (tempo ? 3 * s : 0) + 3 * s
        let below = max(CGFloat(-low) / 2 * s, 0) + (dynamics ? 3 * s : 0) + 3 * s
        return (above, below)
    }

    // MARK: Systems

    mutating func drawSystem(_ sys: SystemGeometry, index sysIndex: Int, metrics: [MeasureMetrics], stretch k: CGFloat, firstLine: Bool) {
        let first = sys.measures.lowerBound
        // Staff lines.
        for l in 0..<5 {
            let y = sys.staffTop + CGFloat(l) * s
            out.append(.line(from: CGPoint(x: sys.x0, y: y), to: CGPoint(x: sys.x1, y: y), width: 0.13 * s, owner: nil))
        }
        // Line start: barline, clef, key, time.
        out.append(.line(from: CGPoint(x: sys.x0, y: sys.staffTop), to: CGPoint(x: sys.x0, y: sys.staffTop + 4 * s), width: 0.16 * s, owner: nil))
        var x = sys.x0 + 0.8 * s
        let a = resolved[first]
        drawClef(a.clef, x: x, sys: sys, small: false)
        x += clefW()
        drawKey(a.key, clef: a.clef, x: x, sys: sys)
        x += keyWidth(a.key)
        if first == 0 || part.measures[first].attributes?.time != nil {
            drawTime(a.time, x: x, sys: sys)
            x += timeW()
        }
        if !firstLine {
            out.append(.text("\(part.measures[first].number)", at: CGPoint(x: sys.x0, y: sys.staffTop - 1.2 * s), size: 1.3 * s, style: .italic, anchor: .left))
        }

        // Continue ties/slurs/hairpins from the previous line.
        // (Their y was stored relative to the previous line's staff.)
        for tie in openTies {
            let y = sys.staffTop + tie.from.y
            out.append(.curve(from: CGPoint(x: x - 1.5 * s, y: y), to: CGPoint(x: x + 0.5 * s, y: y), height: (tie.up ? -1 : 1) * 0.6 * s, thickness: 0.18 * s, owner: tie.owner))
        }
        if openSlur != nil { openSlur!.from = CGPoint(x: x - 0.5 * s, y: sys.staffTop + openSlur!.from.y) }
        if openWedge != nil { openWedge!.x = x }

        for i in sys.measures {
            let mm = metrics[i]
            let width = mm.fixed + mm.spring * k + (i == first ? 0 : mm.change)
            drawMeasure(i, x: x, width: width, stretch: k, sys: sys, sysIndex: sysIndex, isLineStart: i == first)
            x += width
        }

        // Close what runs past the line end.
        let end = sys.x1
        let pendingTies = openTies
        openTies = []
        for tie in pendingTies {
            out.append(.curve(from: tie.from, to: CGPoint(x: end - 0.3 * s, y: tie.from.y), height: (tie.up ? -1 : 1) * 0.6 * s, thickness: 0.18 * s, owner: tie.owner))
            openTies.append((CGPoint(x: 0, y: tie.from.y - sys.staffTop), tie.up, tie.owner))
        }
        if let slur = openSlur {
            out.append(.curve(from: slur.from, to: CGPoint(x: end - 0.3 * s, y: slur.from.y), height: (slur.above ? -1 : 1) * 1.2 * s, thickness: 0.2 * s, owner: slur.owner))
            openSlur!.from.y -= sys.staffTop
        }
        if let w = openWedge { drawWedge(w.kind, from: w.x, to: end - 0.5 * s, sys: sys) }
        flush()
    }

    func drawClef(_ c: Clef, x: CGFloat, sys: SystemGeometry, small: Bool) {
        let glyph: Character = switch c.sign {
        case .g: c.octaveChange == -1 ? SMuFL.gClef8vb : SMuFL.gClef
        case .f: SMuFL.fClef
        case .c, .percussion: SMuFL.cClef
        }
        let y = sys.y(ofStep: (c.line - 1) * 2)
        outAppend(.glyph(String(glyph), at: CGPoint(x: x, y: y), size: 4 * s * (small ? 0.75 : 1), centered: false, owner: nil))
    }

    func drawKey(_ key: KeySignature, clef: Clef, x: CGFloat, sys: SystemGeometry) {
        let glyph = key.fifths > 0 ? SMuFL.sharp : SMuFL.flat
        for (n, step) in clef.keySignatureSteps(key).enumerated() {
            outAppend(.glyph(String(glyph), at: CGPoint(x: x + CGFloat(n) * 1.0 * s, y: sys.y(ofStep: step)), size: 4 * s, centered: false, owner: nil))
        }
    }

    func drawTime(_ t: TimeSignature, x: CGFloat, sys: SystemGeometry) {
        let mid = sys.y(ofStep: 4)
        switch t.symbol {
        case .common: outAppend(.glyph(String(SMuFL.timeSigCommon), at: CGPoint(x: x + 1 * s, y: mid), size: 4 * s, centered: true, owner: nil))
        case .cut: outAppend(.glyph(String(SMuFL.timeSigCut), at: CGPoint(x: x + 1 * s, y: mid), size: 4 * s, centered: true, owner: nil))
        case .normal:
            let digits: (Int) -> String = { String(String($0).compactMap { Int(String($0)) }.map { SMuFL.timeSigDigit($0) }) }
            outAppend(.glyph(digits(t.beats), at: CGPoint(x: x + 1 * s, y: sys.y(ofStep: 6)), size: 4 * s, centered: true, owner: nil))
            outAppend(.glyph(digits(t.beatType), at: CGPoint(x: x + 1 * s, y: sys.y(ofStep: 2)), size: 4 * s, centered: true, owner: nil))
        }
    }

    // `out` is mutated from non-mutating helpers through this box-free shim.
    private func outAppend(_ p: Primitive) { pending.append(p) }
    private let pending = PrimitiveSink()

    mutating func flush() {
        out.append(contentsOf: pending.items)
        pending.items.removeAll()
    }

    // MARK: Measures

    mutating func drawMeasure(_ i: Int, x mx: CGFloat, width: CGFloat, stretch k: CGFloat, sys: SystemGeometry, sysIndex: Int, isLineStart: Bool) {
        let m = part.measures[i]
        var x = mx
        var clef = resolved[i].clef

        if m.barline == .repeatStart || m.barline == .repeatBoth {
            let bx = x + 0.2 * s
            out.append(.line(from: CGPoint(x: bx, y: sys.staffTop), to: CGPoint(x: bx, y: sys.staffTop + 4 * s), width: 0.5 * s, owner: nil))
            out.append(.line(from: CGPoint(x: bx + 0.65 * s, y: sys.staffTop), to: CGPoint(x: bx + 0.65 * s, y: sys.staffTop + 4 * s), width: 0.16 * s, owner: nil))
            outAppend(.glyph(String(SMuFL.repeatDots), at: CGPoint(x: bx + 1.0 * s, y: sys.y(ofStep: 0)), size: 4 * s, centered: false, owner: nil))
            x += 1.2 * s
        }

        // Mid-piece changes of clef, key and meter.
        if !isLineStart, i > 0, let a = m.attributes {
            if let c = a.clef { drawClef(c, x: x + 0.2 * s, sys: sys, small: true); x += 2.6 * s }
            if let kk = a.key, kk != resolved[i - 1].key {
                if kk.fifths == 0 {
                    // Cancel the old signature with naturals.
                    for (n, step) in clef.keySignatureSteps(resolved[i - 1].key).enumerated() {
                        outAppend(.glyph(String(SMuFL.natural), at: CGPoint(x: x + CGFloat(n) * 0.8 * s, y: sys.y(ofStep: step)), size: 4 * s, centered: false, owner: nil))
                    }
                    x += CGFloat(abs(resolved[i - 1].key.fifths)) * 0.8 * s
                } else {
                    drawKey(kk, clef: clef, x: x, sys: sys)
                    x += keyWidth(kk)
                }
            }
            if let t = a.time { drawTime(t, x: x, sys: sys); x += timeW() }
        }
        let contentX = x
        x += 1.2 * s

        // Tempo marking above the first beat.
        if let tempo = m.attributes?.tempo { drawTempo(tempo, x: x, sys: sys) }

        var itemX: [Int: CGFloat] = [:]
        var pendingDirections: [MeasureItem] = []
        var placed: [(note: NoteEvent, x: CGFloat, up: Bool)] = []
        let beamGroups = self.beamGroups(m, time: resolved[i].time)
        let groupOf: [UUID: Int] = Dictionary(uniqueKeysWithValues: beamGroups.enumerated().flatMap { gi, g in g.map { ($0, gi) } })
        let groupUp: [Int: Bool] = Dictionary(uniqueKeysWithValues: beamGroups.enumerated().map { gi, g in
            let notes = m.notes.filter { g.contains($0.id) }
            return (gi, stemUp(notes.flatMap(\.pitches).map { clef.staffStep(of: $0) }))
        })

        for (ii, item) in m.items.enumerated() {
            switch item {
            case .clef(let c):
                drawClef(c, x: x, sys: sys, small: true)
                clef = c
                itemX[ii] = x
                x += 2.4 * s
            case .note(let n):
                if n.isMeasureRest {
                    let cx = mx + width / 2
                    outAppend(.glyph(String(SMuFL.rest(.whole)), at: CGPoint(x: cx, y: sys.y(ofStep: 6)), size: 4 * s, centered: true, owner: n.id))
                    noteFrames[n.id] = CGRect(x: cx - s, y: sys.y(ofStep: 6), width: 2 * s, height: s)
                    itemX[ii] = cx
                    placeDirections(&pendingDirections, x: x, sys: sys, itemX: &itemX)
                    x += spring(n) * k
                    continue
                }
                let accW = fixedWidth(n, measure: i) - CGFloat(n.duration.dots) * 0.6 * s - (n.pitches.count > 1 && hasSecond(n.pitches) ? 1.2 * s : 0)
                let noteX = x + accW
                itemX[ii] = noteX
                placeDirections(&pendingDirections, x: noteX, sys: sys, itemX: &itemX)
                let up = groupOf[n.id].flatMap { groupUp[$0] } ?? stemUp(n.pitches.map { clef.staffStep(of: $0) })
                drawNote(n, x: noteX, clef: clef, up: up, beamed: groupOf[n.id] != nil, accidentals: accidentals[i]?[n.id] ?? [:], sys: sys)
                placed.append((n, noteX, up))
                x = noteX + fixedWidth(n, measure: i) - accW + spring(n) * k
            default:
                pendingDirections.append(item)
            }
        }
        if !pendingDirections.isEmpty { placeDirections(&pendingDirections, x: x - 2 * s, sys: sys, itemX: &itemX) }

        for g in beamGroups { drawBeam(g, placed: placed, clef: clef, sys: sys, measureClef: resolved[i].clef, measure: m) }
        drawTuplets(placed, clef: clef, sys: sys)
        drawTiesAndSlurs(placed, clef: clef, sys: sys)

        // Barline.
        let bx = mx + width
        let top = sys.staffTop, bottom = sys.staffTop + 4 * s
        switch m.barline {
        case .regular, .repeatStart:
            out.append(.line(from: CGPoint(x: bx, y: top), to: CGPoint(x: bx, y: bottom), width: 0.16 * s, owner: nil))
        case .double:
            out.append(.line(from: CGPoint(x: bx - 0.5 * s, y: top), to: CGPoint(x: bx - 0.5 * s, y: bottom), width: 0.16 * s, owner: nil))
            out.append(.line(from: CGPoint(x: bx, y: top), to: CGPoint(x: bx, y: bottom), width: 0.16 * s, owner: nil))
        case .final, .repeatEnd, .repeatBoth:
            if m.barline != .final {
                outAppend(.glyph(String(SMuFL.repeatDots), at: CGPoint(x: bx - 1.75 * s, y: sys.y(ofStep: 0)), size: 4 * s, centered: false, owner: nil))
            }
            out.append(.line(from: CGPoint(x: bx - 0.75 * s, y: top), to: CGPoint(x: bx - 0.75 * s, y: bottom), width: 0.16 * s, owner: nil))
            out.append(.line(from: CGPoint(x: bx - 0.25 * s, y: top), to: CGPoint(x: bx - 0.25 * s, y: bottom), width: 0.5 * s, owner: nil))
        }

        measureGeos.append(MeasureGeometry(index: i, system: sysIndex,
                                           frame: CGRect(x: mx, y: sys.band.lowerBound, width: width, height: sys.band.upperBound - sys.band.lowerBound),
                                           contentX: contentX, itemX: itemX, clef: resolved[i].clef))
        flush()
    }

    mutating func placeDirections(_ items: inout [MeasureItem], x: CGFloat, sys: SystemGeometry, itemX: inout [Int: CGFloat]) {
        let below = sys.staffTop + 4 * s + 3.2 * s
        var dx: CGFloat = 0
        for item in items {
            switch item {
            case .dynamic(let d):
                outAppend(.glyph(SMuFL.dynamic(d), at: CGPoint(x: x - 0.3 * s + dx, y: below), size: 4 * s, centered: false, owner: nil))
                dx += CGFloat(d.rawValue.count) * 1.1 * s + 0.6 * s
            case .wedge(let w):
                if w == .stop {
                    if let open = openWedge { drawWedge(open.kind, from: open.x, to: x, sys: sys) }
                    openWedge = nil
                } else {
                    if let open = openWedge { drawWedge(open.kind, from: open.x, to: x, sys: sys) }
                    openWedge = (x + dx, w)
                }
            case .tempo(let t):
                drawTempo(t, x: x, sys: sys)
            case .text(let str):
                outAppend(.text(str, at: CGPoint(x: x, y: sys.staffTop - 2.5 * s), size: 1.5 * s, style: .italic, anchor: .left))
            default: break
            }
        }
        items.removeAll()
    }

    func drawWedge(_ kind: Wedge, from x0: CGFloat, to x1: CGFloat, sys: SystemGeometry) {
        guard x1 - x0 > 3 * s else { return }
        let y = sys.staffTop + 4 * s + 2.4 * s
        let open: CGFloat = 0.75 * s
        let (wideX, pointX) = kind == .crescendo ? (x1, x0) : (x0, x1)
        outAppend(.line(from: CGPoint(x: pointX, y: y), to: CGPoint(x: wideX, y: y - open), width: 0.12 * s, owner: nil))
        outAppend(.line(from: CGPoint(x: pointX, y: y), to: CGPoint(x: wideX, y: y + open), width: 0.12 * s, owner: nil))
    }

    func drawTempo(_ t: Tempo, x: CGFloat, sys: SystemGeometry) {
        let y = sys.band.lowerBound + 2.4 * s
        var cx = x - 1 * s
        if let text = t.text, !text.isEmpty {
            outAppend(.text(text, at: CGPoint(x: cx, y: y), size: 1.7 * s, style: .bold, anchor: .left))
            cx += CGFloat(text.count) * 0.95 * s + 1.2 * s
        }
        let note: Character = switch t.beatUnit.kind {
        case .half: SMuFL.metNoteHalfUp
        case .eighth: SMuFL.metNote8thUp
        default: SMuFL.metNoteQuarterUp
        }
        let dots = String(repeating: " " + String(SMuFL.metAugmentationDot), count: t.beatUnit.dots)
        outAppend(.glyph(String(note) + dots, at: CGPoint(x: cx, y: y), size: 2.6 * s, centered: false, owner: nil))
        outAppend(.text("= \(Int(t.bpm.rounded()))", at: CGPoint(x: cx + 1.4 * s + CGFloat(t.beatUnit.dots) * 0.8 * s, y: y), size: 1.6 * s, style: .regular, anchor: .left))
    }

    // MARK: Notes

    /// Stems go away from the middle line, decided by the note furthest from it; a note on the middle line
    /// (or a group balanced around it) takes a down stem, as engravers do.
    func stemUp(_ steps: [Int]) -> Bool {
        guard let hi = steps.max(), let lo = steps.min() else { return true }
        return (hi - 4) < (4 - lo)
    }

    func hasSecond(_ pitches: [Pitch]) -> Bool {
        zip(pitches, pitches.dropFirst()).contains { $1.diatonic - $0.diatonic == 1 }
    }

    mutating func drawNote(_ n: NoteEvent, x: CGFloat, clef: Clef, up: Bool, beamed: Bool, accidentals acc: [Int: Accidental], sys: SystemGeometry) {
        let scale: CGFloat = n.isGrace ? 0.65 : 1
        let size = 4 * s * scale
        let headW = CGFloat(SMuFL.noteheadWidth(n.duration.kind)) * s * scale

        if n.isRest {
            let step = n.duration.kind == .whole ? 6 : 4
            let y = sys.y(ofStep: step)
            outAppend(.glyph(String(SMuFL.rest(n.duration.kind)), at: CGPoint(x: x, y: y), size: size, centered: false, owner: n.id))
            noteFrames[n.id] = CGRect(x: x, y: sys.staffTop + s, width: headW + 0.3 * s, height: 2 * s)
            drawDots(n, x: x + headW, step: 5, sys: sys)
            return
        }

        let steps = n.pitches.map { clef.staffStep(of: $0) }
        var frame = CGRect.null
        // Heads: seconds in a chord sit on the other side of the stem.
        var previousOffset = false
        for (pi, step) in steps.enumerated() {
            var hx = x
            if pi > 0, steps[pi] - steps[pi - 1] == 1, !previousOffset {
                hx += up ? headW - 0.1 * s : -(headW - 0.1 * s)
                previousOffset = true
            } else {
                previousOffset = false
            }
            let y = sys.y(ofStep: step)
            outAppend(.glyph(String(SMuFL.notehead(n.duration.kind, harmonic: n.harmonic)), at: CGPoint(x: hx, y: y), size: size, centered: false, owner: n.id))
            frame = frame.union(CGRect(x: hx, y: y - 0.5 * s, width: headW, height: s))
            // Ledger lines.
            if step < -1 || step > 9 {
                let range = step < 0 ? Array(stride(from: -2, through: step, by: -2)) : Array(stride(from: 10, through: step, by: 2))
                for ls in range {
                    let ly = sys.y(ofStep: ls)
                    out.append(.line(from: CGPoint(x: hx - 0.4 * s, y: ly), to: CGPoint(x: hx + headW + 0.4 * s, y: ly), width: 0.16 * s, owner: nil))
                }
            }
        }
        noteFrames[n.id] = frame

        // Accidentals, stacked into columns when a chord needs several.
        var column = 0
        for (pi, a) in acc.sorted(by: { $0.key > $1.key }) {
            let w = CGFloat(SMuFL.accidentalWidth(a)) * s * scale
            let ax = x - w - 0.25 * s - CGFloat(column) * 1.1 * s
            outAppend(.glyph(String(SMuFL.accidental(a)), at: CGPoint(x: ax, y: sys.y(ofStep: steps[pi])), size: size, centered: false, owner: n.id))
            column = (column + 1) % 2
        }

        // Stem and flag.
        if n.duration.kind.hasStem {
            let hi = steps.max()!, lo = steps.min()!
            let stemX = up ? x + headW - 0.06 * s : x + 0.06 * s
            let startY = sys.y(ofStep: up ? lo : hi) + (up ? -0.17 : 0.17) * s
            var endStep = up ? hi + 7 : lo - 7
            // Notes far outside the staff get stems reaching the middle line.
            if up && endStep < 4 { endStep = 4 }
            if !up && endStep > 4 { endStep = 4 }
            let endY = sys.y(ofStep: endStep) + (n.isGrace ? (up ? 1.2 : -1.2) * s : 0)
            if !beamed {
                out.append(.line(from: CGPoint(x: stemX, y: startY), to: CGPoint(x: stemX, y: endY), width: 0.12 * s, owner: n.id))
                if let flag = SMuFL.flag(beams: n.duration.kind.beams, up: up) {
                    outAppend(.glyph(String(flag), at: CGPoint(x: stemX - 0.06 * s, y: endY), size: size, centered: false, owner: n.id))
                }
                if n.isGrace, n.duration.kind.beams > 0 {
                    // Acciaccatura slash.
                    out.append(.line(from: CGPoint(x: stemX - 0.6 * s, y: startY + (up ? -0.8 : 0.8) * s),
                                     to: CGPoint(x: stemX + 0.9 * s, y: startY + (up ? -2.2 : 2.2) * s), width: 0.1 * s, owner: n.id))
                }
            }
        }

        drawDots(n, x: x + headW, steps: steps, sys: sys)

        // Articulations on the notehead side away from the stem; fermata above the staff.
        let headSideAbove = !up
        var markStep = headSideAbove ? max(steps.max()! + 2, 4) : min(steps.min()! - 2, 4)
        for art in n.articulations.sorted(by: { $0.rawValue < $1.rawValue }) where art != .fermata {
            guard let g = SMuFL.articulation(art, above: headSideAbove) else { continue }
            // Keep dots off staff lines.
            if markStep % 2 == 0, markStep >= 0, markStep <= 8 { markStep += headSideAbove ? 1 : -1 }
            outAppend(.glyph(String(g), at: CGPoint(x: x + headW / 2, y: sys.y(ofStep: markStep)), size: size, centered: true, owner: n.id))
            markStep += headSideAbove ? 2 : -2
        }

        // Above the staff: fermata, bowing, string, fingering — stacked upwards.
        // Each mark's baseline is `aboveY`; it then moves up by the mark's height.
        var aboveY = min(sys.staffTop - 1.0 * s, sys.y(ofStep: steps.max()! + (up ? 7 : 0)) - 1.0 * s)
        if headSideAbove, n.articulations.contains(where: { $0 != .fermata }) { aboveY = min(aboveY, sys.y(ofStep: markStep) - 0.4 * s) }
        if n.articulations.contains(.fermata) {
            outAppend(.glyph(String(SMuFL.fermataAbove), at: CGPoint(x: x + headW / 2, y: aboveY), size: size, centered: true, owner: n.id))
            aboveY -= 2 * s
        }
        if let b = n.bowing {
            outAppend(.glyph(String(b == .down ? SMuFL.downBow : SMuFL.upBow), at: CGPoint(x: x + headW / 2, y: aboveY), size: size, centered: true, owner: n.id))
            aboveY -= (b == .down ? 1.8 : 2.7) * s
        }
        if !n.fingerings.isEmpty {
            let text = n.fingerings.map { $0 == 5 ? "T" : "\($0)" }.joined(separator: "\n")
            outAppend(.text(text, at: CGPoint(x: x + headW / 2, y: aboveY), size: 1.4 * s, style: .bold, anchor: .center))
            aboveY -= 1.4 * s * CGFloat(n.fingerings.count) + 0.2 * s
        }
        if let st = n.string {
            outAppend(.text(st.roman, at: CGPoint(x: x + headW / 2, y: aboveY), size: 1.3 * s, style: .regular, anchor: .center))
        }
    }

    func drawDots(_ n: NoteEvent, x: CGFloat, step: Int? = nil, steps: [Int] = [], sys: SystemGeometry) {
        guard n.duration.dots > 0 else { return }
        let rows = step.map { [$0] } ?? steps.map { $0 % 2 == 0 ? $0 + 1 : $0 }
        for row in Set(rows) {
            for d in 0..<n.duration.dots {
                outAppend(.glyph(String(SMuFL.augmentationDot), at: CGPoint(x: x + 0.4 * s + CGFloat(d) * 0.55 * s, y: sys.y(ofStep: row)),
                                 size: 4 * s, centered: false, owner: n.id))
            }
        }
    }

    // MARK: Beams

    /// Groups of consecutive eighth-or-shorter notes inside one beat (a dotted-quarter beat in compound
    /// meter; the whole bar in 3/8 and 2/8), the grouping that shows the meter.
    func beamGroups(_ m: Measure, time: TimeSignature) -> [[UUID]] {
        let unit: Fraction = time.beatType >= 8 && !time.isCompound ? time.measureDuration : time.beatDuration
        var groups: [[UUID]] = []
        var current: [UUID] = []
        var position = Fraction.zero
        var currentBeat = -1
        func close() { if current.count > 1 { groups.append(current) }; current = [] }
        for n in m.notes where !n.isGrace {
            let beat = Int((position / unit).double.rounded(.down) + 1e-9)
            if n.isRest || n.duration.kind.beams == 0 || beat != currentBeat { close() }
            if !n.isRest, n.duration.kind.beams > 0 { current.append(n.id) }
            currentBeat = beat
            position += n.duration.value
            // A group ends where its beat does.
            if (position / unit).double.truncatingRemainder(dividingBy: 1) < 1e-9 { close(); currentBeat = -1 }
        }
        close()
        return groups
    }

    mutating func drawBeam(_ ids: [UUID], placed: [(note: NoteEvent, x: CGFloat, up: Bool)], clef: Clef, sys: SystemGeometry, measureClef: Clef, measure: Measure) {
        let items = placed.filter { ids.contains($0.note.id) }
        guard items.count > 1, let up = items.first?.up else { return }
        let headW = CGFloat(SMuFL.noteheadWidth(.quarter)) * s
        // Each note's own clef (a mid-measure change can split a group's clefs).
        func steps(_ n: NoteEvent) -> [Int] { n.pitches.map { clefFor(n.id, in: measure, start: measureClef).staffStep(of: $0) } }
        let stems = items.map { item -> (x: CGFloat, head: CGFloat, natural: CGFloat) in
            let st = steps(item.note)
            let x = up ? item.x + headW - 0.06 * s : item.x + 0.06 * s
            let head = sys.y(ofStep: up ? st.min()! : st.max()!)
            let tip = sys.y(ofStep: up ? st.max()! + 7 : st.min()! - 7)
            return (x, head, tip)
        }
        let first = stems.first!, last = stems.last!
        var slope = (last.natural - first.natural) / max(last.x - first.x, 1)
        slope = max(-0.25, min(0.25, slope))
        // Shift the beam so the shortest stem is still 3 spaces from its outermost head.
        var offset: CGFloat = 0
        for st in stems {
            let beamY = first.natural + slope * (st.x - first.x)
            let length = up ? st.head - beamY : beamY - st.head
            let minLength = 3.0 * s
            if length < minLength { offset = up ? min(offset, -(minLength - length)) : max(offset, minLength - length) }
        }
        func beamY(_ x: CGFloat) -> CGFloat { first.natural + offset + slope * (x - first.x) }

        for (k, st) in stems.enumerated() {
            out.append(.line(from: CGPoint(x: st.x, y: st.head + (up ? -0.17 : 0.17) * s), to: CGPoint(x: st.x, y: beamY(st.x)), width: 0.12 * s, owner: items[k].note.id))
        }
        let thick = 0.5 * s
        let gap = 0.75 * s
        let maxLevel = items.map { $0.note.duration.kind.beams }.max() ?? 1
        for level in 1...maxLevel {
            let dy = CGFloat(level - 1) * gap * (up ? 1 : -1)
            var k = 0
            while k < items.count {
                guard items[k].note.duration.kind.beams >= level else { k += 1; continue }
                var e = k
                while e + 1 < items.count, items[e + 1].note.duration.kind.beams >= level { e += 1 }
                var x0 = stems[k].x, x1 = stems[e].x
                if k == e {
                    // A lone shorter note gets a stub pointing into the group.
                    if k == items.count - 1 { x0 = x1 - 1.1 * s } else { x1 = x0 + 1.1 * s }
                }
                let y0 = beamY(x0) + dy, y1 = beamY(x1) + dy
                let t = up ? thick : -thick
                out.append(.polygon([CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x1, y: y1 + t), CGPoint(x: x0, y: y0 + t)], owner: items[k].note.id))
                k = e + 1
            }
        }
    }

    func clefFor(_ id: UUID, in m: Measure, start: Clef) -> Clef {
        var c = start
        for item in m.items {
            if case .clef(let cc) = item { c = cc }
            if item.note?.id == id { return c }
        }
        return c
    }

    // MARK: Tuplets, ties, slurs

    mutating func drawTuplets(_ placed: [(note: NoteEvent, x: CGFloat, up: Bool)], clef: Clef, sys: SystemGeometry) {
        var k = 0
        while k < placed.count {
            guard let t = placed[k].note.duration.tuplet else { k += 1; continue }
            let end = min(k + t.actual, placed.count) - 1
            let group = placed[k...end]
            let above = !(group.first?.up ?? true) ? false : true
            let steps = group.flatMap { $0.note.pitches.map { clef.staffStep(of: $0) } }
            let y = above ? min(sys.staffTop - 0.8 * s, sys.y(ofStep: (steps.max() ?? 8) + 8)) : max(sys.staffTop + 5 * s, sys.y(ofStep: (steps.min() ?? 0) - 8))
            let cx = ((group.first?.x ?? 0) + (group.last?.x ?? 0)) / 2 + 0.6 * s
            outAppend(.text("\(t.actual)", at: CGPoint(x: cx, y: y), size: 1.4 * s, style: .italic, anchor: .center))
            k = end + 1
        }
        flush()
    }

    mutating func drawTiesAndSlurs(_ placed: [(note: NoteEvent, x: CGFloat, up: Bool)], clef: Clef, sys: SystemGeometry) {
        let headW = CGFloat(SMuFL.noteheadWidth(.quarter)) * s
        // Ties that came from the previous measure end on this measure's first note.
        if !openTies.isEmpty, let first = placed.first, openTies.allSatisfy({ $0.from.x > 0 }) {
            for tie in openTies {
                out.append(.curve(from: tie.from, to: CGPoint(x: first.x - 0.2 * s, y: tie.from.y), height: (tie.up ? -1 : 1) * 0.6 * s, thickness: 0.18 * s, owner: tie.owner))
            }
            openTies = []
        } else if !openTies.isEmpty, let first = placed.first {
            // Continuation after a line break: already drawn from the line start.
            _ = first
            openTies = []
        }
        for (k, p) in placed.enumerated() {
            let steps = p.note.pitches.map { clef.staffStep(of: $0) }
            if p.note.tieToNext {
                for st in steps {
                    let below = p.up
                    let y = sys.y(ofStep: st) + (below ? 0.6 : -0.6) * s
                    let from = CGPoint(x: p.x + headW + 0.15 * s, y: y)
                    if k + 1 < placed.count {
                        out.append(.curve(from: from, to: CGPoint(x: placed[k + 1].x - 0.15 * s, y: y), height: (below ? 1 : -1) * 0.6 * s, thickness: 0.18 * s, owner: p.note.id))
                    } else {
                        openTies.append((from, !below, p.note.id))
                    }
                }
            }
            if p.note.slurStart && !p.note.slurStop {
                let above = !p.up
                let st = above ? (steps.max() ?? 4) + 2 : (steps.min() ?? 4) - 2
                openSlur = (CGPoint(x: p.x + headW / 2, y: sys.y(ofStep: st)), above, p.note.id)
            } else if p.note.slurStop, let slur = openSlur {
                let st = slur.above ? (steps.max() ?? 4) + 2 : (steps.min() ?? 4) - 2
                let to = CGPoint(x: p.x + headW / 2, y: sys.y(ofStep: st))
                let y = slur.above ? min(slur.from.y, to.y) : max(slur.from.y, to.y)
                out.append(.curve(from: CGPoint(x: slur.from.x, y: slur.from.x < to.x ? slur.from.y : y), to: to,
                                  height: (slur.above ? -1 : 1) * min(2 * s, 0.8 * s + (to.x - slur.from.x) * 0.04), thickness: 0.2 * s, owner: slur.owner))
                openSlur = nil
            }
        }
    }
}

/// Lets non-mutating helpers queue primitives; flushed into the output in order.
private final class PrimitiveSink: @unchecked Sendable {
    var items: [Primitive] = []
    func append(_ p: Primitive) { items.append(p) }
}
