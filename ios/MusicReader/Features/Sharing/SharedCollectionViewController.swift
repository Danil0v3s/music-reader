import ScoreKit
import UIKit

/// Someone's shared collection: its scores, read-only (tap one to look at it and play it), and Import All.
final class SharedCollectionViewController: UITableViewController {
    private let item: SharedItem
    private let onOpen: (Score) -> Void
    private let onImport: () -> Void

    init(item: SharedItem, onOpen: @escaping (Score) -> Void, onImport: @escaping () -> Void) {
        self.item = item
        self.onOpen = onOpen
        self.onImport = onImport
        super.init(style: .insetGrouped)
        title = item.title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        var c = UIButton.Configuration.filled()
        c.title = "Import All"
        c.cornerStyle = .capsule
        c.baseBackgroundColor = Theme.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.onImport() }))
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { item.scores.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Shared by \(item.owner) · \(item.scores.count) score\(item.scores.count == 1 ? "" : "s")"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Import All saves your own copy of the collection and its scores, to change as you like."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        var content = UIListContentConfiguration.subtitleCell()
        let score = item.scores[indexPath.row]
        content.text = score.title
        content.textProperties.font = Fonts.serif(19, weight: .semibold)
        content.secondaryText = LibraryViewController.subtitle(ScoreSummary(score, hasOriginal: false))
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpen(item.scores[indexPath.row])
    }
}

/// Everything I'm sharing: each code, how many people saved a copy, and a way to stop.
final class MySharesViewController: UITableViewController {
    private let client: ShareClient
    private let onOpen: (Share) -> Void
    private var shares: [Share] = []
    private var message: String?

    init(client: ShareClient, onOpen: @escaping (Share) -> Void) {
        self.client = client
        self.onOpen = onOpen
        super.init(style: .insetGrouped)
        title = "Shared by Me"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { @MainActor in
            do {
                shares = try await client.myShares()
                message = shares.isEmpty ? "You're not sharing anything. To share a score, open it and choose … → Share." : nil
            } catch {
                message = error.localizedDescription
            }
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shares.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        message ?? "Swipe a share to stop it. Copies people already saved stay theirs."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let s = shares[indexPath.row]
        let cell = UITableViewCell()
        var content = UIListContentConfiguration.subtitleCell()
        content.text = s.title ?? "Untitled"
        content.secondaryText = "\(s.code) · \(s.kind == .score ? "score" : "collection") · \(s.imports) cop\(s.imports == 1 ? "y" : "ies") saved"
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: s.kind == .score ? "music.note" : "folder")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpen(shares[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let s = shares[indexPath.row]
        let stop = UIContextualAction(style: .destructive, title: "Stop Sharing") { [weak self] _, _, done in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try await self.client.stopSharing(s.code)
                    self.shares.removeAll { $0.code == s.code }
                    self.tableView.reloadData()
                    done(true)
                } catch {
                    done(false)
                }
            }
        }
        return UISwipeActionsConfiguration(actions: [stop])
    }
}
