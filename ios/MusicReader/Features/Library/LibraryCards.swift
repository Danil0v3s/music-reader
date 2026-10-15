import ScoreKit
import UIKit

/// "Pick up where you left off": the bars last played, drawn small, with a rosin playhead passing over them
/// while each note lights up in turn (a 6 s loop). Reduce Motion leaves the staff still.
final class NowPlayingCell: UICollectionViewCell {
    private let caption = UILabel()
    private let staff = MiniStaffView()
    private let title = UILabel()
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.chrome
        contentView.layer.cornerRadius = 20
        contentView.layer.cornerCurve = .continuous
        caption.attributedText = Fonts.labelText("Pick up where you left off", size: 10)
        title.font = Fonts.display(17, relativeTo: .headline)
        title.textColor = Theme.ink
        title.adjustsFontForContentSizeCategory = true
        detail.font = Fonts.ui(13, relativeTo: .footnote)
        detail.textColor = Theme.inkSoft
        detail.adjustsFontForContentSizeCategory = true
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bottom = UIStackView(arrangedSubviews: [title, detail])
        bottom.alignment = .firstBaseline
        bottom.spacing = 8
        let stack = UIStackView(arrangedSubviews: [caption, staff, bottom])
        stack.axis = .vertical
        stack.spacing = 8
        contentView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            staff.heightAnchor.constraint(equalToConstant: 72),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? Theme.selected : Theme.chrome }
    }

    func configure(score: Score, last: LastPlayed) {
        let part = score.parts[0]
        let count = part.measures.count
        let bars = last.loop ?? (min(last.startMeasure, max(0, count - 1))...min(last.startMeasure + 1, max(0, count - 1)))
        title.text = score.title
        let bpm = Int((part.attributes(at: bars.lowerBound).tempo.bpm * last.tempoScale).rounded())
        let where_ = bars.count == 1 ? "Bar \(bars.lowerBound + 1)" : "Bars \(bars.lowerBound + 1)–\(bars.upperBound + 1)"
        detail.text = "\(last.loop != nil ? "⟲ " : "")\(where_) · ♩ \(bpm)"
        staff.show(part: part, bars: bars)
        accessibilityLabel = "Pick up where you left off: \(score.title), \(where_.lowercased())\(last.loop != nil ? " on repeat" : "")"
    }
}

