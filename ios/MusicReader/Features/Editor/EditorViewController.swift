import ScoreKit
import UIKit

/// Writing and correcting a score. Tap the staff to put a note there; tap a note to select it, then
/// use the palette. Bars that don't add up to the meter are tinted (orange short, red too long).
final class EditorViewController: UIViewController {
    private var score: Score
    private let original: Score
    private let library: ScoreLibrary
    private let settings: SettingsStore
    private let player: ScorePlayer

    private let scroll = UIScrollView()
    private let scoreView = ScoreView()
    private let palette = EditorPalette()

    private var selection: UUID? { didSet { scoreView.selectedNote = selection; refreshPalette() } }
    private var caret = ItemPath(measure: 0, item: 0) { didSet { scoreView.caret = caret; refreshPalette() } }
    private var input = NoteValue(.quarter)
    private var restMode = false

    private var undoStack: [Score] = []
    private var redoStack: [Score] = []
    private var barItem: UIBarButtonItem!

    private var part: Part {
        get { score.parts[0] }
        set { score.parts[0] = newValue }
    }

    init(score: Score, library: ScoreLibrary, settings: SettingsStore, player: ScorePlayer) {
        self.score = score
        self.original = score
        self.library = library
        self.settings = settings
        self.player = player
        super.init(nibName: nil, bundle: nil)
        title = score.title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.save() })
        done.style = .prominent
        barItem = UIBarButtonItem(title: "Bar", menu: barMenu())
        navigationItem.rightBarButtonItems = [done, barItem]
        navigationItem.titleMenuProvider = { [weak self] _ in self?.titleMenu() }

        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.addSubview(scoreView)
        view.addSubview(palette)
        [scroll, scoreView, palette].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: palette.topAnchor),
            scoreView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            scoreView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            scoreView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scoreView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            scoreView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            palette.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            palette.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            palette.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // A little larger than reading size: easier to hit lines and spaces.
        scoreView.staffSpace = max(9, settings.value.staffSpace + 1)
        scoreView.showHeader = false
        scoreView.score = score
        scoreView.onTap = { [weak self] hit, _ in self?.tapped(hit) }
        palette.delegate = self
        caret = ItemPath(measure: 0, item: 0)
        refresh()
    }

    // MARK: State

    private func change(_ edit: (inout Score) -> Void) {
        undoStack.append(score)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        edit(&score)
        refresh()
    }

    private func refresh() {
        scoreView.score = score
        var tints: [Int: UIColor] = [:]
        let attrs = part.resolvedAttributes
        for (i, m) in part.measures.enumerated() {
            switch m.fill(in: attrs[i].time) {
            case .complete: break
            case .underfull: tints[i] = .systemOrange
            case .overfull: tints[i] = .systemRed
            }
        }
        scoreView.measureTints = tints
        scoreView.caret = caret
        scoreView.selectedNote = selection
        palette.setUndo(canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty)
        barItem.menu = barMenu()
        refreshPalette()
    }

    private func refreshPalette() {
        let note = selection.flatMap { id in part.path(of: id).flatMap { part.note(at: $0) } }
        let m = min(caret.measure, part.measures.count - 1)
        let time = part.attributes(at: m).time
        let measure = part.measures[m]
        let status: String
        switch measure.fill(in: time) {
        case .complete: status = "Bar \(measure.number) · complete"
        case .underfull(let missing): status = "Bar \(measure.number) · \(Self.describe(missing)) still to write"
        case .overfull(let excess): status = "Bar \(measure.number) · \(Self.describe(excess)) too long for \(time)"
        }
        var detail = ""
        if let note {
            detail = note.isRest ? "Rest · \(note.duration)" : note.pitches.map(\.description).joined(separator: " + ") + " · \(note.duration)"
        }
        palette.update(input: input, rest: restMode, selected: note, status: status, detail: detail)
    }

    /// "1/2 beat"-style wording for a gap, in quarter-note beats.
    static func describe(_ f: Fraction) -> String {
        let beats = f.double * 4
        if beats == beats.rounded() { return "\(Int(beats)) beat\(beats == 1 ? "" : "s")" }
        return String(format: "%.2g beats", beats)
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(score)
        score = last
        validateSelection()
        refresh()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(score)
        score = next
        validateSelection()
        refresh()
    }

    private func validateSelection() {
        if let s = selection, part.path(of: s) == nil { selection = nil }
        caret.measure = min(caret.measure, part.measures.count - 1)
        caret.item = min(caret.item, part.measures[caret.measure].items.count)
    }

    private func save() {
        var s = score
        s.title = score.title
        do {
            try library.save(s)
            dismiss(animated: true)
        } catch {
            showError("Couldn't save", error)
        }
    }

    private func cancel() {
        guard score != original else { dismiss(animated: true); return }
        let a = UIAlertController(title: "Discard changes?", message: nil, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "Discard Changes", style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        a.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        a.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(a, animated: true)
    }

    // MARK: Tapping

    private func tapped(_ hit: StaffHit?) {
        guard let hit else { selection = nil; return }
        if let id = hit.noteId, let path = part.path(of: id) {
            selection = id
            caret = ItemPath(measure: path.measure, item: path.item + 1)
            if let n = part.note(at: path), !n.isRest { preview(n.pitches) }
            return
        }
        insert(at: ItemPath(measure: hit.measure, item: hit.insertIndex), pitch: hit.pitch)
    }

    private func insert(at path: ItemPath, pitch: Pitch) {
        let note = restMode ? NoteEvent(rest: input) : NoteEvent(duration: input, pitches: [pitch])
        var inserted = path
        change { s in inserted = s.parts[0].insert(note, at: path) }
        selection = note.id
        caret = ItemPath(measure: inserted.measure, item: inserted.item + 1)
        if !note.isRest { preview(note.pitches) }
        advanceIfComplete()
    }

    /// When a bar is full, the caret moves to the next one; the last bar gets a new bar after it.
    private func advanceIfComplete() {
        let m = caret.measure
        guard caret.item >= part.measures[m].items.count,
              part.measures[m].fill(in: part.attributes(at: m).time) == .complete else { return }
        if m == part.measures.count - 1 {
            // Not an undo step of its own: it belongs to the note that filled the bar.
            score.parts[0].appendMeasure()
            refresh()
        }
        caret = ItemPath(measure: m + 1, item: 0)
        scrollCaretIntoView()
    }

    private func scrollCaretIntoView() {
        guard let layout = scoreView.layout, let m = layout.measures.first(where: { $0.index == caret.measure }) else { return }
        scroll.scrollRectToVisible(m.frame.insetBy(dx: 0, dy: -20), animated: true)
    }

    private func preview(_ pitches: [Pitch]) {
        var m = Measure(number: 1)
        m.attributes = MeasureAttributes(tempo: Tempo(bpm: 120))
        m.items = [.note(NoteEvent(duration: .quarter, pitches: pitches))]
        let p = Part(name: "preview", measures: [m])
        player.play(PlaybackSchedule.build(part: p, tuning: settings.value.tuning))
    }

    // MARK: Editing the selection

    private func editSelected(_ edit: (inout NoteEvent, ResolvedAttributes) -> Void) {
        guard let id = selection, let path = part.path(of: id), var note = part.note(at: path) else { return }
        let attrs = part.attributes(at: path.measure)
        change { s in
            edit(&note, attrs)
            s.parts[0].replace(at: path, with: note)
        }
        if !note.isRest { preview(note.pitches) }
    }

    private func selectedPath() -> ItemPath? { selection.flatMap { part.path(of: $0) } }

    /// Puts a direction (dynamic, hairpin) just before the selected note, replacing one of the same kind there.
    private func setDirection(_ item: MeasureItem?, replacing matches: @escaping (MeasureItem) -> Bool) {
        guard let path = selectedPath() else { return }
        change { s in
            var items = s.parts[0].measures[path.measure].items
            var i = path.item
            // Directions attached to this note sit directly before it.
            var j = i - 1
            while j >= 0, items[j].note == nil {
                if matches(items[j]) { items.remove(at: j); i -= 1 }
                j -= 1
            }
            if let item { items.insert(item, at: i) }
            s.parts[0].measures[path.measure].items = items
        }
    }

    private func deleteSelected() {
        if let path = selectedPath() {
            change { $0.parts[0].remove(at: path) }
            selection = nil
            caret = ItemPath(measure: path.measure, item: min(path.item, part.measures[path.measure].items.count))
        } else if caret.item > 0 {
            let path = ItemPath(measure: caret.measure, item: caret.item - 1)
            change { $0.parts[0].remove(at: path) }
            caret = path
        }
    }

    // MARK: Menus

    private func titleMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.rename() },
        ])
    }

    private func rename() {
        let a = UIAlertController(title: "Score details", message: nil, preferredStyle: .alert)
        a.addTextField { $0.text = self.score.title; $0.placeholder = "Title" }
        a.addTextField { $0.text = self.score.composer; $0.placeholder = "Composer" }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak a] _ in
            guard let self, let fields = a?.textFields else { return }
            let title = fields[0].text ?? "", composer = fields[1].text ?? ""
            self.change { $0.title = title.isEmpty ? "Untitled" : title; $0.composer = composer }
            self.title = self.score.title
        })
        present(a, animated: true)
    }

    private func barMenu() -> UIMenu {
        let m = min(caret.measure, part.measures.count - 1)
        let a = part.attributes(at: m)
        let clefs = UIMenu(title: "Clef", subtitle: a.clef.name, image: UIImage(systemName: "music.note"), children: Clef.common.map { c in
            UIAction(title: c.name, state: c == a.clef ? .on : .off) { [weak self] _ in self?.change { $0.parts[0].setAttributes(at: m) { $0.clef = c } } }
        })
        let keys = UIMenu(title: "Key", subtitle: a.key.name, image: UIImage(systemName: "number"), children: KeyPicker.menu(selected: a.key) { [weak self] k in
            self?.change { $0.parts[0].setAttributes(at: m) { $0.key = k } }
        })
        let times = [TimeSignature(4, 4), TimeSignature(3, 4), TimeSignature(2, 4), TimeSignature(6, 8), TimeSignature(2, 2),
                     TimeSignature(3, 8), TimeSignature(9, 8), TimeSignature(12, 8), TimeSignature(5, 4), .common, .cut]
        let meter = UIMenu(title: "Time Signature", subtitle: a.time.description, image: UIImage(systemName: "metronome"), children: times.map { t in
            UIAction(title: t.symbol == .normal ? t.description : t.symbol == .common ? "Common time (𝄴)" : "Cut time (𝄵)", state: t == a.time ? .on : .off) { [weak self] _ in
                self?.change { $0.parts[0].setAttributes(at: m) { $0.time = t } }
            }
        })
        let barlines: [(String, Measure.Barline)] = [("Normal", .regular), ("Double", .double), ("Final", .final),
                                                     ("Start Repeat", .repeatStart), ("End Repeat", .repeatEnd)]
        let barline = UIMenu(title: "Barline", image: UIImage(systemName: "line.3.horizontal"), children: barlines.map { name, b in
            UIAction(title: name, state: part.measures[m].barline == b ? .on : .off) { [weak self] _ in self?.change { $0.parts[0].measures[m].barline = b } }
        })
        return UIMenu(title: "Bar \(part.measures[m].number)", children: [
            UIMenu(options: .displayInline, children: [clefs, keys, meter,
                UIAction(title: "Tempo…", subtitle: a.tempo.description, image: UIImage(systemName: "speedometer")) { [weak self] _ in self?.editTempo(at: m) }]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Fill With Rests", image: UIImage(systemName: "rectangle.dashed")) { [weak self] _ in self?.change { $0.parts[0].fillWithRests(measure: m) } },
                UIAction(title: "Pickup Bar", state: part.measures[m].isPickup ? .on : .off) { [weak self] _ in
                    self?.change { s in s.parts[0].measures[m].isPickup.toggle(); s.parts[0].renumber() }
                },
                barline,
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Insert Bar Before", image: UIImage(systemName: "plus.rectangle")) { [weak self] _ in self?.change { $0.parts[0].insertMeasure(at: m) } },
                UIAction(title: "Insert Bar After", image: UIImage(systemName: "plus.rectangle")) { [weak self] _ in self?.change { $0.parts[0].insertMeasure(at: m + 1) } },
                UIAction(title: "Delete Bar", image: UIImage(systemName: "trash"), attributes: part.measures.count > 1 ? .destructive : .disabled) { [weak self] _ in
                    self?.change { $0.parts[0].removeMeasure(at: m) }
                    self?.selection = nil
                    self?.validateSelection()
                },
            ]),
        ])
    }

    private func editTempo(at m: Int) {
        let current = part.attributes(at: m).tempo
        let a = UIAlertController(title: "Tempo from bar \(part.measures[m].number)", message: "Beats per minute, and an optional marking such as “Allegro”.", preferredStyle: .alert)
        a.addTextField { f in f.text = "\(Int(current.bpm))"; f.keyboardType = .numberPad; f.placeholder = "BPM" }
        a.addTextField { f in f.text = current.text; f.placeholder = "Marking (optional)"; f.autocapitalizationType = .words }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Set", style: .default) { [weak self, weak a] _ in
            guard let fields = a?.textFields, let bpm = Double(fields[0].text ?? "") else { return }
            let text = fields[1].text?.trimmingCharacters(in: .whitespaces)
            self?.change { $0.parts[0].setAttributes(at: m) { $0.tempo = Tempo(bpm: bpm, beatUnit: current.beatUnit, text: text?.isEmpty == false ? text : nil) } }
        })
        present(a, animated: true)
    }
}

