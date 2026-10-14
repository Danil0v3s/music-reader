import PDFKit
import ScoreKit
import UIKit

/// Sends a PDF or scan to the recognition server and waits for the MusicXML, showing where it's at.
final class ImportViewController: UIViewController {
    private let client: OMRClient
    private let file: Data
    private let filename: String
    private let onDone: ([Score]) -> Void
    private var task: Task<Void, Never>?

    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detail = UILabel()
    private let progress = UIActivityIndicatorView(style: .large)
    private let retry = UIButton(configuration: .borderedProminent())
    private var started = Date()

    init(client: OMRClient, file: Data, filename: String, onDone: @escaping ([Score]) -> Void) {
        self.client = client
        self.file = file
        self.filename = filename
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        title = "Reading Sheet Music"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.task?.cancel()
            self?.dismiss(animated: true)
        })
        icon.image = thumbnail() ?? UIImage(systemName: "doc.viewfinder")
        icon.contentMode = .scaleAspectFit
        icon.tintColor = Theme.accent
        icon.layer.cornerRadius = 6
        icon.layer.borderWidth = 1
        icon.layer.borderColor = UIColor.separator.cgColor
        icon.backgroundColor = .white
        icon.clipsToBounds = true
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.text = filename
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        retry.configuration?.title = "Try Again"
        retry.isHidden = true
        retry.addAction(UIAction { [weak self] _ in self?.run() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, progress, detail, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            icon.heightAnchor.constraint(equalToConstant: 168),
            icon.widthAnchor.constraint(equalToConstant: 126),
        ])
        run()
    }

    private func thumbnail() -> UIImage? {
        if let doc = PDFDocument(data: file), let page = doc.page(at: 0) { return page.thumbnail(of: CGSize(width: 378, height: 504), for: .mediaBox) }
        return UIImage(data: file)
    }

    private func run() {
        retry.isHidden = true
        progress.startAnimating()
        started = Date()
        task = Task { [weak self, client, file, filename] in
            do {
                let scores = try await client.transcribe(file, filename: filename) { p in
                    Task { @MainActor in self?.show(p) }
                }
                await MainActor.run {
                    self?.progress.stopAnimating()
                    self?.onDone(scores)
                }
            } catch OMRError.cancelled {
            } catch {
                await MainActor.run { self?.failed(error) }
            }
        }
    }

    private func show(_ p: OMRProgress) {
        switch p {
        case .uploading: detail.text = "Uploading…"
        case .queued(let ahead):
            detail.text = ahead == 0 ? "Next in line…" : "Waiting: \(ahead) scan\(ahead == 1 ? "" : "s") ahead of yours…"
        case .recognising(let s):
            detail.text = "Recognising staves, notes and markings… \(Int(s)) s\nA page usually takes 10–60 seconds."
        case .downloading: detail.text = "Reading the result…"
        }
    }

    private func failed(_ error: Error) {
        progress.stopAnimating()
        detail.text = error.localizedDescription
        retry.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
    }
}

/// The imported PDF, for checking the recognised notes against the original.
final class OriginalViewController: UIViewController {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        title = "Original"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let pdf = PDFView(frame: view.bounds)
        pdf.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdf.autoScales = true
        pdf.document = PDFDocument(url: url)
        view.addSubview(pdf)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }
}
