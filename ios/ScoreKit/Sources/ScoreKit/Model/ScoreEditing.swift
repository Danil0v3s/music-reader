import Foundation

/// Points at one item in a part: the editor's cursor and selection.
public struct ItemPath: Hashable, Codable, Sendable {
    public var measure: Int
    public var item: Int
    public init(measure: Int, item: Int) { self.measure = measure; self.item = item }
}

extension Part {
    /// Attributes in force at the start of measure `index` (every earlier change applied, including clef
    /// changes made mid-measure in earlier bars).
    public func attributes(at index: Int) -> ResolvedAttributes {
        guard measures.indices.contains(index) else { return resolvedAttributes.last ?? .initial }
        return resolvedAttributes[index]
    }

    /// Attributes in force at the start of every measure, computed in one pass.
    public var resolvedAttributes: [ResolvedAttributes] {
        var a = ResolvedAttributes.initial
        return measures.map { m in
            a = a.applying(m.attributes)
            let atStart = a
            for item in m.items { if case .clef(let c) = item { a.clef = c } }
            return atStart
        }
    }

    /// The clef in force just before item `item` of measure `index`, counting mid-measure clef changes.
    public func clef(at path: ItemPath) -> Clef {
        var clef = attributes(at: path.measure).clef
        for item in measures[path.measure].items.prefix(path.item) { if case .clef(let c) = item { clef = c } }
        return clef
    }

    public func note(at path: ItemPath) -> NoteEvent? {
        guard measures.indices.contains(path.measure), measures[path.measure].items.indices.contains(path.item) else { return nil }
        return measures[path.measure].items[path.item].note
    }

    public func path(of noteId: UUID) -> ItemPath? {
        for (mi, m) in measures.enumerated() {
            if let ii = m.items.firstIndex(where: { $0.note?.id == noteId }) { return ItemPath(measure: mi, item: ii) }
        }
        return nil
    }

    /// Inserts a note at `path` (before the item there, or at the end). A measure holding only a full-measure
    /// rest gives it up to the first note. Returns the path of the inserted note.
    @discardableResult
    public mutating func insert(_ note: NoteEvent, at path: ItemPath) -> ItemPath {
        var m = measures[path.measure]
        var index = min(path.item, m.items.count)
        if m.notes.count == 1, m.notes[0].isMeasureRest, let restIndex = m.items.firstIndex(where: { $0.note?.isMeasureRest == true }) {
            m.items.remove(at: restIndex)
            if restIndex < index { index -= 1 }
        }
        m.items.insert(.note(note), at: index)
        measures[path.measure] = m
        return ItemPath(measure: path.measure, item: index)
    }

    public mutating func replace(at path: ItemPath, with note: NoteEvent) {
        guard self.note(at: path) != nil else { return }
        measures[path.measure].items[path.item] = .note(note)
    }

    /// Removes an item; a measure left empty gets its whole-measure rest back.
    public mutating func remove(at path: ItemPath) {
        guard measures.indices.contains(path.measure), measures[path.measure].items.indices.contains(path.item) else { return }
        measures[path.measure].items.remove(at: path.item)
        if measures[path.measure].notes.isEmpty {
            measures[path.measure].items.append(.note(NoteEvent(rest: .whole, measureRest: true)))
        }
    }

    /// Pads an underfull measure with rests (largest values first) so it adds up to the meter.
    public mutating func fillWithRests(measure index: Int) {
        let time = attributes(at: index).time
        guard case .underfull(let missing) = measures[index].fill(in: time) else { return }
        for d in NoteValue.decompose(missing) { measures[index].items.append(.note(NoteEvent(rest: d))) }
    }

    public mutating func appendMeasure() {
        var m = Measure(number: (measures.last?.number ?? 0) + 1)
        m.items = [.note(NoteEvent(rest: .whole, measureRest: true))]
        measures.append(m)
    }

    public mutating func insertMeasure(at index: Int) {
        var m = Measure(number: 0)
        m.items = [.note(NoteEvent(rest: .whole, measureRest: true))]
        measures.insert(m, at: min(index, measures.count))
        renumber()
    }

    /// Deletes a measure, moving its attribute changes to the next one so the rest of the piece keeps its clef, key and meter.
    public mutating func removeMeasure(at index: Int) {
        guard measures.count > 1, measures.indices.contains(index) else { return }
        let removed = measures.remove(at: index)
        if let attrs = removed.attributes, index < measures.count {
            var next = measures[index].attributes ?? MeasureAttributes()
            next.clef = next.clef ?? attrs.clef
            next.key = next.key ?? attrs.key
            next.time = next.time ?? attrs.time
            next.tempo = next.tempo ?? attrs.tempo
            measures[index].attributes = next
        }
        renumber()
    }

    public mutating func renumber() {
        let pickup = measures.first?.isPickup == true
        for i in measures.indices { measures[i].number = pickup ? i : i + 1 }
    }

    /// Sets a clef/key/meter/tempo change at a measure. Passing a value equal to what's already in force removes the change.
    public mutating func setAttributes(at index: Int, _ change: (inout MeasureAttributes) -> Void) {
        var a = measures[index].attributes ?? MeasureAttributes()
        change(&a)
        if index > 0 {
            let before = attributes(at: index - 1)
            if a.clef == before.clef { a.clef = nil }
            if a.key == before.key { a.key = nil }
            if a.time == before.time { a.time = nil }
            if a.tempo == before.tempo { a.tempo = nil }
        }
        measures[index].attributes = a.isEmpty ? nil : a
    }
}

extension NoteEvent {
    /// Moves every pitch by letter steps (the editor's up/down arrows), re-applying the key signature so
    /// the result stays in key: in D major, F♯ up a step is G, up again A.
    public func movedDiatonically(_ steps: Int, in key: KeySignature) -> NoteEvent {
        var n = self
        n.pitches = pitches.map { p in
            let moved = p.movedDiatonically(steps)
            return Pitch(moved.step, moved.octave, alter: key.alter(for: moved.step))
        }
        n.forcedAccidentals = []
        return n
    }

    /// Raises or lowers every pitch's alteration by one (sharpen / flatten), clamped to double accidentals.
    public func altered(by delta: Int) -> NoteEvent {
        var n = self
        n.pitches = pitches.map { Pitch($0.step, $0.octave, alter: $0.alter + delta) }
        return n
    }

    /// Transposes by semitones, spelling the result in `key`.
    public func transposed(semitones: Int, in key: KeySignature) -> NoteEvent {
        var n = self
        n.pitches = pitches.map { Pitch(midi: $0.midi + semitones, in: key) }
        n.forcedAccidentals = []
        return n
    }
}
