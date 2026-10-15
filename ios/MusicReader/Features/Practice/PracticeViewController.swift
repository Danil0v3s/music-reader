import Combine
import ScoreKit
import UIKit

/// Intonation practice. The microphone's pitch is compared with each written note under the chosen
/// tuning system, and notes are coloured as they're played: green in tune, amber close, red off.
///  - Follow me: waits for you. A note counts once you hold it steadily near its pitch, then the next is expected.
///  - With metronome: count-in, then clicks only; each note is judged in its own time window.
final class PracticeViewController: UIViewController {
    enum Mode: Int { case follow, metronome }

    private let score: Score
    private let settings: SettingsStore
    private let player: ScorePlayer
    private let mic = MicrophoneListener()
    private var startMeasure: Int

    private let scroll = UIScrollView()
    private let scoreView = ScoreView()
    private let meter = IntonationMeter()
    private let modeControl = UISegmentedControl(items: ["Follow Me", "With Metronome"])
    private let startButton = UIButton(configuration: .borderedProminent())
    private let hint = UILabel()
    private let summary = UILabel()
    private let infoPill = InfoPill()

    private var mode = Mode.follow
    private var running = false
    private var schedule: PlaybackSchedule!
    private var targets: [ScheduledNote] = []
    private var current = 0
    private var assessment: IntonationAssessment!
    private var goodFrames = 0
    private var wrongFrames = 0
    private var needsRearticulation = false
    private var lastJudged: UUID?
    private var displayLink: CADisplayLink?
    private var bag = Set<AnyCancellable>()
    private var tempoScale = 1.0

    private var part: Part { score.parts[0] }

