import Combine
import ScoreKit
import UIKit

/// Reading a score: notation, playback that follows along, practice speed and metronome, and, for a
/// tapped note, what it is in music-theory terms.
final class ScoreViewController: UIViewController {
    private var score: Score
    private let library: ScoreLibrary
    private let player: ScorePlayer
    private let settings: SettingsStore
    private let onEdit: () -> Void
    private let onPractice: (Int) -> Void
    private let onOriginal: () -> Void
    private let onShare: ([Any], UIBarButtonItem?) -> Void

    private let scroll = UIScrollView()
    private let scoreView = ScoreView()
    private let transport = TransportBar()
    private let infoPill = InfoPill()
    private var schedule: PlaybackSchedule?
    private var startMeasure = 0
    private var displayLink: CADisplayLink?
    private var bag = Set<AnyCancellable>()
    private var tempoScale = 1.0
    private var moreItem: UIBarButtonItem!

    init(score: Score, library: ScoreLibrary, player: ScorePlayer, settings: SettingsStore, onEdit: @escaping () -> Void,
         onPractice: @escaping (Int) -> Void, onOriginal: @escaping () -> Void, onShare: @escaping ([Any], UIBarButtonItem?) -> Void) {
        self.score = score
        self.library = library
        self.player = player
        self.settings = settings
        self.onEdit = onEdit
        self.onPractice = onPractice
        self.onOriginal = onOriginal
        self.onShare = onShare
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
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scoreView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            scoreView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            scoreView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scoreView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            scoreView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            transport.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            transport.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            transport.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            infoPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            infoPill.bottomAnchor.constraint(equalTo: transport.topAnchor, constant: -10),
            infoPill.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
        ])
        scroll.contentInset.bottom = 110

        scoreView.staffSpace = settings.value.staffSpace
        scoreView.score = score
        scoreView.onTap = { [weak self] hit, _ in self?.tapped(hit) }

        let edit = UIBarButtonItem(title: "Edit", image: UIImage(systemName: "pencil"), primaryAction: UIAction { [weak self] _ in self?.stopPlayback(); self?.onEdit() })
        let practice = UIBarButtonItem(title: "Practice", image: UIImage(systemName: "waveform.badge.mic"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.stopPlayback()
            self.onPractice(self.startMeasure)
        })
        moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: moreMenu())
        navigationItem.rightBarButtonItems = [moreItem, edit, practice]

        transport.metronome = settings.value.metronome
        transport.onPlay = { [weak self] in self?.togglePlay() }
        transport.onRewind = { [weak self] in self?.rewind() }
        transport.onTempo = { [weak self] scale in self?.setTempo(scale) }
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
        if let fresh = try? library.load(score.id), fresh != score {
            score = fresh
            title = score.title
            scoreView.score = score
            schedule = nil
            transport.tempoText = tempoLabel()
            moreItem.menu = moreMenu()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { stopPlayback() }
    }

    // MARK: Playback

    private func buildSchedule() -> PlaybackSchedule {
        let s = PlaybackSchedule.build(part: score.parts[scoreView.partIndex], tuning: settings.value.tuning, tempoScale: tempoScale)
        schedule = s
        return s
    }

    private func togglePlay() {
        switch player.state.value {
        case .playing, .rendering:
            player.pause()
        case .paused(let at):
            player.play(schedule ?? buildSchedule(), from: at)
        case .stopped:
            let s = schedule ?? buildSchedule()
            player.play(s, from: s.time(ofMeasure: startMeasure), countInBeats: settings.value.countIn && settings.value.metronome ? countInBeats() : 0)
        }
    }

    private func countInBeats() -> Int {
        score.parts[scoreView.partIndex].attributes(at: startMeasure).time.beatsPerMeasure
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
            let s = buildSchedule()
            player.play(s, from: max(0, position * scale))
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
        if FileManager.default.fileExists(atPath: library.originalURL(score.id).path) {
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
