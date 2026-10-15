import Combine
import ScoreKit
import UIKit

/// Reading a score: notation, playback that follows along, practice speed and metronome, a passage on
/// repeat (hold a bar and drag across the others), and, for a tapped note, what it is in music-theory terms.
final class ScoreViewController: UIViewController {
    private var score: Score
    private let library: ScoreLibrary
    private let player: ScorePlayer
    private let settings: SettingsStore
    private let onEdit: () -> Void
    private let onPractice: (Int) -> Void
    private let onOriginal: () -> Void
    private let onShare: ([Any], UIBarButtonItem?) -> Void
    /// Share a code for this score (my scores only).
    private let onShareCode: (() -> Void)?
    /// Someone else's shared score, read-only: importing saves my own copy.
    private let onImport: (() -> Void)?
    private var isShared: Bool { onImport != nil }
    var scoreId: UUID { score.id }

    private let scroll = UIScrollView()
    private let scoreView = ScoreView()
    private let transport = TransportBar()
    private let infoPill = InfoPill()
    private var schedule: PlaybackSchedule?
    private var startMeasure = 0
    /// Bars playing on repeat.
    private var loop: ClosedRange<Int>? { didSet { loopChanged() } }
    private var displayLink: CADisplayLink?
    private var bag = Set<AnyCancellable>()
    private var tempoScale = 1.0
    private var moreItem: UIBarButtonItem!

    init(score: Score, library: ScoreLibrary, player: ScorePlayer, settings: SettingsStore, onEdit: @escaping () -> Void,
         onPractice: @escaping (Int) -> Void, onOriginal: @escaping () -> Void, onShare: @escaping ([Any], UIBarButtonItem?) -> Void,
         onShareCode: (() -> Void)? = nil, onImport: (() -> Void)? = nil) {
        self.score = score
        self.library = library
        self.player = player
        self.settings = settings
        self.onEdit = onEdit
        self.onPractice = onPractice
        self.onOriginal = onOriginal
        self.onShare = onShare
        self.onShareCode = onShareCode
        self.onImport = onImport
        super.init(nibName: nil, bundle: nil)
        title = score.title
        navigationItem.largeTitleDisplayMode = .never
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper

        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .always
        view.addSubview(scroll)
        scroll.addSubview(scoreView)
        view.addSubview(transport)
        view.addSubview(infoPill)
        [scroll, scoreView, transport, infoPill].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            // The safe area, not the edges: on iPad the library sidebar floats over this column's left side.
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scoreView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            scoreView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            scoreView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scoreView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            scoreView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),

