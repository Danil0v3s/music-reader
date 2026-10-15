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
            // On a tall screen (iPad) the form sits lower, near the middle; on a phone, near the top.
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor,
                                       constant: mode == .welcome ? (Device.isPad ? 140 : 56) : 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
        ] + NSLayoutConstraint.readable(stack, in: scroll.frameLayoutGuide, maxWidth: 460, inset: 24))
        build()
    }

    // MARK: Layout

    private func build() {
        if mode == .welcome {
            let strings = StringsView()
            stack.addArrangedSubview(strings)
            stack.setCustomSpacing(28, after: strings)
        }
        let heading = UILabel()
        let headingText = mode == .welcome ? "Music Reader" : "Sign in to keep your library"
        let title = NSMutableAttributedString(string: headingText, attributes: [
            .font: Fonts.display(mode == .welcome ? 40 : 26, relativeTo: .largeTitle), .foregroundColor: Theme.ink, .kern: -0.6])
        title.append(NSAttributedString(string: ".", attributes: [.font: Fonts.display(mode == .welcome ? 40 : 26, relativeTo: .largeTitle), .foregroundColor: Theme.accent]))
        heading.attributedText = title
        heading.adjustsFontForContentSizeCategory = true
        heading.numberOfLines = 0
        let lead = label(mode == .welcome
            ? "Read it. Hear it. Play it in tune. Sign in to keep your scores on all your devices."
            : "Your scores move into the account you sign in to, and you'll find them on every device you sign in on.",
            style: .body, color: Theme.inkSoft)
        lead.font = Fonts.ui(17, relativeTo: .body)
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(lead)
        stack.setCustomSpacing(28, after: lead)

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

        let appleButton = ASAuthorizationAppleIDButton(type: .signIn, style: traitCollection.userInterfaceStyle == .dark ? .white : .whiteOutline)
        appleButton.cornerRadius = 14
        appleButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        appleButton.addAction(UIAction { [weak self] _ in self?.signInWithApple() }, for: .touchUpInside)
        stack.addArrangedSubview(appleButton)
        controls.append(appleButton)

        if GoogleSignIn.clientID != nil {
            var c = UIButton.Configuration.bordered()
            c.title = "Continue with Google"
            c.background.cornerRadius = 14
            c.background.backgroundColor = Theme.surface
            c.background.strokeColor = Theme.hairline
            c.baseForegroundColor = Theme.ink
            let googleButton = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.signInWithGoogle() })
            googleButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
            stack.addArrangedSubview(googleButton)
            controls.append(googleButton)
        }

        let or = UILabel()
        or.attributedText = Fonts.labelText("or with your email")
        or.textAlignment = .center
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
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
        p.background.cornerRadius = 14
        p.baseBackgroundColor = Theme.accent
        p.baseForegroundColor = .white
        p.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = Fonts.ui(17, weight: .bold, relativeTo: .headline); return a
        }
        primary.configuration = p
        primary.heightAnchor.constraint(equalToConstant: 52).isActive = true
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
            g.baseForegroundColor = Theme.ink
            g.image = UIImage(systemName: "arrow.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
            g.imagePlacement = .trailing
            g.imagePadding = 6
            g.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a; a.font = Fonts.ui(17, weight: .semibold, relativeTo: .headline); return a
            }
            let guest = UIButton(configuration: g, primaryAction: UIAction { [weak self] _ in self?.continueAsGuest() })
            stack.setCustomSpacing(28, after: spinner)
            stack.addArrangedSubview(guest)
            stack.addArrangedSubview(label("No account needed. Your scores are kept for this \(Device.name); create an account any time to keep them on all your devices.",
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
        // A pale paper well, no border.
        field.borderStyle = .none
        field.backgroundColor = Theme.chrome
        field.layer.cornerRadius = 12
        field.layer.cornerCurve = .continuous
        field.font = Fonts.ui(17, relativeTo: .body)
        field.textColor = Theme.ink
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        field.leftViewMode = .always
        field.textContentType = content
        field.keyboardType = keyboard
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true
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
            try await account.signInWithApple(identityToken: credential.identityToken, authorizationCode: credential.authorizationCode,
                                              nonce: credential.nonce, name: credential.name)
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
