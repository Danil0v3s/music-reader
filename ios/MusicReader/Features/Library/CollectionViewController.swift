import Combine
import ScoreKit
import UIKit

/// One collection: its scores in the order the user arranged them. Drag the handles to reorder (Edit),
/// swipe to take a score out (it stays in the library), + to add scores.
final class CollectionViewController: UIViewController {
    private let collectionId: UUID
    private let library: ScoreLibrary
    private let onOpen: (UUID) -> Void
    private let onDeleted: () -> Void

    private var list: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ScoreSummary>!
    private var bag = Set<AnyCancellable>()

    private let onShare: () -> Void

    init(collectionId: UUID, library: ScoreLibrary, onOpen: @escaping (UUID) -> Void, onDeleted: @escaping () -> Void,
         onShare: @escaping () -> Void) {
        self.onShare = onShare
        self.collectionId = collectionId
        self.library = library
        self.onOpen = onOpen
        self.onDeleted = onDeleted
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .always
    }

    required init?(coder: NSCoder) { fatalError() }

    private var current: ScoreCollection? { library.collections.value.collection(collectionId) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let add = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.addScores() })
        add.accessibilityLabel = "Add Scores"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIAction(title: "Share…", subtitle: "A code friends can open", image: UIImage(systemName: "person.2")) { [weak self] _ in self?.onShare() },
            UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.rename() },
            UIAction(title: "Reorder", image: UIImage(systemName: "arrow.up.arrow.down")) { [weak self] _ in self?.setEditing(true, animated: true) },
            UIAction(title: "Delete Collection", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteCollection() },
        ]))
        navigationItem.rightBarButtonItems = [more, add]

        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let s = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
            let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                guard let self else { return }
                self.library.updateCollections { $0.remove(s.id, from: self.collectionId) }
                done(true)
            }
            remove.image = UIImage(systemName: "folder.badge.minus")
            return UISwipeActionsConfiguration(actions: [remove])
        }
        list = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        list.delegate = self
        view.addSubview(list)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, ScoreSummary> { cell, _, item in
            cell.contentConfiguration = LibraryViewController.scoreContent(item)
            cell.accessories = [.disclosureIndicator(displayed: .whenNotEditing), .reorder(displayed: .whenEditing)]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: list) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.reorderingHandlers.canReorderItem = { _ in true }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            let ordered = transaction.finalSnapshot.itemIdentifiers.map(\.id)
            // Scores not on this device (still syncing) keep their place at the end.
            self.library.updateCollections { doc in
                guard let i = doc.collections.firstIndex(where: { $0.id == self.collectionId }) else { return }
                let missing = doc.collections[i].scoreIds.filter { !ordered.contains($0) }
                doc.collections[i].scoreIds = ordered + missing
            }
        }

        library.summaries.combineLatest(library.collections).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        list.isEditing = editing
        navigationItem.leftBarButtonItem = editing ? UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.setEditing(false, animated: true)
        }) : nil
        navigationItem.hidesBackButton = editing
    }

    private func apply() {
        guard let c = current else {
            // Deleted here or on another device.
            onDeleted()
            return
        }
        title = c.name
        let byId = Dictionary(uniqueKeysWithValues: library.summaries.value.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Int, ScoreSummary>()
        snapshot.appendSections([0])
        snapshot.appendItems(c.scoreIds.compactMap { byId[$0] })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        if snapshot.numberOfItems == 0 {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "folder")
            empty.text = "No Scores in \(c.name)"
            empty.secondaryText = "Add scores from your library. They stay in the library too."
            var button = UIButton.Configuration.borderedProminent()
            button.title = "Add Scores"
            empty.button = button
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.addScores() }
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func addScores() {
        guard let c = current else { return }
        let picker = ScorePickerViewController(library: library, excluding: Set(c.scoreIds), title: "Add to \(c.name)") { [weak self] ids in
            guard let self else { return }
            self.library.updateCollections { $0.add(ids, to: self.collectionId) }
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    private func rename() {
        let a = UIAlertController(title: "Rename Collection", message: nil, preferredStyle: .alert)
        a.addTextField { [weak self] f in f.text = self?.current?.name; f.autocapitalizationType = .words; f.clearButtonMode = .whileEditing }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak a] _ in
            let name = a?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let self, !name.isEmpty else { return }
            self.library.updateCollections { $0.rename(self.collectionId, to: name) }
        })
        present(a, animated: true)
    }

    private func deleteCollection() {
        guard let c = current else { return }
        let a = UIAlertController(title: "Delete “\(c.name)”?", message: "Its scores stay in your library.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Delete Collection", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.library.updateCollections { $0.delete(self.collectionId) }
        })
        present(a, animated: true)
    }
}

extension CollectionViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let s = dataSource.itemIdentifier(for: indexPath) { onOpen(s.id) }
    }
}

/// Picks several scores at once (adding to a collection).
final class ScorePickerViewController: UITableViewController {
    private let scores: [ScoreSummary]
    private let onPick: ([UUID]) -> Void
    private var picked = Set<UUID>()

    init(library: ScoreLibrary, excluding: Set<UUID>, title: String, onPick: @escaping ([UUID]) -> Void) {
        scores = library.summaries.value.filter { !excluding.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        self.onPick = onPick
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let add = UIBarButtonItem(title: "Add", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            // Keep the library's order (newest first) for what was picked.
            self.onPick(self.scores.map(\.id).filter { self.picked.contains($0) })
            self.dismiss(animated: true)
        })
        add.style = .prominent
        navigationItem.rightBarButtonItem = add
        updateAdd()
        if scores.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.text = "Every score is already here"
            contentUnavailableConfiguration = empty
        }
    }

    private func updateAdd() {
        navigationItem.rightBarButtonItem?.isEnabled = !picked.isEmpty
        navigationItem.rightBarButtonItem?.title = picked.isEmpty ? "Add" : "Add \(picked.count)"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { scores.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        let s = scores[indexPath.row]
        var content = LibraryViewController.scoreContent(s)
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
        cell.contentConfiguration = content
        cell.accessoryType = picked.contains(s.id) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let id = scores[indexPath.row].id
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        tableView.reloadRows(at: [indexPath], with: .none)
        updateAdd()
    }
}