    init(score: Score, startMeasure: Int, settings: SettingsStore, player: ScorePlayer) {
        self.score = score
        self.startMeasure = startMeasure
        self.settings = settings
        self.player = player
        super.init(nibName: nil, bundle: nil)
        title = "Practice"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.stop(showSummary: false)
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "speedometer"), menu: tempoMenu())

        let paper = UIView()
        paper.backgroundColor = Theme.paper
        paper.layer.cornerRadius = Theme.radius
        paper.clipsToBounds = true
        paper.addSubview(scroll)
        scroll.addSubview(scoreView)

        modeControl.selectedSegmentIndex = 0
        modeControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.mode = Mode(rawValue: self.modeControl.selectedSegmentIndex) ?? .follow
            self.updateHint()
        }, for: .valueChanged)

        startButton.configuration?.title = "Start"
        startButton.configuration?.image = UIImage(systemName: "mic.fill")
        startButton.configuration?.imagePadding = 8
        startButton.configuration?.cornerStyle = .capsule
        startButton.configuration?.buttonSize = .large
        startButton.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .primaryActionTriggered)

        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.textAlignment = .center
        summary.font = .preferredFont(forTextStyle: .subheadline)
        summary.numberOfLines = 0
        summary.textAlignment = .center
        meter.thresholds = settings.value.thresholds

        let controls = UIStackView(arrangedSubviews: [meter, summary, modeControl, startButton, hint])
        controls.axis = .vertical
        controls.spacing = 14
        controls.setCustomSpacing(20, after: summary)

        view.addSubview(paper)
        view.addSubview(controls)
        view.addSubview(infoPill)
        [paper, scroll, scoreView, controls, infoPill].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            paper.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            paper.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            paper.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            paper.heightAnchor.constraint(equalTo: guide.heightAnchor, multiplier: 0.36),
            scroll.topAnchor.constraint(equalTo: paper.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
            scoreView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            scoreView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            scoreView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scoreView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            scoreView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            controls.topAnchor.constraint(greaterThanOrEqualTo: paper.bottomAnchor, constant: 16),
            controls.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            infoPill.centerXAnchor.constraint(equalTo: paper.centerXAnchor),
            infoPill.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -8),
            infoPill.leadingAnchor.constraint(greaterThanOrEqualTo: paper.leadingAnchor, constant: 8),
        ] + NSLayoutConstraint.readable(controls, in: guide, maxWidth: 640, inset: 24))

        scoreView.staffSpace = 7
        scoreView.showHeader = false
        scoreView.score = score
        scoreView.onTap = { [weak self] hit, _ in self?.tapped(hit) }
        mic.onReading = { [weak self] r in self?.heard(r) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MR_DEV_FAKE_MIC"] == "1" { mic.simulate = { [weak self] in self?.simulatedFrequency() } }
        #endif
        prepare()
        updateHint()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop(showSummary: false)
    }

    private func tempoMenu() -> UIMenu {
        UIMenu(title: "Tempo with metronome", children: [0.5, 0.6, 0.7, 0.8, 0.9, 1.0].reversed().map { s in
            UIAction(title: s == 1 ? "Written tempo" : "\(Int(s * 100))%", state: s == tempoScale ? .on : .off) { [weak self] _ in
                self?.tempoScale = s
                self?.navigationItem.rightBarButtonItem?.menu = self?.tempoMenu()
                self?.prepare()
            }
        })
    }

    private func updateHint() {
        hint.text = mode == .follow
            ? "Play each note and hold it steadily. The next note is expected once this one is heard. Start at a bar by tapping it."
            : "One bar of clicks counts you in. Headphones keep the clicks out of the microphone."
    }

    private func prepare() {
        let s = settings.value
        schedule = PlaybackSchedule.build(part: part, tuning: s.tuning, tempoScale: tempoScale, from: startMeasure)
        targets = schedule.notes.filter { !$0.isRest && !$0.isGrace && $0.sounding > 0 }
        assessment = IntonationAssessment(tuning: s.tuning, key: part.attributes(at: startMeasure).key, thresholds: s.thresholds)
        current = 0
        showExpected()
    }

    private func showExpected() {
        guard current < targets.count else {
            meter.show(target: nil, caption: "Done", heard: nil, cents: nil)
            return
        }
        let t = targets[current]
        scoreView.playingNote = t.noteId
        follow(t.noteId)
        let names = t.pitches.map(\.description).joined(separator: " + ")
        meter.show(target: names, caption: "Bar \(part.measures[t.path.measure].number) · \(Int(t.frequencies.last ?? 0)) Hz", heard: nil, cents: nil)
    }

    // MARK: Running

    private func toggle() { running ? stop(showSummary: true) : start() }

    private func start() {
        Task { @MainActor in
            guard await MicrophoneListener.requestPermission() else {
                let a = UIAlertController(title: "Microphone access is off", message: "Allow Music Reader to use the microphone in Settings to check your intonation.", preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                })
                a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                present(a, animated: true)
                return
            }
            prepare()
            scoreView.noteColors = [:]
            summary.text = nil
            startButton.isEnabled = false
            mic.start { error in
                self.startButton.isEnabled = true
                if let error { self.showError("The microphone couldn't start", error); return }
                self.beginRun()
            }
        }
    }

    private func beginRun() {
        running = true
        modeControl.isEnabled = false
        startButton.configuration?.title = "Stop"
        startButton.configuration?.image = UIImage(systemName: "stop.fill")
        UIApplication.shared.isIdleTimerDisabled = true
        if mode == .metronome {
            player.metronome = true
            player.musicVolume = 0
            let beats = part.attributes(at: startMeasure).time.beatsPerMeasure
            player.play(schedule, from: schedule.time(ofMeasure: startMeasure), countInBeats: beats, session: .practice)
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
            player.state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] s in
                if s == .stopped, self?.running == true { self?.stop(showSummary: true) }
            }.store(in: &bag)
        }
    }

    private func stop(showSummary: Bool) {
        guard running else { return }
        running = false
        mic.stop()
        displayLink?.invalidate()
        displayLink = nil
        bag.removeAll()
        if mode == .metronome {
            player.stop()
            player.musicVolume = 1
            player.metronome = settings.value.metronome
        }
        UIApplication.shared.isIdleTimerDisabled = false
        modeControl.isEnabled = true
        startButton.configuration?.title = "Start Again"
        startButton.configuration?.image = UIImage(systemName: "mic.fill")
        scoreView.playingNote = nil
        if showSummary { summarise() }
    }

    // MARK: Listening

    private func heard(_ reading: PitchDetector.Reading?) {
        guard running else { return }
        guard let reading, reading.confidence > 0.86 else {
            // Silence or a bow change: lets a repeated note be heard as a new one.
            needsRearticulation = false
            goodFrames = 0
            if mode == .follow, current < targets.count {
                meter.show(target: targets[current].pitches.map(\.description).joined(separator: " + "),
                           caption: "Bar \(part.measures[targets[current].path.measure].number)", heard: nil, cents: nil)
            }
            return
        }
        switch mode {
        case .follow: follow(reading)
        case .metronome: timed(reading)
        }
    }

    private func follow(_ r: PitchDetector.Reading) {
        guard current < targets.count else { return }
        let t = targets[current]
        let (pitch, freq) = nearestTarget(t, to: r.frequency)
        let cents = Tuning.cents(r.frequency, relativeTo: freq)
        let names = t.pitches.map(\.description).joined(separator: " + ")
        let bar = "Bar \(part.measures[t.path.measure].number)"
        if abs(cents) <= 50 {
            wrongFrames = 0
            meter.show(target: names, caption: bar, heard: t.pitches.count > 1 ? "on \(pitch)" : nil, cents: cents)
            guard !needsRearticulation else { return }
            assessment.add(r.frequency, for: t)
            goodFrames += 1
            // About a third of a second of steady sound counts as the note.
            if goodFrames >= 8 {
                judge(t)
                let next = current + 1
                needsRearticulation = next < targets.count && targets[next].pitches == t.pitches
                goodFrames = 0
                current = next
                showExpected()
                if current >= targets.count { stop(showSummary: true) }
            }
        } else {
            goodFrames = 0
            wrongFrames += 1
            let heardPitch = settings.value.tuning.nearest(to: r.frequency, in: assessment.key)
            meter.show(target: names, caption: bar, heard: wrongFrames > 6 ? "Hearing \(heardPitch.pitch)" : nil, cents: max(-50, min(50, cents)))
        }
    }

    @objc private func tick() {
        guard running, mode == .metronome else { return }
        let t = player.currentTime
        // Judge every note that has finished.
        while current < targets.count, targets[current].end <= t {
            judge(targets[current])
            current += 1
        }
        if current < targets.count, t >= targets[current].start, scoreView.playingNote != targets[current].noteId {
            scoreView.playingNote = targets[current].noteId
            follow(targets[current].noteId)
        }
    }

    private func timed(_ r: PitchDetector.Reading) {
        let t = player.currentTime
        guard current < targets.count else { return }
        let note = targets[current]
        // Skip the bow's attack and the very end, where the next note's shift begins.
        guard t >= note.start + 0.08, t <= note.start + note.sounding * 0.92 else { return }
        assessment.add(r.frequency, for: note)
        let (_, freq) = nearestTarget(note, to: r.frequency)
        meter.show(target: note.pitches.map(\.description).joined(separator: " + "),
                   caption: "Bar \(part.measures[note.path.measure].number)", heard: nil, cents: max(-50, min(50, Tuning.cents(r.frequency, relativeTo: freq))))
    }

    private func nearestTarget(_ note: ScheduledNote, to f: Double) -> (Pitch, Double) {
        let i = note.frequencies.indices.min { abs(Tuning.cents(f, relativeTo: note.frequencies[$0])) < abs(Tuning.cents(f, relativeTo: note.frequencies[$1])) } ?? 0
        return (note.pitches[i], note.frequencies[i])
    }

    private func judge(_ note: ScheduledNote) {
        assessment.expect(note)
        guard let result = assessment.result(for: note.noteId) else { return }
        scoreView.noteColors[note.noteId] = Theme.color(for: result.rating)
        lastJudged = note.noteId
    }

    private func summarise() {
        let results = assessment.results.filter { $0.rating != .missed }
        guard !results.isEmpty else { summary.text = "Nothing was heard. Check the microphone isn't covered."; return }
        let pct = Int((assessment.score * 100).rounded())
        let tendency = assessment.tendency
        var lines = ["\(pct)% of \(results.count) notes in tune (±\(Int(settings.value.thresholds.inTune)) ¢)."]
        if abs(tendency) >= 4 {
            lines.append("On average you play \(Int(abs(tendency).rounded())) ¢ \(tendency > 0 ? "sharp" : "flat"): check your hand frame.")
        }
        let wrong = results.filter { $0.rating == .wrongNote }.count
        if wrong > 0 { lines.append("\(wrong) wrong note\(wrong == 1 ? "" : "s").") }
        let worst = results.filter { $0.rating == .off }.sorted { abs($0.cents) > abs($1.cents) }.prefix(3)
        if !worst.isEmpty {
            lines.append("Furthest off: " + worst.map { "\($0.target) \($0.direction)" }.joined(separator: ", ") + ".")
        }
        summary.text = lines.joined(separator: "\n")
        scroll.setContentOffset(.zero, animated: true)
        UIAccessibility.post(notification: .announcement, argument: summary.text)
    }

    #if DEBUG
    private var simFrame = 0
    private var simNote = -1

    /// A pretend cellist: each note a little off in its own way (some in tune, some close, one off),
    /// with a short gap at each bow change.
    private func simulatedFrequency() -> Double? {
        guard current < targets.count else { return nil }
        if simNote != current { simNote = current; simFrame = 0 }
        simFrame += 1
        if simFrame <= 3 { return nil }
        let offsets: [Double] = [2, -6, 14, 4, -3, 22, 8, -1, 31, 5, -12, 3]
        let cents = offsets[current % offsets.count] + Double.random(in: -2...2)
        return targets[current].frequencies[0] * pow(2, cents / 1200)
    }
    #endif

    // MARK: Score

    private func tapped(_ hit: StaffHit?) {
        guard let hit else { return }
        if let id = hit.noteId, let result = assessment.result(for: id) {
            let detail = result.rating == .missed ? "Not heard" : "\(result.direction) · steadiness ±\(Int(result.spread.rounded())) ¢"
            infoPill.show(title: result.target.description, detail: detail)
        } else if !running {
            startMeasure = hit.measure
            prepare()
            infoPill.show(title: "Starting at bar \(part.measures[hit.measure].number)", detail: "Tap Start when you're ready", for: 3)
        }
    }

    private func follow(_ id: UUID) {
        guard let frame = scoreView.systemFrame(containing: id) else { return }
        let visible = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
        if !visible.contains(CGRect(x: 0, y: frame.minY, width: 1, height: min(frame.height, scroll.bounds.height))) {
            let y = min(max(0, frame.minY - 8), max(0, scroll.contentSize.height - scroll.bounds.height))
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        }
    }
}
