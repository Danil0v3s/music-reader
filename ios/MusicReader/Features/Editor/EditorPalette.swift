import ScoreKit
import UIKit

@MainActor
protocol EditorPaletteDelegate: AnyObject {
    func palette(setValue kind: NoteValue.Kind)
    func paletteToggleDot()
    func paletteToggleTriplet()
    func paletteToggleRest()
    func palette(accidental alter: Int)
    func palette(step: Int)
    func paletteToggleTie()
    func paletteCycleSlur()
    func palette(doubleStop interval: Int?)
    func palette(toggle articulation: Articulation)
    func palette(bowing: Bowing)
    func palette(finger: Int?)
    func palette(string: CelloString?)
    func palette(dynamic: Dynamic?)
    func palette(wedge: Wedge?)
    func paletteDelete()
    func paletteUndo()
    func paletteRedo()
}

/// The editor's input panel: note values, pitch and accidentals, and a scrolling row of markings.
final class EditorPalette: UIView {
    weak var delegate: EditorPaletteDelegate?

    private let status = UILabel()
    private let detail = UILabel()
    private var valueButtons: [NoteValue.Kind: UIButton] = [:]
    private let dot = UIButton()
    private let triplet = UIButton()
    private let rest = UIButton()
    private let tie = UIButton()
    private let slur = UIButton()
    private let downBow = UIButton()
    private let upBow = UIButton()
    private var articulationButtons: [Articulation: UIButton] = [:]
    private var needsSelection: [UIButton] = []
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.chrome
        let hairline = UIView()
        hairline.backgroundColor = .separator

