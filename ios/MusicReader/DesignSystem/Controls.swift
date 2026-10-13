import UIKit

/// The floating playback bar: rewind, play/pause, practice tempo, metronome.
final class TransportBar: UIView {
    var onPlay: (() -> Void)?
    var onRewind: (() -> Void)?
    var onTempo: ((Double) -> Void)?
    var onMetronome: ((Bool) -> Void)?

    var isPlaying = false { didSet { updatePlay() } }
    var isBusy = false { didSet { isBusy ? spinner.startAnimating() : spinner.stopAnimating(); play.isHidden = isBusy } }
    var metronome = false { didSet { updateMetronome() } }
    var tempoText = "" { didSet { tempoButton.configuration?.title = tempoText } }

    private let play = UIButton(type: .system)
    private let rewind = UIButton(type: .system)
    private let tempoButton = UIButton(type: .system)
    private let metronomeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let scales: [Double] = [0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25]
    private var scale = 1.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        let glass = UIVisualEffectView(effect: UIGlassEffect())
        glass.layer.cornerRadius = 28
        glass.clipsToBounds = true
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false

        var big = UIButton.Configuration.filled()
        big.cornerStyle = .capsule
        big.baseBackgroundColor = Theme.accent
        play.configuration = big
        play.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
        play.accessibilityLabel = "Play"

        var plain = UIButton.Configuration.plain()
        plain.image = UIImage(systemName: "backward.end.fill")
        rewind.configuration = plain
        rewind.accessibilityLabel = "Back to the start"
        rewind.addAction(UIAction { [weak self] _ in self?.onRewind?() }, for: .primaryActionTriggered)

        var tempo = UIButton.Configuration.plain()
        tempo.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = Fonts.mono(14); return a
        }
        tempo.baseForegroundColor = .label
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

        let row = UIStackView(arrangedSubviews: [rewind, play, spinner, tempoButton, metronomeButton])
        row.alignment = .center
        row.spacing = 6
        row.setCustomSpacing(14, after: spinner)
        glass.contentView.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -8),
            play.widthAnchor.constraint(equalToConstant: 46),
            play.heightAnchor.constraint(equalToConstant: 46),
            spinner.widthAnchor.constraint(equalToConstant: 0),
        ])
        tempoButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updatePlay()
        updateMetronome()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updatePlay() {
        play.configuration?.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
        play.accessibilityLabel = isPlaying ? "Pause" : "Play"
    }

    private func updateMetronome() {
        metronomeButton.configuration?.image = UIImage(systemName: "metronome" + (metronome ? ".fill" : ""))
        metronomeButton.configuration?.baseForegroundColor = metronome ? Theme.accent : .secondaryLabel
        metronomeButton.accessibilityValue = metronome ? "On" : "Off"
    }

    private func tempoMenu() -> UIMenu {
        UIMenu(title: "Practice tempo", children: scales.reversed().map { s in
            UIAction(title: s == 1 ? "Written tempo" : "\(Int((s * 100).rounded()))%", state: s == scale ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.scale = s
                self.tempoButton.menu = self.tempoMenu()
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
        let glass = UIVisualEffectView(effect: UIGlassEffect())
        glass.layer.cornerRadius = 18
        glass.clipsToBounds = true
        addSubview(glass)
        title.font = Fonts.serif(17, weight: .semibold)
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 3
        detail.textAlignment = .center
        title.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.spacing = 2
        glass.contentView.addSubview(stack)
        [glass, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -16),
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