// MARK: - Palette actions

extension EditorViewController: EditorPaletteDelegate {
    func palette(setValue kind: NoteValue.Kind) {
        input.kind = kind
        editSelected { n, _ in n.duration.kind = kind; n.isMeasureRest = false }
        refreshPalette()
    }

    func paletteToggleDot() {
        input.dots = input.dots == 0 ? 1 : 0
        editSelected { n, _ in n.duration.dots = n.duration.dots == 0 ? 1 : 0 }
        refreshPalette()
    }

    func paletteToggleTriplet() {
        input.tuplet = input.tuplet == nil ? .triplet : nil
        editSelected { n, _ in n.duration.tuplet = n.duration.tuplet == nil ? .triplet : nil }
        refreshPalette()
    }

    func paletteToggleRest() {
        restMode.toggle()
        // A selected note becomes a rest, or a rest becomes a note on the middle line.
        editSelected { n, a in
            if n.isRest {
                n.isMeasureRest = false
                n.pitches = [a.clef.pitch(atStaffStep: 4)]
            } else {
                n.pitches = []
                n.tieToNext = false
            }
        }
        refreshPalette()
    }

    func palette(accidental alter: Int) {
        editSelected { n, a in
            n.pitches = n.pitches.map { p in
                // Pressing the sign the note already has returns it to what the key says.
                let target = p.alter == alter ? a.key.alter(for: p.step) : alter
                return Pitch(p.step, p.octave, alter: target)
            }
        }
    }

