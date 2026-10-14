import AuthenticationServices
import ScoreKit
import UIKit

/// Signing in: with Apple, Google (when set up), email and password, or as a guest.
///
/// Shown at launch when nobody is signed in (`.welcome`), and from Settings for a guest who wants to keep
/// their library on all their devices (`.upgrade`): then the guest's session goes along with the sign-in,
/// so the server attaches the new sign-in method to the guest's account (or moves the guest's scores into
/// the account they sign in to).
final class SignInViewController: UIViewController {
    enum Mode { case welcome, upgrade }

    private let mode: Mode
    private let account: AccountStore
    private let settings: SettingsStore
    private let onDone: () -> Void

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let serverField = UITextField()
    private let serverRow = UIStackView()
    private let changeServer = UIButton(type: .system)
    private let modeControl = UISegmentedControl(items: ["Sign in", "Create account"])
    private let nameField = UITextField()
    private let emailField = UITextField()
    private let passwordField = UITextField()
    private let primary = UIButton(type: .system)
    private let forgot = UIButton(type: .system)
    private let errorLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var controls: [UIControl] = []
    private let apple = AppleSignIn()
    private let google = GoogleSignIn()

    init(mode: Mode, account: AccountStore, settings: SettingsStore, onDone: @escaping () -> Void) {
        self.mode = mode
        self.account = account
        self.settings = settings
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = mode == .welcome
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper
        if mode == .upgrade {
            title = "Keep Your Library"
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        }
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.addSubview(stack)
        stack.axis = .vertical
        stack.spacing = 12
        [scroll, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            // The keyboard never covers the form: the scroll view ends where it starts.
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: mode == .welcome ? 56 : 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        build()
    }

    // MARK: Layout

    private func build() {
        let heading = UILabel()
        heading.font = Fonts.serif(mode == .welcome ? 34 : 26, weight: .semibold)
        heading.text = mode == .welcome ? "Music Reader" : "Sign in to keep your library"
        heading.numberOfLines = 0
        let lead = label(mode == .welcome
            ? "Read, play and practise your sheet music. Sign in to keep your scores on all your devices."
            : "Your scores move into the account you sign in to, and you'll find them on every device you sign in on.",
            style: .body, color: .secondaryLabel)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(lead)
        stack.setCustomSpacing(24, after: lead)

        // The server: asked for when there isn't one; otherwise tucked away behind "Change".
        serverField.placeholder = "Server address, e.g. 192.168.1.20:8765"
        serverField.text = settings.value.serverAddress
        style(serverField, content: .URL, keyboard: .URL)
        serverField.addAction(UIAction { [weak self] _ in
            self?.settings.update { $0.serverAddress = self?.serverField.text?.trimmingCharacters(in: .whitespaces) ?? "" }
        }, for: .editingChanged)
        serverRow.axis = .vertical
        serverRow.spacing = 6
        serverRow.addArrangedSubview(label("Music Reader server", style: .footnote, color: .secondaryLabel))
        serverRow.addArrangedSubview(serverField)
        serverRow.isHidden = settings.hasServer
        stack.addArrangedSubview(serverRow)

        let appleButton = ASAuthorizationAppleIDButton(type: .signIn, style: traitCollection.userInterfaceStyle == .dark ? .white : .black)
        appleButton.cornerRadius = 25
        appleButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        appleButton.addAction(UIAction { [weak self] _ in self?.signInWithApple() }, for: .touchUpInside)
        stack.addArrangedSubview(appleButton)
        controls.append(appleButton)

        if GoogleSignIn.clientID != nil {
            var c = UIButton.Configuration.bordered()
            c.title = "Continue with Google"
            c.cornerStyle = .capsule
            c.baseForegroundColor = .label
            let googleButton = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.signInWithGoogle() })
            googleButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
            stack.addArrangedSubview(googleButton)
            controls.append(googleButton)
        }

        let or = label("or with your email", style: .footnote, color: .secondaryLabel)
        or.textAlignment = .center
        stack.addArrangedSubview(or)

        modeControl.selectedSegmentIndex = 0
        modeControl.addAction(UIAction { [weak self] _ in self?.modeChanged() }, for: .valueChanged)
        stack.addArrangedSubview(modeControl)
        nameField.placeholder = "Your name (optional)"
        style(nameField, content: .name, keyboard: .default)
        nameField.autocapitalizationType = .words
        emailField.placeholder = "Email"
        style(emailField, content: .emailAddress, keyboard: .emailAddress)
        passwordField.placeholder = "Password"
        style(passwordField, content: .password, keyboard: .default)
        passwordField.isSecureTextEntry = true
        passwordField.returnKeyType = .go
        passwordField.addAction(UIAction { [weak self] _ in self?.submitEmail() }, for: .editingDidEndOnExit)
        [nameField, emailField, passwordField].forEach(stack.addArrangedSubview)
        controls += [modeControl, nameField, emailField, passwordField]

