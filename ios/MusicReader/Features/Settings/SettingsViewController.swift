import Combine
import ScoreKit
import UIKit

/// The account, the server, tuning (reference A and system), intonation tolerance, playback, and credits.
final class SettingsViewController: UITableViewController {
    private let settings: SettingsStore
    private let library: ScoreLibrary
    private let sync: SyncService
    private let account: AccountStore
    private let sample: () -> Score?
    private let onSignIn: () -> Void
    private let onSignOut: () -> Void
    private let onDeleteAccount: () -> Void
    private let onMyShares: () -> Void
    private var serverStatus = ""
    private var testing = false
    private var bag = Set<AnyCancellable>()

    private enum Section: Int, CaseIterable { case account, server, sync, tuning, intonation, playback, library, about }
    private enum AccountRow { case who, shares, signIn, signOut, delete }

    init(settings: SettingsStore, library: ScoreLibrary, sync: SyncService, account: AccountStore, sample: @escaping () -> Score?,
         onSignIn: @escaping () -> Void, onSignOut: @escaping () -> Void, onDeleteAccount: @escaping () -> Void,
         onMyShares: @escaping () -> Void) {
        self.onMyShares = onMyShares
        self.settings = settings
        self.library = library
        self.sync = sync
        self.account = account
        self.sample = sample
        self.onSignIn = onSignIn
        self.onSignOut = onSignOut
        self.onDeleteAccount = onDeleteAccount
        super.init(style: .insetGrouped)
        title = "Settings"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.keyboardDismissMode = .interactive
        sync.status.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.tableView.reloadSections([Section.sync.rawValue], with: .none)
        }.store(in: &bag)
        account.state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.tableView.reloadData() }.store(in: &bag)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await account.refreshUser() }
    }

    private var accountRows: [AccountRow] {
        guard let user = account.user else { return [.signIn] }
        return user.isGuest ? [.who, .shares, .signIn, .delete] : [.who, .shares, .signOut, .delete]
    }

    private var syncStatusText: String {
        switch sync.status.value {
        case .off: !settings.hasServer ? "Add the server address above first." : account.user == nil ? "Sign in first." : "Off"
        case .syncing: "Syncing…"
        case .idle(let last?): "Up to date · synced \(last.formatted(.relative(presentation: .named)))"
        case .idle(nil): "Not synced yet"
        case .failed(let message): "Couldn't sync: \(message)"
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .account: accountRows.count
        case .server: 2
        case .sync: 3
        case .tuning: 2
        case .intonation: 2
        case .playback: 2
        case .library: 1
        case .about: 3
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .account: "Account"
        case .server: "Server"
        case .sync: "Library on the Server"
        case .tuning: "Tuning"
        case .intonation: "Intonation Practice"
        case .playback: "Playback"
        case .library: "Library"
        case .about: "About"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .account:
            account.user?.isGuest == true
                ? "You're using Music Reader as a guest: your scores are kept for this iPhone only. Sign in to keep them on all your devices; nothing is lost."
                : nil
        case .server:
            "The Music Reader server keeps your library and reads PDFs and scans (Audiveris). Enter its address, e.g. 192.168.1.20:8765." + (serverStatus.isEmpty ? "" : "\n\n" + serverStatus)
        case .sync: "Your scores, their originals and your collections are kept in your account on the server, so they're backed up and the same on every device. Deleting a score deletes it everywhere."
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
        if Section(rawValue: indexPath.section) == .account {
            return accountCell(accountRows[indexPath.row])
        }
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.server, 0):
            return fieldCell(placeholder: "Server address", text: s.serverAddress, secure: false, keyboard: .URL) { [weak self] text in
                self?.settings.update { $0.serverAddress = text.trimmingCharacters(in: .whitespaces) }
                self?.serverStatus = ""
            }
        case (.server, 1):
            content = .cell()
            content.text = testing ? "Testing…" : "Test Connection"
            content.textProperties.color = Theme.accent
            cell.selectionStyle = .default
        case (.sync, 0):
            content.text = "Keep library on the server"
            let toggle = UISwitch()
            toggle.isOn = s.syncLibrary
            toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.settings.update { $0.syncLibrary = toggle?.isOn ?? true } }, for: .valueChanged)
            cell.accessoryView = toggle
        case (.sync, 1):
            content = .subtitleCell()
            content.text = "Status"
            content.secondaryText = syncStatusText
            content.secondaryTextProperties.color = { if case .failed = sync.status.value { .systemRed } else { .secondaryLabel } }()
            content.secondaryTextProperties.numberOfLines = 0
        case (.sync, 2):
            content = .cell()
            content.text = "Sync Now"
            content.textProperties.color = s.syncLibrary && settings.hasServer && account.user != nil ? Theme.accent : .tertiaryLabel
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
        case (.playback, 1):
            content = .subtitleCell()
            content.text = "Recorded cello"
            content.secondaryText = "Real bowed notes (University of Iowa samples). Off: a synthesised tone."
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            let toggle = UISwitch()
            toggle.isOn = s.recordedCello
            toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.settings.update { $0.recordedCello = toggle?.isOn ?? true } }, for: .valueChanged)
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
        case (.about, 2):
            content = .subtitleCell()
            content.text = "Cello recordings"
            content.secondaryText = "University of Iowa Electronic Music Studios, Musical Instrument Samples · free to use without restrictions"
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
        if Section(rawValue: indexPath.section) == .account {
            switch accountRows[indexPath.row] {
            case .who: break
            case .shares: onMyShares()
            case .signIn: onSignIn()
            case .signOut: onSignOut()
            case .delete: onDeleteAccount()
            }
            return
        }
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.server, 1): testConnection()
        case (.sync, 2): sync.syncNow()
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
        guard let config = account.config else {
            serverStatus = "Enter the server's address first."
            tableView.reloadSections([Section.server.rawValue], with: .none)
            return
        }
        testing = true
        tableView.reloadSections([Section.server.rawValue], with: .none)
        Task { @MainActor in
            do {
                let info = try await OMRClient(config: config).health()
                serverStatus = "✓ Connected to Music Reader at \(config.baseURL.absoluteString) (\(info.engine.capitalized) \(info.version))"
            } catch {
                serverStatus = "✕ " + (error.localizedDescription)
            }
            testing = false
            tableView.reloadSections([Section.server.rawValue], with: .none)
        }
    }

    // MARK: Cells

    private func accountCell(_ row: AccountRow) -> UITableViewCell {
        let cell = UITableViewCell()
        var content = UIListContentConfiguration.cell()
        switch row {
        case .who:
            content = .subtitleCell()
            let user = account.user
            content.text = user?.label
            var detail: [String] = []
            if let email = user?.email, user?.displayName.isEmpty == false || user?.isGuest == false, email != user?.label { detail.append(email) }
            if user?.isGuest == false, user?.email != nil, user?.emailVerified == false, user?.providers.contains("email") == true {
                detail.append("check your inbox to confirm the address")
            }
            let names = ["apple": "Apple", "google": "Google", "email": "email and password"]
            if let providers = user?.providers, !providers.isEmpty {
                detail.append("signs in with " + providers.compactMap { names[$0] }.formatted(.list(type: .and)))
            }
            content.secondaryText = user?.isGuest == true ? "No sign-in yet" : detail.joined(separator: " · ")
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: user?.isGuest == true ? "person.crop.circle.badge.questionmark" : "person.crop.circle.fill")
            cell.selectionStyle = .none
        case .shares:
            content.text = "Shared by Me"
            content.image = UIImage(systemName: "person.2")
            cell.accessoryType = .disclosureIndicator
        case .signIn:
            content.text = account.user?.isGuest == true ? "Sign In or Create Account" : "Sign In"
            content.textProperties.color = Theme.accent
        case .signOut:
            content.text = "Sign Out"
            content.textProperties.color = Theme.accent
        case .delete:
            content.text = account.user?.isGuest == true ? "Delete Guest Account…" : "Delete Account…"
            content.textProperties.color = .systemRed
        }
        cell.contentConfiguration = content
        return cell
    }

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
