import ScoreKit
import UIKit

/// Recognition server, tuning (reference A and system), intonation tolerance, playback, and credits.
final class SettingsViewController: UITableViewController {
    private let settings: SettingsStore
    private let library: ScoreLibrary
    private let sample: () -> Score?
    private var serverStatus = ""
    private var testing = false

    private enum Section: Int, CaseIterable { case server, tuning, intonation, playback, library, about }

    init(settings: SettingsStore, library: ScoreLibrary, sample: @escaping () -> Score?) {
        self.settings = settings
        self.library = library
        self.sample = sample
        super.init(style: .insetGrouped)
        title = "Settings"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.keyboardDismissMode = .interactive
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .server: 3
        case .tuning: 2
        case .intonation: 2
        case .playback: 1
        case .library: 1
        case .about: 2
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .server: "Recognition Server"
        case .tuning: "Tuning"
        case .intonation: "Intonation Practice"
        case .playback: "Playback"
        case .library: "Library"
        case .about: "About"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .server:
            "PDFs and scans are read by Audiveris on your own server (the music-reader-omr Docker image). Enter its address, e.g. 192.168.1.20:8765." + (serverStatus.isEmpty ? "" : "\n\n" + serverStatus)
        case .tuning: settings.value.tuning.system.summary
        case .intonation: "A note within the first range counts as in tune and within the second as close. 5–10 cents is a demanding standard."
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        cell.selectionStyle = .none
        let s = settings.value
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.server, 0):
            return fieldCell(placeholder: "Server address", text: s.serverAddress, secure: false, keyboard: .URL) { [weak self] text in
                self?.settings.update { $0.serverAddress = text.trimmingCharacters(in: .whitespaces) }
                self?.serverStatus = ""
            }
        case (.server, 1):
            return fieldCell(placeholder: "Token (if the server needs one)", text: settings.token ?? "", secure: true, keyboard: .default) { [weak self] text in
                self?.settings.token = text
            }
        case (.server, 2):
            content = .cell()
            content.text = testing ? "Testing…" : "Test Connection"
            content.textProperties.color = Theme.accent
            cell.selectionStyle = .default
        case (.tuning, 0):
            content.text = "Reference A"
            content.secondaryText = String(format: "A = %g Hz", s.tuning.referenceA4)
            let stepper = UIStepper()
            stepper.minimumValue = 415
            stepper.maximumValue = 466
            stepper.value = s.tuning.referenceA4
            stepper.addAction(UIAction { [weak self, weak stepper] _ in
                self?.settings.update { $0.tuning.referenceA4 = stepper?.value ?? 440 }
                self?.tableView.reloadRows(at: [indexPath], with: .none)
            }, for: .valueChanged)
            cell.accessoryView = stepper
        case (.tuning, 1):
            content.text = "System"
            cell.accessoryView = menuButton(s.tuning.system.name, Tuning.System.allCases.map { sys in
                UIAction(title: sys.name, subtitle: sys.summary, state: sys == s.tuning.system ? .on : .off) { [weak self] _ in
                    self?.settings.update { $0.tuning.system = sys }
                    self?.tableView.reloadSections([Section.tuning.rawValue], with: .none)
                }
            })
        case (.intonation, 0):
            content.text = "In tune within"
            content.secondaryText = "±\(Int(s.thresholds.inTune)) ¢"
            cell.accessoryView = stepper(value: s.thresholds.inTune, range: 2...20, step: 1) { [weak self] v in
                self?.settings.update { $0.thresholds.inTune = v; $0.thresholds.close = max($0.thresholds.close, v + 1) }
                self?.tableView.reloadSections([Section.intonation.rawValue], with: .none)
            }
        case (.intonation, 1):
            content.text = "Close within"
            content.secondaryText = "±\(Int(s.thresholds.close)) ¢"
            cell.accessoryView = stepper(value: s.thresholds.close, range: 5...45, step: 5) { [weak self] v in
                self?.settings.update { $0.thresholds.close = max(v, $0.thresholds.inTune + 1) }
                self?.tableView.reloadSections([Section.intonation.rawValue], with: .none)
            }
        case (.playback, 0):
            content.text = "Count-in bar with the metronome"
            let toggle = UISwitch()
            toggle.isOn = s.countIn
            toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.settings.update { $0.countIn = toggle?.isOn ?? true } }, for: .valueChanged)
            cell.accessoryView = toggle
        case (.library, 0):
            content = .cell()
            content.text = "Add the Sample Étude"
            content.textProperties.color = Theme.accent
            cell.selectionStyle = .default
        case (.about, 0):
            content = .subtitleCell()
            content.text = "Bravura music font"
            content.secondaryText = "© Steinberg Media Technologies, SIL Open Font License 1.1"
            content.secondaryTextProperties.color = .secondaryLabel
        case (.about, 1):
            content = .subtitleCell()
            content.text = "Audiveris optical music recognition"
            content.secondaryText = "Runs on your server · AGPL-3.0 · github.com/Audiveris/audiveris"
            content.secondaryTextProperties.color = .secondaryLabel
        default: break
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.server, 2): testConnection()
        case (.library, 0):
            if let score = sample() { try? library.save(score) }
            let a = UIAlertController(title: "Added", message: "“Étude in D” is in your library.", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
        default: break
        }
    }

    private func testConnection() {
        view.endEditing(true)
        guard let config = settings.omrConfig else {
            serverStatus = "Enter the server's address first."
            tableView.reloadSections([0], with: .none)
            return
        }
        testing = true
        tableView.reloadSections([0], with: .none)
        Task { @MainActor in
            do {
                let info = try await OMRClient(config: config).health()
                serverStatus = "✓ Connected to \(info.engine.capitalized) \(info.version) at \(config.baseURL.absoluteString)" + (info.auth ? " (token required)" : "")
            } catch {
                serverStatus = "✕ " + (error.localizedDescription)
            }
            testing = false
            tableView.reloadSections([0], with: .none)
        }
    }

    // MARK: Cells

    private func fieldCell(placeholder: String, text: String, secure: Bool, keyboard: UIKeyboardType, onChange: @escaping (String) -> Void) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        let field = UITextField()
        field.placeholder = placeholder
        field.text = text
        field.isSecureTextEntry = secure
        field.keyboardType = keyboard
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.addAction(UIAction { [weak field] _ in onChange(field?.text ?? "") }, for: .editingChanged)
        field.addAction(UIAction { [weak field] _ in field?.resignFirstResponder() }, for: .editingDidEndOnExit)
        cell.contentView.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 11),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -11),
        ])
        return cell
    }

    private func stepper(value: Double, range: ClosedRange<Double>, step: Double, onChange: @escaping (Double) -> Void) -> UIStepper {
        let s = UIStepper()
        s.minimumValue = range.lowerBound
        s.maximumValue = range.upperBound
        s.stepValue = step
        s.value = value
        s.addAction(UIAction { [weak s] _ in onChange(s?.value ?? value) }, for: .valueChanged)
        return s
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