        var p = UIButton.Configuration.filled()
        p.cornerStyle = .capsule
        p.baseBackgroundColor = Theme.accent
        primary.configuration = p
        primary.heightAnchor.constraint(equalToConstant: 50).isActive = true
        primary.addAction(UIAction { [weak self] _ in self?.submitEmail() }, for: .touchUpInside)
        stack.addArrangedSubview(primary)
        forgot.setTitle("Forgot your password?", for: .normal)
        forgot.addAction(UIAction { [weak self] _ in self?.forgotPassword() }, for: .touchUpInside)
        stack.addArrangedSubview(forgot)
        controls += [primary, forgot]

        errorLabel.font = .preferredFont(forTextStyle: .callout)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(spinner)

        if mode == .welcome {
            var g = UIButton.Configuration.plain()
            g.title = "Continue as guest"
            g.baseForegroundColor = Theme.accent
            let guest = UIButton(configuration: g, primaryAction: UIAction { [weak self] _ in self?.continueAsGuest() })
            stack.setCustomSpacing(28, after: spinner)
            stack.addArrangedSubview(guest)
            stack.addArrangedSubview(label("No account needed. Your scores are kept for this iPhone; create an account any time to keep them on all your devices.",
                                           style: .footnote, color: .secondaryLabel))
            controls.append(guest)
        }

        if settings.hasServer {
            changeServer.setTitle("Server: \(settings.value.serverAddress) · Change", for: .normal)
            changeServer.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            changeServer.tintColor = .secondaryLabel
            changeServer.addAction(UIAction { [weak self] _ in
                self?.serverRow.isHidden = false
                self?.changeServer.isHidden = true
            }, for: .touchUpInside)
            stack.addArrangedSubview(changeServer)
        }
        modeChanged()
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .preferredFont(forTextStyle: style)
        l.textColor = color
        l.numberOfLines = 0
        return l
    }

    private func style(_ field: UITextField, content: UITextContentType, keyboard: UIKeyboardType) {
        field.borderStyle = .roundedRect
        field.textContentType = content
        field.keyboardType = keyboard
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
        field.addAction(UIAction { [weak self, weak field] _ in
            guard let self, let field else { return }
            // Once the keyboard is up, bring the field (and the button under it) into view.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                let rect = field.convert(field.bounds, to: self.scroll).insetBy(dx: 0, dy: -70)
                self.scroll.scrollRectToVisible(rect, animated: true)
            }
        }, for: .editingDidBegin)
    }

    private var creating: Bool { modeControl.selectedSegmentIndex == 1 }

    private func modeChanged() {
        nameField.isHidden = !creating
        forgot.isHidden = creating
        passwordField.textContentType = creating ? .newPassword : .password
        primary.configuration?.title = creating ? "Create Account" : "Sign In"
        showError(nil)
    }

    // MARK: Actions

    private func run(_ work: @escaping () async throws -> Void) {
        view.endEditing(true)
        showError(nil)
        controls.forEach { $0.isEnabled = false }
        spinner.startAnimating()
        Task { @MainActor in
            do {
                try await work()
                onDone()
            } catch is CancellationError {
            } catch OMRError.cancelled {
            } catch {
                showError(error.localizedDescription)
            }
            controls.forEach { $0.isEnabled = true }
            spinner.stopAnimating()
        }
    }

    private func showError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = message == nil
    }

    private func signInWithApple() {
        run { [self] in
            let credential = try await apple.signIn(from: view.window)
            try await account.signInWithApple(identityToken: credential.identityToken, nonce: credential.nonce, name: credential.name)
        }
    }

    private func signInWithGoogle() {
        run { [self] in
            let idToken = try await google.signIn(from: view.window)
            try await account.signInWithGoogle(idToken: idToken)
        }
    }

    private func submitEmail() {
        let email = emailField.text ?? "", password = passwordField.text ?? "", name = nameField.text ?? ""
        run { [self] in
            if creating {
                try await account.signUp(email: email, password: password, name: name)
            } else {
                try await account.signIn(email: email, password: password)
            }
        }
    }

    private func continueAsGuest() {
        run { [self] in try await account.continueAsGuest() }
    }

    private func forgotPassword() {
        let alert = UIAlertController(title: "Reset Password", message: "We'll email you a link to choose a new password.", preferredStyle: .alert)
        alert.addTextField { [emailField] f in
            f.placeholder = "Email"
            f.text = emailField.text
            f.keyboardType = .emailAddress
            f.textContentType = .emailAddress
            f.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Send Link", style: .default) { [weak self, weak alert] _ in
            guard let self, let email = alert?.textFields?.first?.text, !email.isEmpty else { return }
            Task { @MainActor in
                do {
                    try await self.account.requestPasswordReset(email: email)
                    let done = UIAlertController(title: "Check Your Email",
                                                 message: "If there's an account for \(email), a link to reset the password is on its way.", preferredStyle: .alert)
                    done.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(done, animated: true)
                } catch {
                    self.showError(error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }
}