/// A few bars on one staff: clef, noteheads and stems, and the animated playhead.
final class MiniStaffView: UIView {
    private let lines = CAShapeLayer()
    private let clef = CATextLayer()
    private let playhead = CALayer()
    private var notes: [CAShapeLayer] = []
    /// Each note's centre, for timing its flash against the playhead.
    private var noteX: [CGFloat] = []
    private var barlines = CAShapeLayer()
    private var events: [(step: Int, hollow: Bool, barline: Bool)] = []
    private var clefGlyph = "\u{E062}"
    private var clefStep = 6
    private let period: CFTimeInterval = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        lines.fillColor = nil
        lines.lineWidth = 1
        barlines.fillColor = nil
        barlines.lineWidth = 1
        clef.contentsScale = UIScreen.main.scale
        clef.font = Fonts.bravura(28)
        clef.fontSize = 28
        playhead.cornerRadius = 1.5
        [lines, barlines, clef, playhead].forEach(layer.addSublayer)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MiniStaffView, _) in view.setNeedsLayout() }
        NotificationCenter.default.addObserver(self, selector: #selector(animate), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(animate), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(part: Part, bars: ClosedRange<Int>) {
        let attributes = part.attributes(at: bars.lowerBound)
        let c = attributes.clef
        switch c.sign {
        case .g: clefGlyph = "\u{E050}"
        case .c: clefGlyph = "\u{E05C}"
        default: clefGlyph = "\u{E062}"
        }
        clefStep = (c.line - 1) * 2
        events = []
        for (i, m) in bars.map({ part.measures[$0] }).enumerated() {
            if i > 0 { events.append((0, false, true)) }
            for n in m.notes where !n.isGrace && !n.isRest {
                events.append((c.staffStep(of: n.pitches[0]), n.duration.kind <= .half, false))
            }
        }
        // Keep it a glance: at most fourteen notes.
        var kept = 0
        events = events.prefix { e in if !e.barline { kept += 1 }; return kept <= 14 }
        if events.last?.barline == true { events.removeLast() }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let t = traitCollection
        let ink = Theme.ink.resolvedColor(with: t)
        let space: CGFloat = 8
        let w = bounds.width
        // Centre the staff and the notes together: high passages push the staff down, low ones up.
        let steps = events.filter { !$0.barline }.map(\.step)
        let low = min(steps.min() ?? 0, 0), high = max(steps.max() ?? 8, 8)
        let bottom = bounds.midY + CGFloat(low + high) / 2 * space / 2
        func y(_ step: Int) -> CGFloat { bottom - CGFloat(step) * space / 2 }

        let staffPath = UIBezierPath()
        for i in 0..<5 {
            staffPath.move(to: CGPoint(x: 0, y: y(i * 2)))
            staffPath.addLine(to: CGPoint(x: w, y: y(i * 2)))
        }
        lines.path = staffPath.cgPath
        lines.strokeColor = ink.withAlphaComponent(0.22).cgColor
        clef.string = NSAttributedString(string: clefGlyph, attributes: [.font: Fonts.bravura(32), .foregroundColor: ink.withAlphaComponent(0.6)])
        // A text layer puts the baseline one ascender below its top; SMuFL clefs sit on their line at the baseline.
        let font = Fonts.bravura(32)
        clef.frame = CGRect(x: 2, y: y(clefStep) - font.ascender, width: 30, height: font.lineHeight)

        notes.forEach { $0.removeFromSuperlayer() }
        notes = []
        noteX = []
        let start: CGFloat = 40
        let step = (w - start - 12) / CGFloat(max(1, events.count))
        let bars = UIBezierPath()
        for (i, e) in events.enumerated() {
            let x = start + step * (CGFloat(i) + 0.5)
            if e.barline {
                bars.move(to: CGPoint(x: x, y: y(0)))
                bars.addLine(to: CGPoint(x: x, y: y(8)))
                continue
            }
            let note = CAShapeLayer()
            let path = UIBezierPath()
            let head = UIBezierPath(ovalIn: CGRect(x: -5.2, y: -3.9, width: 10.4, height: 7.8))
            head.apply(CGAffineTransform(rotationAngle: -20 * .pi / 180))
            head.apply(CGAffineTransform(translationX: x, y: y(e.step)))
            path.append(head)
            // Stems down from the middle line up, as engraved.
            let down = e.step >= 4
            let sx = down ? x - 4.9 : x + 4.9
            let stem = UIBezierPath()
            stem.move(to: CGPoint(x: sx, y: y(e.step)))
            stem.addLine(to: CGPoint(x: sx, y: y(e.step) + (down ? 21 : -21)))
            // Ledger lines below and above the staff.
            for s in stride(from: -2, through: e.step, by: -2) where e.step <= -2 {
                stem.move(to: CGPoint(x: x - 8, y: y(s))); stem.addLine(to: CGPoint(x: x + 8, y: y(s)))
            }
            for s in stride(from: 10, through: e.step, by: 2) where e.step >= 10 {
                stem.move(to: CGPoint(x: x - 8, y: y(s))); stem.addLine(to: CGPoint(x: x + 8, y: y(s)))
            }
            note.lineWidth = 1.6
            note.path = path.cgPath
            let strokes = CAShapeLayer()
            strokes.path = stem.cgPath
            strokes.lineWidth = 1.4
            note.addSublayer(strokes)
            layer.insertSublayer(note, below: playhead)
            notes.append(note)
            noteX.append(x)
        }
        barlines.path = bars.cgPath
        barlines.strokeColor = ink.withAlphaComponent(0.3).cgColor
        playhead.backgroundColor = Theme.rosin.resolvedColor(with: t).cgColor
        playhead.frame = CGRect(x: start - 8, y: y(8) - 12, width: 3, height: y(0) - y(8) + 24)
        paint(ink)
        CATransaction.commit()
        animate()
    }

    private func paint(_ color: UIColor) {
        for (i, n) in notes.enumerated() {
            let hollow = events.filter { !$0.barline }[i].hollow
            n.fillColor = hollow ? nil : color.cgColor
            n.strokeColor = hollow ? color.cgColor : nil
            (n.sublayers?.first as? CAShapeLayer)?.strokeColor = color.cgColor
            (n.sublayers?.first as? CAShapeLayer)?.fillColor = nil
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        animate()
    }

    @objc private func animate() {
        playhead.removeAllAnimations()
        notes.forEach { n in n.removeAllAnimations(); n.sublayers?.forEach { $0.removeAllAnimations() } }
        let still = UIAccessibility.isReduceMotionEnabled || window == nil || notes.isEmpty
        playhead.isHidden = still
        guard !still else { return }

        let travel = bounds.width - playhead.frame.minX - 12
        let sweep = CAKeyframeAnimation(keyPath: "transform.translation.x")
        sweep.values = [0, travel, travel]
        sweep.keyTimes = [0, 0.9, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0, 0]
        fade.keyTimes = [0, 0.04, 0.9, 0.96, 1]
        let group = CAAnimationGroup()
        group.animations = [sweep, fade]
        group.duration = period
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        playhead.add(group, forKey: "sweep")

        // Each note lights in varnish as the playhead reaches it.
        let ink = Theme.ink.resolvedColor(with: traitCollection).cgColor
        let lit = Theme.accent.resolvedColor(with: traitCollection).cgColor
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let heads = events.filter { !$0.barline }
        for ((n, e), x) in zip(zip(notes, heads), noteX) {
            let delay = Double((x - playhead.frame.minX) / max(1, travel)) * period * 0.9
            for (target, key) in [(n, e.hollow ? "strokeColor" : "fillColor"), (n.sublayers?.first, "strokeColor")] {
                guard let target else { continue }
                let flash = CAKeyframeAnimation(keyPath: key)
                flash.values = [lit, lit, ink, ink]
                flash.keyTimes = [0, 0.18, 0.34, 1]
                flash.duration = period
                flash.beginTime = now + delay
                flash.repeatCount = .infinity
                flash.isRemovedOnCompletion = false
                target.add(flash, forKey: "flash")
            }
        }
    }
}

/// A collection as a tile: the number of scores in Poppins, varnish, over the name.
final class CollectionTileCell: UICollectionViewCell {
    private let count = UILabel()
    private let name = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.chrome
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        count.font = Fonts.display(26, relativeTo: .title2)
        count.textColor = Theme.accent
        count.adjustsFontForContentSizeCategory = true
        name.font = Fonts.ui(14, weight: .semibold, relativeTo: .subheadline)
        name.textColor = Theme.ink
        name.numberOfLines = 2
        name.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [count, UIView(), name])
        stack.axis = .vertical
        contentView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? Theme.selected : Theme.chrome }
    }

    func configure(name: String, count n: Int) {
        count.text = "\(n)"
        self.name.text = name
        accessibilityLabel = "\(name), \(n) score\(n == 1 ? "" : "s")"
    }
}
