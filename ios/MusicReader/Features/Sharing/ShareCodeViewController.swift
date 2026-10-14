import ScoreKit
import UIKit

/// Sharing one of my scores or collections: the code (made on the server when this opens, or the existing
/// one), a link to send, how many people imported a copy, and a way to stop sharing.
final class ShareCodeViewController: UIViewController {
    private let kind: Share.Kind
    private let targetId: UUID
    private let name: String
    private let client: ShareClient
    /// Makes sure the server has the score (a score made a moment ago may not have synced yet).
    private let syncFirst: () async -> Void

    private let codeLabel = UILabel()
    private let detail = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let buttons = UIStackView()
    private var share: Share?

    init(kind: Share.Kind, id: UUID, name: String, client: ShareClient, syncFirst: @escaping () async -> Void) {
        self.kind = kind
        self.targetId = id
        self.name = name
        self.client = client
        self.syncFirst = syncFirst
        super.init(nibName: nil, bundle: nil)
        title = kind == .score ? "Share Score" : "Share Collection"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })

        let heading = UILabel()
        heading.text = name
        heading.font = Fonts.serif(22, weight: .semibold)
        heading.numberOfLines = 2
        heading.textAlignment = .center
        codeLabel.font = Fonts.mono(40, weight: .semibold)
        codeLabel.textAlignment = .center
        codeLabel.accessibilityLabel = "Share code"
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        buttons.axis = .vertical
        buttons.spacing = 10
        buttons.isHidden = true
        buttons.addArrangedSubview(button("Send Link…", image: "square.and.arrow.up", filled: true) { [weak self] in self?.sendLink() })
        buttons.addArrangedSubview(button("Copy Code", image: "doc.on.doc") { [weak self] in
            UIPasteboard.general.string = self?.share?.code
            self?.detail.text = "Copied. " + (self?.explanation ?? "")
        })
        buttons.addArrangedSubview(button("Stop Sharing", image: "xmark.circle", destructive: true) { [weak self] in self?.confirmStop() })

        let stack = UIStackView(arrangedSubviews: [heading, codeLabel, spinner, detail, buttons])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(28, after: detail)
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
        ])
        load()
    }

    private func button(_ title: String, image: String, filled: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> UIButton {
        var c: UIButton.Configuration = filled ? .filled() : .tinted()
        c.title = title
        c.image = UIImage(systemName: image)
        c.imagePadding = 8
        c.cornerStyle = .capsule
        c.baseBackgroundColor = destructive ? .systemRed : Theme.accent
        c.baseForegroundColor = filled ? .white : (destructive ? .systemRed : Theme.accent)
        let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
        b.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return b
    }

    private var explanation: String {
        let what = kind == .score ? "this score" : "this collection"
        var text = "Anyone with the code can look at \(what) and save their own copy to change as they like. Your original scan isn't shared."
        if let imports = share?.imports, imports > 0 { text += "\n\n\(imports) \(imports == 1 ? "person has" : "people have") saved a copy." }
        return text
    }

    private func load() {
        spinner.startAnimating()
        Task { @MainActor in
            do {
                let s: Share
                do {
                    s = try await client.share(kind, id: targetId)
                } catch let e as ServerError where e.code == "not_found" {
                    // Not on the server yet: sync, then try again.
                    await syncFirst()
                    s = try await client.share(kind, id: targetId)
                }
                share = s
                codeLabel.text = s.code
                detail.text = explanation
                buttons.isHidden = false
            } catch {
                detail.text = "Couldn't make a share code: \(error.localizedDescription)"
            }
            spinner.stopAnimating()
        }
    }

    private func sendLink() {
        guard let share else { return }
        let text = "\(name): open it in Music Reader with \(share.url), or enter the code \(share.code)."
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = buttons
        present(vc, animated: true)
    }

    private func confirmStop() {
        guard let share else { return }
        let a = UIAlertController(title: "Stop Sharing?", message: "The code \(share.code) will stop working. Copies people already saved stay theirs.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Stop Sharing", style: .destructive) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await self.client.stopSharing(share.code)
                    self.dismiss(animated: true)
                } catch {
                    self.detail.text = error.localizedDescription
                }
            }
        })
        present(a, animated: true)
    }
}