            transport.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            infoPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            infoPill.bottomAnchor.constraint(equalTo: transport.topAnchor, constant: -10),
            infoPill.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
        ] + NSLayoutConstraint.readable(transport, in: view.safeAreaLayoutGuide, maxWidth: 640, inset: 12))
        scroll.contentInset.bottom = 110

        scoreView.staffSpace = settings.value.staffSpace
        scoreView.score = score
        scoreView.onTap = { [weak self] hit, _ in self?.tapped(hit) }
        scoreView.onSelectBars = { [weak self] range, state in self?.selectingBars(range, state) }

        let edit = UIBarButtonItem(title: "Edit", image: UIImage(systemName: "pencil"), primaryAction: UIAction { [weak self] _ in self?.stopPlayback(); self?.onEdit() })
        let practice = UIBarButtonItem(title: "Practice", image: UIImage(systemName: "waveform.badge.mic"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.stopPlayback()
            self.onPractice(self.loop?.lowerBound ?? self.startMeasure)
        })
        moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: moreMenu())
        if let onImport {
            var c = UIButton.Configuration.filled()
            c.title = "Import"
            c.image = UIImage(systemName: "square.and.arrow.down")
            c.imagePadding = 6
            c.cornerStyle = .capsule
            c.baseBackgroundColor = Theme.accent
            let importButton = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.stopPlayback(); onImport() })
            navigationItem.rightBarButtonItems = [moreItem, UIBarButtonItem(customView: importButton)]
        } else {
            navigationItem.rightBarButtonItems = [moreItem, edit, practice]
        }

        transport.metronome = settings.value.metronome
        transport.onPlay = { [weak self] in self?.togglePlay() }
        transport.onRewind = { [weak self] in self?.rewind() }
        transport.onTempo = { [weak self] scale in self?.setTempo(scale) }
        transport.onLoop = { [weak self] in self?.loopTapped() }
        transport.onMetronome = { [weak self] on in
            self?.player.metronome = on
            self?.settings.update { $0.metronome = on }
        }
        player.metronome = settings.value.metronome
        transport.tempoText = tempoLabel()

        player.state.receive(on: DispatchQueue.main).sink { [weak self] state in self?.playerChanged(state) }.store(in: &bag)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Back from the editor: show the saved changes.
        if !isShared, let fresh = try? library.load(score.id), fresh != score {
            score = fresh
            title = score.title
            scoreView.score = score
            schedule = nil
            if let loop, loop.upperBound >= score.parts[scoreView.partIndex].measures.count { self.loop = nil }
            transport.tempoText = tempoLabel()
            moreItem.menu = moreMenu()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()   // for the keyboard and page-turn pedals
    }

    // MARK: Keyboard and page-turn pedals

    override var canBecomeFirstResponder: Bool { true }

    /// Space plays and pauses; Page Down/Up and the arrow keys turn the page (Bluetooth page-turn pedals send
    /// these), so a score on a music stand can be read without touching the screen.
    override var keyCommands: [UIKeyCommand]? {
        let play = UIKeyCommand(title: "Play / Pause", action: #selector(keyPlay), input: " ")
        let forward = [UIKeyCommand.inputPageDown, UIKeyCommand.inputDownArrow, UIKeyCommand.inputRightArrow].map {
            UIKeyCommand(title: "Next Page", action: #selector(keyNextPage), input: $0)
        }
        let back = [UIKeyCommand.inputPageUp, UIKeyCommand.inputUpArrow, UIKeyCommand.inputLeftArrow].map {
            UIKeyCommand(title: "Previous Page", action: #selector(keyPreviousPage), input: $0)
        }
        let all = [play] + forward + back
        all.forEach { $0.wantsPriorityOverSystemBehavior = true }
        // Only the first of each shows in the keyboard shortcuts overlay.
        (forward.dropFirst() + back.dropFirst()).forEach { $0.attributes = .hidden }
        return all
    }

    @objc private func keyPlay() { togglePlay() }
    @objc private func keyNextPage() { turnPage(1) }
    @objc private func keyPreviousPage() { turnPage(-1) }

    /// Scrolls a screenful, keeping a line of overlap so the eye has somewhere to land.
    private func turnPage(_ direction: CGFloat) {
        let inset = scroll.adjustedContentInset
        let visible = scroll.bounds.height - inset.top - inset.bottom
        let minY = -inset.top, maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        let target = min(maxY, max(minY, scroll.contentOffset.y + direction * (visible - scoreView.staffSpace * 10)))
        scroll.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { stopPlayback() }
    }

    // MARK: Playback

    private func buildSchedule() -> PlaybackSchedule {
        let part = score.parts[scoreView.partIndex]
        let s = loop.map { PlaybackSchedule.loop(part: part, measures: $0, tuning: settings.value.tuning, tempoScale: tempoScale) }
            ?? PlaybackSchedule.build(part: part, tuning: settings.value.tuning, tempoScale: tempoScale)
        schedule = s
        return s
    }

    private func togglePlay() {
        switch player.state.value {
        case .playing, .rendering:
            player.pause()
        case .paused(let at):
            play(from: at, countIn: false)
        case .stopped:
            let s = schedule ?? buildSchedule()
            play(from: loop == nil ? s.time(ofMeasure: startMeasure) : 0, countIn: true)
        }
    }

    private func play(from time: Double, countIn: Bool) {
        let s = schedule ?? buildSchedule()
        let beats = countIn && settings.value.countIn && settings.value.metronome ? countInBeats() : 0
        if loop != nil {
            player.playLoop(s, from: min(time, max(0, s.duration - 0.05)), countInBeats: beats)
        } else {
            player.play(s, from: time, countInBeats: beats)
        }
    }

    private func countInBeats() -> Int {
        score.parts[scoreView.partIndex].attributes(at: loop?.lowerBound ?? startMeasure).time.beatsPerMeasure
    }

    private func rewind() {
        startMeasure = 0
        player.stop()
        scoreView.playingNote = nil
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: true)
    }

    private func stopPlayback() {
        player.stop()
        scoreView.playingNote = nil
    }

    private func setTempo(_ scale: Double) {
        let wasPlaying: Bool = if case .playing = player.state.value { true } else { false }
        let position = player.currentTime / tempoScale
        tempoScale = scale
        schedule = nil
        transport.tempoText = tempoLabel()
        if wasPlaying {
            _ = buildSchedule()
            play(from: max(0, position * scale), countIn: false)
        } else if case .paused = player.state.value {
            player.stop()
        }
    }

    private func tempoLabel() -> String {
        let tempo = score.parts[scoreView.partIndex].attributes(at: 0).tempo
        let bpm = Int((tempo.bpm * tempoScale).rounded())
        return tempoScale == 1 ? "♩ = \(bpm)" : "♩ = \(bpm) · \(Int((tempoScale * 100).rounded()))%"
    }

    private func playerChanged(_ state: ScorePlayer.State) {
        transport.isPlaying = state != .stopped && { if case .paused = state { false } else { true } }()
        transport.isBusy = state == .rendering
        switch state {
        case .playing:
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        default:
            displayLink?.invalidate()
            displayLink = nil
            if state == .stopped { scoreView.playingNote = nil }
        }
    }

    @objc private func tick() {
        guard let schedule else { return }
        let t = player.currentTime
        guard let note = schedule.note(at: t), !note.isGrace else { return }
        if scoreView.playingNote != note.noteId {
            scoreView.playingNote = note.noteId
            follow(note.noteId)
        }
    }

    /// Keeps the line being played in view, turning the page a line early.
    private func follow(_ id: UUID) {
        guard let frame = scoreView.systemFrame(containing: id) else { return }
        let visible = CGRect(x: 0, y: scroll.contentOffset.y + scroll.adjustedContentInset.top, width: scroll.bounds.width,
                             height: scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom)
        if frame.maxY > visible.maxY || frame.minY < visible.minY {
            let target = min(frame.minY - 12 - scroll.adjustedContentInset.top,
                             scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, target)), animated: true)
        }
    }

    // MARK: Looping a passage

    private func selectingBars(_ range: ClosedRange<Int>, _ state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            stopPlayback()
            infoPill.hide()
            scroll.panGestureRecognizer.isEnabled = false     // the drag chooses bars instead of scrolling
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showSelection(range)
        case .changed:
            if scoreView.measureTints.count != range.count || scoreView.measureTints[range.lowerBound] == nil {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            showSelection(range)
        default:
            scroll.panGestureRecognizer.isEnabled = true
            loop = range
            infoPill.show(title: "\(barsText(range)) on repeat", detail: "Press play to practise \(range.count == 1 ? "it" : "them") over and over. Tap the repeat button to stop.")
        }
    }

    private func showSelection(_ range: ClosedRange<Int>) {
        scoreView.measureTints = Dictionary(uniqueKeysWithValues: range.map { ($0, Theme.accent) })
        transport.loopText = barNumbers(range)
    }

    private func loopChanged() {
        schedule = nil
        stopPlayback()
        if let loop {
            showSelection(loop)
        } else {
            scoreView.measureTints = [:]
            transport.loopText = nil
        }
    }

    private func loopTapped() {
        if loop != nil {
            loop = nil
            infoPill.show(title: "Loop off", detail: "Playback runs through the whole piece again.", for: 3)
        } else {
            infoPill.show(title: "Loop a passage", detail: "Press and hold a bar, then drag across the bars you want to repeat.")
        }
    }

    /// "5–8" in the score's own bar numbers.
    private func barNumbers(_ range: ClosedRange<Int>) -> String {
        let measures = score.parts[scoreView.partIndex].measures
        let first = measures[range.lowerBound].number, last = measures[range.upperBound].number
        return first == last ? "\(first)" : "\(first)–\(last)"
    }

    private func barsText(_ range: ClosedRange<Int>) -> String {
        (range.count == 1 ? "Bar " : "Bars ") + barNumbers(range)
    }

    // MARK: Tapping notes

    private func tapped(_ hit: StaffHit?) {
        guard let hit else { infoPill.hide(); return }
        startMeasure = hit.measure
        let part = score.parts[scoreView.partIndex]
        guard let id = hit.noteId, let path = part.path(of: id), let note = part.note(at: path) else {
            scoreView.selectedNote = nil
            infoPill.show(title: "Bar \(part.measures[hit.measure].number)", detail: "Playback and practice start here")
            if case .stopped = player.state.value {} else { player.stop() }
            return
        }
        scoreView.selectedNote = id
        let (title, detail) = NoteInfo.describe(note, at: path, in: part, tuning: settings.value.tuning)
        infoPill.show(title: title, detail: detail)
        if case .stopped = player.state.value {} else { player.stop() }
    }

    // MARK: Menu

    private func moreMenu() -> UIMenu {
        var items: [UIMenuElement] = []
        if let onShareCode {
            items.append(UIAction(title: "Share…", subtitle: "A code friends can open", image: UIImage(systemName: "person.2")) { [weak self] _ in
                self?.stopPlayback()
                onShareCode()
            })
        }
        if let from = score.importedFrom {
            items.append(UIAction(title: "Shared by \(from.owner)", subtitle: "Code \(from.code)", image: UIImage(systemName: "person.crop.circle"), attributes: .disabled) { _ in })
        }
        if !isShared, FileManager.default.fileExists(atPath: library.originalURL(score.id).path) {
            items.append(UIAction(title: "Show Original PDF", image: UIImage(systemName: "doc.richtext")) { [weak self] _ in self?.onOriginal() })
        }
        items.append(UIMenu(title: "Size", options: .displayInline, children: [
            UIAction(title: "Larger", image: UIImage(systemName: "plus.magnifyingglass")) { [weak self] _ in self?.zoom(1) },
            UIAction(title: "Smaller", image: UIImage(systemName: "minus.magnifyingglass")) { [weak self] _ in self?.zoom(-1) },
        ]))
        if score.parts.count > 1 {
            items.append(UIMenu(title: "Part", image: UIImage(systemName: "person.3"), children: score.parts.enumerated().map { i, p in
                UIAction(title: p.name, state: i == scoreView.partIndex ? .on : .off) { [weak self] _ in
                    self?.scoreView.partIndex = i
                    self?.schedule = nil
                    self?.moreItem.menu = self?.moreMenu()
                }
            }))
        }
        if isShared { return UIMenu(children: items) }
        items.append(UIMenu(title: "Export", options: .displayInline, children: [
            UIAction(title: "Export MusicXML", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.export(pdf: false) },
            UIAction(title: "Export PDF", image: UIImage(systemName: "doc")) { [weak self] _ in self?.export(pdf: true) },
        ]))
        return UIMenu(children: items)
    }

    private func zoom(_ direction: Int) {
        let size = max(5, min(14, scoreView.staffSpace + CGFloat(direction)))
        scoreView.staffSpace = size
        settings.update { $0.staffSpace = Double(size) }
    }

    private func export(pdf: Bool) {
        let name = score.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + (pdf ? ".pdf" : ".musicxml"))
        let data = pdf ? scoreView.pdfData() : MusicXMLWriter.write(score)
        guard let data, (try? data.write(to: url)) != nil else { return }
        onShare([url], moreItem)
    }
}

