import ScoreKit
import UIKit

/// A cello tuner. Open strings are judged against pure fifths down from A (how cellists tune by ear),
/// other notes against the chosen tuning system. Each string can sound a reference drone.
final class TunerViewController: UIViewController {
    private let settings: SettingsStore
    private let mic = MicrophoneListener()
    private let drone = DronePlayer()
    private let meter = IntonationMeter()
    private let frequency = UILabel()
    private var stringButtons: [CelloString: UIButton] = [:]
    private let note = UILabel()
    private var smoothed: Double?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = "Tuner"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper
        frequency.font = Fonts.label(13)
        frequency.textColor = Theme.inkSoft
        frequency.textAlignment = .center
        note.font = Fonts.ui(13, relativeTo: .footnote)
        note.textColor = Theme.inkSoft
        note.numberOfLines = 0
        note.textAlignment = .center
        note.text = "Tap a string to hear its pitch. Open strings are tuned in pure fifths from A."

        let strings = UIStackView(arrangedSubviews: CelloString.allCases.reversed().map { s in
            // White with a hairline; filled with varnish while its reference tone sounds.
            var c = UIButton.Configuration.plain()
            c.title = s.pitch.name
            c.subtitle = s.roman
            c.titleAlignment = .center
            c.baseForegroundColor = Theme.ink
            c.background.cornerRadius = 20
            c.background.backgroundColor = Theme.surface
            c.background.strokeColor = Theme.ink.withAlphaComponent(0.22)
            c.background.strokeWidth = 1.5
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = Fonts.display(30); return a }
            c.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = Fonts.label(11); return a }
            let b = UIButton(configuration: c)
            b.accessibilityLabel = "\(s.pitch.name) string reference tone"
            b.addAction(UIAction { [weak self] _ in self?.toggleDrone(s) }, for: .primaryActionTriggered)
            stringButtons[s] = b
            return b
        })
        strings.distribution = .fillEqually
        strings.spacing = 10

        let stack = UIStackView(arrangedSubviews: [meter, frequency, UIView(), strings, note])
        stack.axis = .vertical
        stack.spacing = 18
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            strings.heightAnchor.constraint(equalToConstant: 84),
        ] + NSLayoutConstraint.readable(stack, in: view.safeAreaLayoutGuide, maxWidth: 640, inset: 24))
        mic.onReading = { [weak self] r in self?.heard(r) }
        meter.show(target: nil, caption: "Play a note", heard: nil, cents: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        meter.thresholds = IntonationAssessment.Thresholds(inTune: 3, close: 10)  // tuning wants tighter zones than playing
        Task { @MainActor in
            guard await MicrophoneListener.requestPermission() else {
                meter.show(target: nil, caption: "Microphone access is off. Allow it in Settings.", heard: nil, cents: nil)
                return
            }
            mic.start { error in
                if let error { self.meter.show(target: nil, caption: error.localizedDescription, heard: nil, cents: nil) }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        mic.stop()
        stopDrone()
    }

    private func toggleDrone(_ s: CelloString) {
        let f = s.frequency(referenceA4: settings.value.tuning.referenceA4)
        if drone.frequency == f { stopDrone(); return }
        drone.play(f)
        for (string, b) in stringButtons {
            b.configuration?.background.backgroundColor = string == s ? Theme.accent : Theme.surface
            b.configuration?.background.strokeColor = string == s ? Theme.accent : Theme.ink.withAlphaComponent(0.22)
            b.configuration?.baseForegroundColor = string == s ? .white : Theme.ink
        }
        note.text = String(format: "%@ string reference: %.2f Hz. Tap again to stop.", s.pitch.name, f)
    }

    private func stopDrone() {
        drone.stop()
        for b in stringButtons.values {
            b.configuration?.background.backgroundColor = Theme.surface
            b.configuration?.background.strokeColor = Theme.ink.withAlphaComponent(0.22)
            b.configuration?.baseForegroundColor = Theme.ink
        }
    }

    private func heard(_ r: PitchDetector.Reading?) {
        guard let r, r.confidence > 0.88 else {
            smoothed = nil
            meter.show(target: nil, caption: "Play a note", heard: nil, cents: nil)
            frequency.text = " "
            return
        }
        // Light smoothing steadies the needle without lagging a tuning peg turn.
        let f = smoothed.map { 0.65 * $0 + 0.35 * r.frequency } ?? r.frequency
        smoothed = f
        let tuning = settings.value.tuning
        let (pitch, cents) = tuning.nearest(to: f)
        if let string = CelloString.allCases.first(where: { $0.pitch.midi == pitch.midi }) {
            let target = string.frequency(referenceA4: tuning.referenceA4)
            meter.show(target: pitch.description, caption: "\(string.roman) · \(string.pitch.name) string", heard: nil,
                       cents: Tuning.cents(f, relativeTo: target))
            frequency.text = String(format: "%.2f Hz · target %.2f Hz", f, target)
        } else {
            meter.show(target: pitch.description, caption: "Nearest note", heard: nil, cents: cents)
            frequency.text = String(format: "%.2f Hz", f)
        }
    }
}
