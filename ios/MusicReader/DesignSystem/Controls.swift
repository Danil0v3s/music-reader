import UIKit

/// The floating playback bar: rewind, play/pause, practice tempo, loop, metronome. A white pill with a
/// hairline and a soft shadow, a big varnish play button, a pale rosin chip while looping.
final class TransportBar: UIView {
    var onPlay: (() -> Void)?
    var onRewind: (() -> Void)?
    var onTempo: ((Double) -> Void)?
    var onMetronome: ((Bool) -> Void)?
    var onLoop: (() -> Void)?

    var isPlaying = false { didSet { updatePlay() } }
    var isBusy = false { didSet { isBusy ? spinner.startAnimating() : spinner.stopAnimating(); play.isHidden = isBusy } }
    var metronome = false { didSet { updateMetronome() } }
    var tempoText = "" { didSet { tempoButton.configuration?.title = tempoText } }
    /// The bars playing on repeat ("5–8"), or nil when not looping.
    var loopText: String? { didSet { updateLoop() } }

    private let play = UIButton(type: .system)
    private let rewind = UIButton(type: .system)
    private let tempoButton = UIButton(type: .system)
    private let metronomeButton = UIButton(type: .system)
    private let loopButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let scales: [Double] = [0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25]
    /// The practice tempo ticked in the menu (1 = as written).
    var scale = 1.0 { didSet { tempoButton.menu = tempoMenu() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let pill = UIView()
        pill.backgroundColor = Theme.surface
        pill.layer.cornerRadius = 34
        pill.layer.cornerCurve = .continuous
        pill.layer.borderWidth = 1
        pill.layer.borderColor = Theme.hairline.cgColor
        pill.layer.shadowColor = UIColor(red: 0.17, green: 0.15, blue: 0.13, alpha: 1).cgColor
        pill.layer.shadowOpacity = 0.14
        pill.layer.shadowRadius = 14
        pill.layer.shadowOffset = CGSize(width: 0, height: 8)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: TransportBar, _) in
            pill.layer.borderColor = Theme.hairline.resolvedColor(with: bar.traitCollection).cgColor
        }
        addSubview(pill)
        pill.translatesAutoresizingMaskIntoConstraints = false

        var big = UIButton.Configuration.filled()
        big.cornerStyle = .capsule
        big.baseBackgroundColor = Theme.accent
        big.baseForegroundColor = .white
        big.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19, weight: .bold)
        play.configuration = big
        play.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
        play.accessibilityLabel = "Play"

        var plain = UIButton.Configuration.plain()
        plain.image = UIImage(systemName: "backward.end.fill")
        plain.baseForegroundColor = Theme.ink
        rewind.configuration = plain
        rewind.accessibilityLabel = "Back to the start"
        rewind.addAction(UIAction { [weak self] _ in self?.onRewind?() }, for: .primaryActionTriggered)

        var tempo = UIButton.Configuration.plain()
        tempo.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = Fonts.label(14, weight: .bold); return a
        }
        tempo.baseForegroundColor = Theme.ink
        tempoButton.configuration = tempo
        tempoButton.showsMenuAsPrimaryAction = true
        tempoButton.menu = tempoMenu()
        tempoButton.accessibilityLabel = "Practice tempo"

        metronomeButton.configuration = .plain()
        metronomeButton.accessibilityLabel = "Metronome"
        metronomeButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.metronome.toggle()
            self.onMetronome?(self.metronome)
        }, for: .primaryActionTriggered)

        loopButton.addAction(UIAction { [weak self] _ in self?.onLoop?() }, for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [rewind, play, spinner, tempoButton, loopButton, metronomeButton])
        row.alignment = .center
        row.spacing = 6
        row.setCustomSpacing(14, after: spinner)
        pill.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: pill.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -7),
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            play.widthAnchor.constraint(equalToConstant: 54),
            play.heightAnchor.constraint(equalToConstant: 54),
            spinner.widthAnchor.constraint(equalToConstant: 0),
        ])
        tempoButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updatePlay()
        updateMetronome()
        updateLoop()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updatePlay() {
        play.configuration?.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
        play.accessibilityLabel = isPlaying ? "Pause" : "Play"
    }

    private func updateLoop() {
        var c: UIButton.Configuration = loopText == nil ? .plain() : .filled()
        c.image = UIImage(systemName: "repeat", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        c.title = loopText
        c.imagePadding = 5
        c.cornerStyle = .capsule
        c.baseForegroundColor = loopText == nil ? Theme.ink : Theme.rosinInk
        c.baseBackgroundColor = Theme.rosinSoft
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = Fonts.label(13, weight: .bold); return a
        }
        loopButton.configuration = c
        loopButton.accessibilityLabel = loopText.map { "Looping bars \($0). Stop looping" } ?? "Loop bars"
    }

    private func updateMetronome() {
        metronomeButton.configuration?.image = UIImage(systemName: "metronome" + (metronome ? ".fill" : ""))
        metronomeButton.configuration?.baseForegroundColor = metronome ? Theme.accent : Theme.ink
        metronomeButton.accessibilityValue = metronome ? "On" : "Off"
    }

    private func tempoMenu() -> UIMenu {
        UIMenu(title: "Practice tempo", children: scales.reversed().map { s in
            UIAction(title: s == 1 ? "Written tempo" : "\(Int((s * 100).rounded()))%", state: s == scale ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.scale = s
                self.onTempo?(s)
            }
        })
    }
}

/// A small floating label that says what was tapped.
final class InfoPill: UIView {
    private let title = UILabel()
    private let detail = UILabel()
    private var hideTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let card = UIView()
        card.backgroundColor = Theme.surface
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Theme.hairline.cgColor
        card.layer.shadowColor = UIColor(red: 0.17, green: 0.15, blue: 0.13, alpha: 1).cgColor
        card.layer.shadowOpacity = 0.08
        card.layer.shadowRadius = 10
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(card)
        title.font = Fonts.display(18)
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = Theme.inkSoft
        detail.numberOfLines = 3
        detail.textAlignment = .center
        title.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.spacing = 2
        card.addSubview(stack)
        [card, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        alpha = 0
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, detail: String, for seconds: Double = 6) {
        self.title.text = title
        self.detail.text = detail
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: "\(title). \(detail)")
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        UIView.animate(withDuration: 0.25) { self.alpha = 0 }
    }
}

extension UIViewController {
    func showError(_ title: String, _ error: Error) {
        let a = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}