    func palette(step: Int) {
        editSelected { n, a in n = n.movedDiatonically(step, in: a.key) }
    }

    func paletteToggleTie() { editSelected { n, _ in n.tieToNext.toggle() } }

    func paletteCycleSlur() {
        editSelected { n, _ in
            switch (n.slurStart, n.slurStop) {
            case (false, false): n.slurStart = true
            case (true, false): n.slurStart = false; n.slurStop = true
            default: n.slurStart = false; n.slurStop = false
            }
        }
    }

    func palette(doubleStop interval: Int?) {
        editSelected { n, a in
            guard let low = n.pitches.first else { return }
            if let interval {
                let p = low.movedDiatonically(interval - 1)
                n.pitches = [low, Pitch(p.step, p.octave, alter: a.key.alter(for: p.step))]
            } else {
                n.pitches = [low]
            }
        }
    }

    func palette(toggle articulation: Articulation) {
        editSelected { n, _ in
            if n.articulations.contains(articulation) { n.articulations.remove(articulation) } else { n.articulations.insert(articulation) }
        }
    }

    func palette(bowing: Bowing) { editSelected { n, _ in n.bowing = n.bowing == bowing ? nil : bowing } }
    func palette(finger: Int?) { editSelected { n, _ in n.fingerings = finger.map { [$0] } ?? [] } }
    func palette(string: CelloString?) { editSelected { n, _ in n.string = string } }

    func palette(dynamic: Dynamic?) {
        setDirection(dynamic.map { .dynamic($0) }) { if case .dynamic = $0 { true } else { false } }
    }

    func palette(wedge: Wedge?) {
        setDirection(wedge.map { .wedge($0) }) { if case .wedge = $0 { true } else { false } }
    }

    func paletteDelete() { deleteSelected() }
    func paletteUndo() { undo() }
    func paletteRedo() { redo() }
}
