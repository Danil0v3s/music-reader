import ScoreKit
import UIKit

/// Starting a score from scratch: title, clef, key, meter, tempo and length.
final class NewScoreViewController: UITableViewController {
    private let onCreate: (Score) -> Void
    private var title_ = ""
    private var composer = ""
    private var clef = Clef.bass
    private var key = KeySignature.cMajor
    private var time = TimeSignature(4, 4)
    private var bpm = 80.0
    private var measures = 8

    init(onCreate: @escaping (Score) -> Void) {
        self.onCreate = onCreate
        super.init(style: .insetGrouped)
        title = "New Score"
    }

    required init?(coder: NSCoder) { fatalError() }

    private enum Row { case title, composer, clef, key, time, tempo, measures }
    private let sections: [[Row]] = [[.title, .composer], [.clef, .key, .time], [.tempo, .measures]]

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Create", style: .prominent, target: self, action: #selector(create))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    @objc private func create() {
        view.endEditing(true)
        var score = Score.blank(title: title_.isEmpty ? "Untitled" : title_, clef: clef, key: key, time: time,
                                tempo: Tempo(bpm: bpm, text: TempoMarking.closest(toQuarterBPM: bpm).rawValue), measures: measures)
        score.composer = composer
        onCreate(score)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 1: "Cello music uses bass clef, tenor clef for the upper register and treble for the highest passages. You can change clef, key and meter at any bar later."
        case 2: "\(TempoMarking.closest(toQuarterBPM: bpm).rawValue): \(Int(TempoMarking.closest(toQuarterBPM: bpm).range.lowerBound))–\(Int(TempoMarking.closest(toQuarterBPM: bpm).range.upperBound)) beats per minute."
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        cell.selectionStyle = .none
        switch sections[indexPath.section][indexPath.row] {
        case .title, .composer:
            let isTitle = sections[indexPath.section][indexPath.row] == .title
            let field = UITextField()
            field.placeholder = isTitle ? "Title" : "Composer (optional)"
            field.text = isTitle ? title_ : composer
            field.font = isTitle ? Fonts.display(20, weight: .bold) : .preferredFont(forTextStyle: .body)
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
            field.addAction(UIAction { [weak self, weak field] _ in
                if isTitle { self?.title_ = field?.text ?? "" } else { self?.composer = field?.text ?? "" }
            }, for: .editingChanged)
            field.addAction(UIAction { [weak field] _ in field?.resignFirstResponder() }, for: .editingDidEndOnExit)
            cell.contentView.addSubview(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            ])
            if isTitle, title_.isEmpty { DispatchQueue.main.async { field.becomeFirstResponder() } }
            return cell
        case .clef:
            content.text = "Clef"
            cell.accessoryView = menuButton(clef.name, Clef.common.map { c in
                UIAction(title: c.name, state: c == clef ? .on : .off) { [weak self] _ in self?.clef = c; self?.tableView.reloadData() }
            })
        case .key:
            content.text = "Key"
            cell.accessoryView = menuButton(key.name, KeyPicker.menu(selected: key) { [weak self] k in self?.key = k; self?.tableView.reloadData() })
        case .time:
            content.text = "Time"
            let options = [TimeSignature(4, 4), TimeSignature(3, 4), TimeSignature(2, 4), TimeSignature(6, 8), TimeSignature(2, 2), TimeSignature(3, 8), TimeSignature(9, 8), TimeSignature(12, 8), TimeSignature(5, 4)]
            cell.accessoryView = menuButton(time.description, options.map { t in
                UIAction(title: t.description, subtitle: t.isCompound ? "\(t.beatsPerMeasure) dotted-quarter beats" : nil, state: t == time ? .on : .off) { [weak self] _ in
                    self?.time = t; self?.tableView.reloadData()
                }
            })
        case .tempo:
            content.text = "Tempo"
            content.secondaryText = "♩ = \(Int(bpm))"
            let stepper = UIStepper()
            stepper.minimumValue = 30
            stepper.maximumValue = 240
            stepper.stepValue = 4
            stepper.value = bpm
            stepper.addAction(UIAction { [weak self, weak stepper] _ in self?.bpm = stepper?.value ?? 80; self?.tableView.reloadSections([2], with: .none) }, for: .valueChanged)
            cell.accessoryView = stepper
        case .measures:
            content.text = "Bars"
            content.secondaryText = "\(measures)"
            let stepper = UIStepper()
            stepper.minimumValue = 1
            stepper.maximumValue = 200
            stepper.value = Double(measures)
            stepper.addAction(UIAction { [weak self, weak stepper] _ in self?.measures = Int(stepper?.value ?? 8); self?.tableView.reloadSections([2], with: .none) }, for: .valueChanged)
            cell.accessoryView = stepper
        }
        cell.contentConfiguration = content
        return cell
    }

    private func menuButton(_ title: String, _ actions: [UIMenuElement]) -> UIButton {
        var c = UIButton.Configuration.gray()
        c.title = title
        c.indicator = .popup
        let b = UIButton(configuration: c)
        b.menu = UIMenu(children: actions)
        b.showsMenuAsPrimaryAction = true
        b.sizeToFit()
        return b
    }
}

/// The 30 key signatures as a menu: major and relative minor, sharps then flats.
enum KeyPicker {
    static func menu(selected: KeySignature, onPick: @escaping (KeySignature) -> Void) -> [UIMenuElement] {
        let sharps = (0...7).map { KeySignature(fifths: $0) }
        let flats = (1...7).map { KeySignature(fifths: -$0) }
        func group(_ title: String, _ keys: [KeySignature]) -> UIMenu {
            UIMenu(title: title, options: .displayInline, children: keys.flatMap { k -> [UIAction] in
                let minor = KeySignature(fifths: k.fifths, mode: .minor)
                let count = k.fifths == 0 ? "no sharps or flats" : "\(abs(k.fifths)) \(k.fifths > 0 ? "sharp" : "flat")\(abs(k.fifths) == 1 ? "" : "s")"
                return [
                    UIAction(title: k.name, subtitle: count, state: k == selected ? .on : .off) { _ in onPick(k) },
                    UIAction(title: minor.name, subtitle: count, state: minor == selected ? .on : .off) { _ in onPick(minor) },
                ]
            })
        }
        return [group("Sharps", sharps), group("Flats", flats)]
    }
}
