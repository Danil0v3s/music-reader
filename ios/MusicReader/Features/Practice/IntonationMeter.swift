import ScoreKit
import UIKit

/// A horizontal cents gauge: ±50 cents around the target with in-tune and close zones, a needle, and the
/// note names. Shared by practice and the tuner.
final class IntonationMeter: UIView {
    var thresholds = IntonationAssessment.Thresholds() { didSet { track.setNeedsLayout() } }

    private let target = UILabel()
    private let targetCaption = UILabel()
    private let heard = UILabel()
    private let centsLabel = UILabel()
    private let track = Track()
    private let closeZone = UIView()
    private let tuneZone = UIView()
    private let centre = UIView()
    private let needle = UIView()
    private var needleX: NSLayoutConstraint!
    private var cents: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        target.font = Fonts.display(72)
        target.textAlignment = .center
        target.adjustsFontSizeToFitWidth = true
        targetCaption.font = Fonts.label(11)
        targetCaption.textColor = .secondaryLabel
        targetCaption.textAlignment = .center
        heard.font = Fonts.ui(15, relativeTo: .subheadline)
        heard.textColor = .secondaryLabel
        heard.textAlignment = .center
        centsLabel.font = Fonts.label(28, weight: .bold)
        centsLabel.textAlignment = .center

        // A white track with a hairline, pale amber and green zones, a needle in the rating's colour.
        track.backgroundColor = Theme.surface
        track.layer.cornerRadius = 14
        track.layer.cornerCurve = .continuous
        track.layer.borderWidth = 1
        track.layer.borderColor = Theme.hairline.cgColor
        track.clipsToBounds = true
        closeZone.backgroundColor = Theme.rosinSoft
        tuneZone.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.2)
        centre.backgroundColor = Theme.ink.withAlphaComponent(0.35)
        needle.backgroundColor = Theme.accent
        needle.layer.cornerRadius = 2
        needle.alpha = 0
        track.addSubview(closeZone)
        track.addSubview(tuneZone)
        track.addSubview(centre)
        track.addSubview(needle)
        track.onLayout = { [weak self] in self?.layoutZones() }

        let flat = UILabel(), sharp = UILabel()
        flat.text = "♭ FLAT"; sharp.text = "SHARP ♯"
        [flat, sharp].forEach { $0.font = Fonts.label(11); $0.textColor = Theme.inkSoft }
        let ends = UIStackView(arrangedSubviews: [flat, UIView(), sharp])

        let stack = UIStackView(arrangedSubviews: [targetCaption, target, heard, track, ends, centsLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(14, after: heard)
        addSubview(stack)
        [stack, needle].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        needleX = needle.centerXAnchor.constraint(equalTo: track.centerXAnchor)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.heightAnchor.constraint(equalToConstant: 44),
            needle.widthAnchor.constraint(equalToConstant: 4),
            needle.topAnchor.constraint(equalTo: track.topAnchor, constant: 4),
            needle.bottomAnchor.constraint(equalTo: track.bottomAnchor, constant: -4),
            needleX,
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        show(target: nil, caption: "", heard: nil, cents: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Zones are sized from the track's own layout pass, once the stack has given it a width.
    private func layoutZones() {
        let w = track.bounds.width, h = track.bounds.height
        func span(_ c: Double) -> CGFloat { CGFloat(c / 50) * w / 2 }
        closeZone.frame = CGRect(x: w / 2 - span(thresholds.close), y: 0, width: span(thresholds.close) * 2, height: h)
        tuneZone.frame = CGRect(x: w / 2 - span(thresholds.inTune), y: 0, width: span(thresholds.inTune) * 2, height: h)
        centre.frame = CGRect(x: w / 2 - 0.5, y: 0, width: 1, height: h)
        if let cents { needleX.constant = span(max(-50, min(50, cents))) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutZones()
    }

    private final class Track: UIView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    /// - Parameters:
    ///   - target: the note expected (or the nearest note, for the tuner).
    ///   - cents: deviation from it; nil hides the needle (silence).
    func show(target: String?, caption: String, heard: String?, cents: Double?) {
        self.target.text = target ?? "–"
        self.targetCaption.text = caption
        self.heard.text = heard ?? " "
        self.cents = cents
        if let cents {
            let c = Int(cents.rounded())
            centsLabel.text = c == 0 ? "0 ¢" : String(format: "%+d ¢", c)
            let a = abs(cents)
            let color: UIColor = a <= thresholds.inTune ? Theme.inTune : a <= thresholds.close ? Theme.close : Theme.off
            centsLabel.textColor = color
            needle.backgroundColor = color
            UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.needle.alpha = 1
                self.layoutIfNeeded()
            }
            accessibilityValue = c == 0 ? "in tune" : c > 0 ? "\(c) cents sharp" : "\(-c) cents flat"
        } else {
            centsLabel.text = " "
            UIView.animate(withDuration: 0.3) { self.needle.alpha = 0.15 }
            accessibilityValue = "listening"
        }
        accessibilityLabel = [caption, target].compactMap { $0 }.joined(separator: " ")
    }
}