        status.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .right
        undoButton.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        redoButton.setImage(UIImage(systemName: "arrow.uturn.forward"), for: .normal)
        undoButton.accessibilityLabel = "Undo"
        redoButton.accessibilityLabel = "Redo"
        undoButton.addAction(UIAction { [weak self] _ in self?.delegate?.paletteUndo() }, for: .primaryActionTriggered)
        redoButton.addAction(UIAction { [weak self] _ in self?.delegate?.paletteRedo() }, for: .primaryActionTriggered)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [status, detail, undoButton, redoButton])
        header.spacing = 12

        // Row 1: values.
        let kinds: [NoteValue.Kind] = [.whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond]
        var valueRow: [UIView] = []
        for k in kinds {
            let b = button(music: k.paletteGlyph, label: "\(k.name) note") { [weak self] in self?.delegate?.palette(setValue: k) }
            valueButtons[k] = b
            valueRow.append(b)
        }
        configure(dot, music: "\u{E1E7}", label: "Dotted") { [weak self] in self?.delegate?.paletteToggleDot() }
        configure(triplet, text: "3", label: "Triplet") { [weak self] in self?.delegate?.paletteToggleTriplet() }
        configure(rest, music: "\u{E4E5}", label: "Rest") { [weak self] in self?.delegate?.paletteToggleRest() }
        valueRow += [divider(), dot, triplet, rest]

        // Row 2: pitch.
        let flat = button(music: "\u{E260}", label: "Flat") { [weak self] in self?.delegate?.palette(accidental: -1) }
        let natural = button(music: "\u{E261}", label: "Natural") { [weak self] in self?.delegate?.palette(accidental: 0) }
        let sharp = button(music: "\u{E262}", label: "Sharp") { [weak self] in self?.delegate?.palette(accidental: 1) }
        let up = button(symbol: "chevron.up", label: "Step up") { [weak self] in self?.delegate?.palette(step: 1) }
        let down = button(symbol: "chevron.down", label: "Step down") { [weak self] in self?.delegate?.palette(step: -1) }
        let octUp = button(symbol: "chevron.up.2", label: "Octave up") { [weak self] in self?.delegate?.palette(step: 7) }
        let octDown = button(symbol: "chevron.down.2", label: "Octave down") { [weak self] in self?.delegate?.palette(step: -7) }
        configure(tie, music: "\u{E1FD}", label: "Tie") { [weak self] in self?.delegate?.paletteToggleTie() }
        let delete = button(symbol: "delete.left", label: "Delete") { [weak self] in self?.delegate?.paletteDelete() }
        delete.configuration?.baseForegroundColor = .systemRed
        needsSelection = [flat, natural, sharp, up, down, octUp, octDown, tie]
        let pitchRow: [UIView] = [flat, natural, sharp, divider(), down, up, octDown, octUp, divider(), tie, delete]

        // Row 3: markings, scrolling.
        configure(slur, text: "Slur", label: "Slur start or end") { [weak self] in self?.delegate?.paletteCycleSlur() }
        configure(downBow, music: "\u{E610}", label: "Down-bow") { [weak self] in self?.delegate?.palette(bowing: .down) }
        configure(upBow, music: "\u{E612}", label: "Up-bow") { [weak self] in self?.delegate?.palette(bowing: .up) }
        var marks: [UIView] = [slur, downBow, upBow]
        let arts: [(Articulation, String, String)] = [(.staccato, "\u{E4A2}", "Staccato"), (.accent, "\u{E4A0}", "Accent"), (.tenuto, "\u{E4A4}", "Tenuto"),
                                                      (.marcato, "\u{E4AC}", "Marcato"), (.fermata, "\u{E4C0}", "Fermata")]
        for (a, glyph, name) in arts {
            let b = button(music: glyph, label: name) { [weak self] in self?.delegate?.palette(toggle: a) }
            articulationButtons[a] = b
            marks.append(b)
        }
        marks.append(menuChip("Finger", [
            UIAction(title: "Open string (0)") { [weak self] _ in self?.delegate?.palette(finger: 0) },
        ] + (1...4).map { (f: Int) in UIAction(title: "\(f)") { [weak self] _ in self?.delegate?.palette(finger: f) } } + [
            UIAction(title: "Thumb") { [weak self] _ in self?.delegate?.palette(finger: 5) },
            UIAction(title: "Clear", attributes: .destructive) { [weak self] _ in self?.delegate?.palette(finger: nil) },
        ]))
        marks.append(menuChip("String", CelloString.allCases.map { s in
            UIAction(title: "\(s.roman) · \(s.pitch.name) string") { [weak self] _ in self?.delegate?.palette(string: s) }
        } + [UIAction(title: "Clear", attributes: .destructive) { [weak self] _ in self?.delegate?.palette(string: nil) }]))
        marks.append(menuChip("Double Stop", [(3, "Third"), (4, "Fourth"), (5, "Fifth"), (6, "Sixth"), (8, "Octave")].map { n, name in
            UIAction(title: "Add a \(name.lowercased()) above") { [weak self] _ in self?.delegate?.palette(doubleStop: n) }
        } + [UIAction(title: "Single note", attributes: .destructive) { [weak self] _ in self?.delegate?.palette(doubleStop: nil) }]))
        marks.append(menuChip("Dynamic", Dynamic.allCases.filter { ![.fz].contains($0) }.map { d in
            UIAction(title: d.rawValue) { [weak self] _ in self?.delegate?.palette(dynamic: d) }
        } + [UIAction(title: "Remove", attributes: .destructive) { [weak self] _ in self?.delegate?.palette(dynamic: nil) }]))
        marks.append(menuChip("Hairpin", [
            UIAction(title: "Crescendo starts here") { [weak self] _ in self?.delegate?.palette(wedge: .crescendo) },
            UIAction(title: "Diminuendo starts here") { [weak self] _ in self?.delegate?.palette(wedge: .diminuendo) },
            UIAction(title: "Hairpin ends here") { [weak self] _ in self?.delegate?.palette(wedge: .stop) },
            UIAction(title: "Remove", attributes: .destructive) { [weak self] _ in self?.delegate?.palette(wedge: nil) },
        ]))
        needsSelection += marks.compactMap { $0 as? UIButton }

        for m in marks { m.setContentHuggingPriority(.required, for: .horizontal); m.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let markStack = UIStackView(arrangedSubviews: marks)
        markStack.spacing = 6
        markStack.alignment = .center
        let markScroll = UIScrollView()
        markScroll.showsHorizontalScrollIndicator = false
        markScroll.addSubview(markStack)
        markStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            markStack.topAnchor.constraint(equalTo: markScroll.contentLayoutGuide.topAnchor),
            markStack.bottomAnchor.constraint(equalTo: markScroll.contentLayoutGuide.bottomAnchor),
            markStack.leadingAnchor.constraint(equalTo: markScroll.contentLayoutGuide.leadingAnchor),
            markStack.trailingAnchor.constraint(equalTo: markScroll.contentLayoutGuide.trailingAnchor),
            markStack.heightAnchor.constraint(equalTo: markScroll.frameLayoutGuide.heightAnchor),
            markScroll.heightAnchor.constraint(equalToConstant: 40),
        ])

        let row1 = row(valueRow)
        let row2 = row(pitchRow)
        let column = UIStackView(arrangedSubviews: [header, row1, row2, markScroll])
        column.axis = .vertical
        column.spacing = 8
        addSubview(hairline)
        addSubview(column)
        [hairline, column].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(input: NoteValue, rest restMode: Bool, selected: NoteEvent?, status: String, detail: String) {
        self.status.text = status
        self.status.textColor = status.contains("too long") ? .systemRed : status.contains("still") ? .systemOrange : .label
        self.detail.text = detail
        let shown = selected?.duration ?? input
        for (k, b) in valueButtons { setOn(b, shown.kind == k) }
        setOn(dot, shown.dots > 0)
        setOn(triplet, shown.tuplet != nil)
        setOn(rest, selected.map(\.isRest) ?? restMode)
        setOn(tie, selected?.tieToNext == true)
        setOn(downBow, selected?.bowing == .down)
        setOn(upBow, selected?.bowing == .up)
        for (a, b) in articulationButtons { setOn(b, selected?.articulations.contains(a) == true) }
        let slurState = selected.map { $0.slurStart ? "Slur (" : $0.slurStop ? "Slur )" : "Slur" } ?? "Slur"
        slur.configuration?.title = slurState
        setOn(slur, selected.map { $0.slurStart || $0.slurStop } ?? false)
        for b in needsSelection { b.isEnabled = selected != nil && (selected?.isRest == false || b === rest) }
    }

    func setUndo(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    // MARK: Building

    private func row(_ views: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.spacing = 4
        s.distribution = .fill
        s.alignment = .center
        return s
    }

    private func divider() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return v
    }

    private func base() -> UIButton.Configuration {
        var c = UIButton.Configuration.gray()
        c.cornerStyle = .medium
        c.baseForegroundColor = .label
        c.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        return c
    }

    private func button(music: String? = nil, text: String? = nil, symbol: String? = nil, label: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton()
        configure(b, music: music, text: text, symbol: symbol, label: label, action: action)
        return b
    }

    private func configure(_ b: UIButton, music: String? = nil, text: String? = nil, symbol: String? = nil, label: String, action: @escaping () -> Void) {
        var c = base()
        if let music {
            c.attributedTitle = AttributedString(music, attributes: AttributeContainer([.font: Fonts.bravura(26)]))
            c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        } else if let text {
            c.title = text
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in var a = a; a.font = Fonts.serif(17, weight: .semibold, italic: text == "3"); return a }
        } else if let symbol {
            c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        }
        b.configuration = c
        b.accessibilityLabel = label
        b.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
    }

    private func menuChip(_ title: String, _ actions: [UIAction]) -> UIButton {
        var c = base()
        c.title = title
        c.indicator = .popup
        let b = UIButton(configuration: c)
        b.menu = UIMenu(children: actions)
        b.showsMenuAsPrimaryAction = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    private func setOn(_ b: UIButton, _ on: Bool) {
        b.configuration?.baseBackgroundColor = on ? Theme.accent : nil
        b.configuration?.baseForegroundColor = on ? .white : .label
        b.accessibilityTraits = on ? [.button, .selected] : .button
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