/// Describes a note in music-theory terms for the info pill.
enum NoteInfo {
    static func describe(_ note: NoteEvent, at path: ItemPath, in part: Part, tuning: Tuning) -> (String, String) {
        let a = part.attributes(at: path.measure)
        let value = note.isMeasureRest ? "Whole-bar rest" : note.duration.description.lowercased()
        guard !note.isRest else { return ("Rest", value.capitalized) }
        let names = note.pitches.map(\.description).joined(separator: " + ")
        var detail: [String] = [value]
        if note.pitches.count == 2 {
            detail.append(Interval(from: note.pitches[0], to: note.pitches[1]).name + " double stop")
        }
        if let p = note.pitches.last {
            detail.append(degree(of: p, in: a.key))
            detail.append(String(format: "%.1f Hz", tuning.frequency(of: p, in: a.key)))
            if let previous = previousPitch(before: path, in: part) {
                let interval = Interval(from: previous, to: p)
                let direction = p > previous ? "up" : p < previous ? "down" : ""
                detail.append(interval.number == 1 && interval.semitones == 0 ? "repeated" : "\(interval.name) \(direction)")
            }
            if let string = note.string ?? CelloString.natural(for: p) { detail.append("\(string.roman) string") }
        }
        if !note.fingerings.isEmpty { detail.append("finger " + note.fingerings.map { $0 == 5 ? "thumb" : "\($0)" }.joined(separator: "/")) }
        if let bow = note.bowing { detail.append(bow == .down ? "down-bow" : "up-bow") }
        return (names, detail.joined(separator: " · "))
    }

    /// The scale degree with its functional name, or how the pitch is altered from the key.
    static func degree(of p: Pitch, in key: KeySignature) -> String {
        let names = ["tonic", "supertonic", "mediant", "subdominant", "dominant", "submediant", key.mode == .major ? "leading tone" : "subtonic"]
        let scale = key.scale
        guard let i = scale.firstIndex(where: { $0.step == p.step }) else { return "" }
        let diff = p.alter - scale[i].alter
        let ordinal = ["1st", "2nd", "3rd", "4th", "5th", "6th", "7th"][i]
        if diff == 0 { return "\(ordinal) degree (\(names[i])) of \(key.name)" }
        return "\(diff > 0 ? "raised" : "lowered") \(ordinal) degree of \(key.name)"
    }

    static func previousPitch(before path: ItemPath, in part: Part) -> Pitch? {
        var m = path.measure, i = path.item - 1
        while m >= 0 {
            let items = part.measures[m].items
            while i >= 0 {
                if let n = items[i].note, let p = n.pitches.last { return p }
                i -= 1
            }
            m -= 1
            if m >= 0 { i = part.measures[m].items.count - 1 }
        }
        return nil
    }
}
