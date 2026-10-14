import Combine
import ScoreKit
import UIKit

/// The scores on this device: collections first, then every score, newest first. Pull down to sync with the
/// server. The + menu writes, scans, imports or starts a collection.
final class LibraryViewController: UIViewController {
    enum Item: Hashable {
        case collection(UUID)
        case score(ScoreSummary)
    }

    enum Section: Int { case collections, scores }

    private let library: ScoreLibrary
    private let sync: SyncService
    private let onOpen: (UUID) -> Void
    private let onOpenCollection: (UUID) -> Void
    private let onImportFile: () -> Void
    private let onImportPhoto: () -> Void
    private let onScan: () -> Void
    private let onNew: () -> Void

    private var collection: UICollectionView!
    private let onOpenSharedCode: () -> Void
    private let onShareCollection: (UUID) -> Void
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var bag = Set<AnyCancellable>()
    private var query = ""

    init(library: ScoreLibrary, sync: SyncService, onOpen: @escaping (UUID) -> Void, onOpenCollection: @escaping (UUID) -> Void,
         onImportFile: @escaping () -> Void, onImportPhoto: @escaping () -> Void, onScan: @escaping () -> Void, onNew: @escaping () -> Void,
         onOpenSharedCode: @escaping () -> Void, onShareCollection: @escaping (UUID) -> Void) {
        self.library = library
        self.sync = sync
        self.onOpen = onOpen
        self.onOpenCollection = onOpenCollection
        self.onImportFile = onImportFile
        self.onImportPhoto = onImportPhoto
        self.onScan = onScan
        self.onNew = onNew
        self.onOpenSharedCode = onOpenSharedCode
        self.onShareCollection = onShareCollection
        super.init(nibName: nil, bundle: nil)
        title = "Library"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, menu: addMenu())

        let search = UISearchController()
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Title, composer or collection"
        navigationItem.searchController = search

        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in self?.swipeActions(indexPath) }
        collection = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.delegate = self
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { @MainActor in
                await self?.sync.syncNow()?.value
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collection.refreshControl = refresh
        view.addSubview(collection)

        let scoreCell = UICollectionView.CellRegistration<UICollectionViewListCell, ScoreSummary> { cell, _, item in
            cell.contentConfiguration = Self.scoreContent(item)
            cell.accessories = [.disclosureIndicator()]
        }
        let collectionCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> { [weak self] cell, _, id in
            guard let self, let c = self.library.collections.value.collection(id) else { return }
            var content = UIListContentConfiguration.valueCell()
            content.text = c.name
            content.textProperties.font = .preferredFont(forTextStyle: .body).withWeight(.semibold)
            content.image = UIImage(systemName: "folder.fill")
            content.imageProperties.tintColor = Theme.accent
            content.secondaryText = "\(self.present(c).count)"
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) {
            [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.header()
            let section = self?.dataSource.sectionIdentifier(for: indexPath.section)
            content.text = section == .collections ? "Collections" : "All Scores"
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { cv, indexPath, item in
            switch item {
            case .score(let s): cv.dequeueConfiguredReusableCell(using: scoreCell, for: indexPath, item: s)
            case .collection(let id): cv.dequeueConfiguredReusableCell(using: collectionCell, for: indexPath, item: id)
            }
        }
        dataSource.supplementaryViewProvider = { cv, _, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }

        library.summaries.combineLatest(library.collections).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
    }

    static func scoreContent(_ item: ScoreSummary) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.title
        content.textProperties.font = Fonts.serif(19, weight: .semibold)
        content.secondaryText = subtitle(item)
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: item.source == .omr ? "doc.viewfinder" : item.source == .musicXML ? "doc.text" : "pencil.and.scribble")
        content.imageProperties.tintColor = Theme.accent
        content.textToSecondaryTextVerticalPadding = 4
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
        return content
    }

    static func subtitle(_ s: ScoreSummary) -> String {
        var parts: [String] = []
        if let owner = s.sharedBy { parts.append("from \(owner)") }
        if !s.composer.isEmpty { parts.append(s.composer) }
        parts.append(s.key.name)
        parts.append(s.time.description)
        parts.append("\(s.measures) bar\(s.measures == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// A collection's scores that are on this device, in its order.
    private func present(_ c: ScoreCollection) -> [ScoreSummary] {
        let byId = Dictionary(uniqueKeysWithValues: library.summaries.value.map { ($0.id, $0) })
        return c.scoreIds.compactMap { byId[$0] }
    }

    private func addMenu() -> UIMenu {
        UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIAction(title: "New Score", subtitle: "Write music note by note", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in self?.onNew() },
                UIAction(title: "Scan Sheet Music", subtitle: "With the camera", image: UIImage(systemName: "doc.viewfinder")) { [weak self] _ in self?.onScan() },
                UIAction(title: "Choose Photo", subtitle: "From your photo library", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.onImportPhoto() },
                UIAction(title: "Import File", subtitle: "PDF, image or MusicXML from Files", image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in self?.onImportFile() },
            ]),
            UIAction(title: "New Collection", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.newCollection(adding: []) },
            UIAction(title: "Open Shared Code…", subtitle: "Music someone shared with you", image: UIImage(systemName: "person.2")) { [weak self] _ in self?.onOpenSharedCode() },
        ])
    }

    private func apply() {
        let matches: (String) -> Bool = { [query] text in query.isEmpty || text.localizedCaseInsensitiveContains(query) }
        let scores = library.summaries.value.filter { matches($0.title) || matches($0.composer) }
        let collections = library.collections.value.collections
            .filter { matches($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !collections.isEmpty {
            snapshot.appendSections([.collections])
            snapshot.appendItems(collections.map { .collection($0.id) }, toSection: .collections)
        }
        snapshot.appendSections([.scores])
        snapshot.appendItems(scores.map { .score($0) }, toSection: .scores)
        // Collection rows show live counts and names: reconfigure them on every change.
        snapshot.reconfigureItems(collections.map { .collection($0.id) })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)

        if library.summaries.value.isEmpty && library.collections.value.collections.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "music.note")
            empty.text = "No Scores Yet"
            empty.secondaryText = "Scan a page from your book, choose a photo, import a PDF, or write a score yourself."
            var button = UIButton.Configuration.borderedProminent()
            button.title = "Add a Score"
            empty.button = button
            empty.buttonProperties.menu = addMenu()
            empty.buttonProperties.primaryAction = nil
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    // MARK: Collections

    func newCollection(adding scoreIds: [UUID]) {
        let a = UIAlertController(title: "New Collection", message: "A book, an exam programme, this week's pieces…", preferredStyle: .alert)
        a.addTextField { f in f.placeholder = "Name"; f.autocapitalizationType = .words }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak a] _ in
            let name = a?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let self, !name.isEmpty else { return }
            self.library.updateCollections { $0.create(name: name, scoreIds: scoreIds) }
        })
        present(a, animated: true)
    }

    /// "Add to Collection" for a score: every collection, ticked where it's already in, plus a new one.
    func collectionsMenu(for scoreId: UUID) -> UIMenu {
        let doc = library.collections.value
        let toggles = doc.collections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { c in
            let isIn = c.scoreIds.contains(scoreId)
            return UIAction(title: c.name, image: UIImage(systemName: "folder"), state: isIn ? .on : .off) { [weak self] _ in
                self?.library.updateCollections { isIn ? $0.remove(scoreId, from: c.id) : $0.add([scoreId], to: c.id) }
            }
        }
        let new = UIAction(title: "New Collection…", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.newCollection(adding: [scoreId]) }
        return UIMenu(title: "Add to Collection", image: UIImage(systemName: "folder.badge.plus"), children: toggles + [UIMenu(options: .displayInline, children: [new])])
    }

    private func swipeActions(_ indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        switch item {
        case .collection(let id):
            let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
                self?.confirmDeleteCollection(id, done: done)
            }
            delete.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [delete])
        case .score(let s):
            let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
                self?.confirmDelete(s, done: done)
            }
            delete.image = UIImage(systemName: "trash")
            let duplicate = UIContextualAction(style: .normal, title: "Duplicate") { [weak self] _, _, done in
                _ = try? self?.library.duplicate(s.id)
                done(true)
            }
            duplicate.image = UIImage(systemName: "plus.square.on.square")
            duplicate.backgroundColor = Theme.accent
            return UISwipeActionsConfiguration(actions: [delete, duplicate])
        }
    }

    private func confirmDelete(_ item: ScoreSummary, done: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: "Delete “\(item.title)”?",
                                  message: "This removes the score and its imported original from this device and from your server.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) })
        a.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.library.delete(item.id)
            done(true)
        })
        present(a, animated: true)
    }

    func confirmDeleteCollection(_ id: UUID, done: ((Bool) -> Void)? = nil) {
        guard let c = library.collections.value.collection(id) else { done?(false); return }
        let a = UIAlertController(title: "Delete “\(c.name)”?", message: "Its scores stay in your library.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done?(false) })
        a.addAction(UIAlertAction(title: "Delete Collection", style: .destructive) { [weak self] _ in
            self?.library.updateCollections { $0.delete(id) }
            done?(true)
        })
        present(a, animated: true)
    }
}

extension LibraryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .score(let s): onOpen(s.id)
        case .collection(let id): onOpenCollection(id)
        case nil: break
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first else { return nil }
        if case .collection(let id) = dataSource.itemIdentifier(for: indexPath) {
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                UIMenu(children: [UIAction(title: "Share…", image: UIImage(systemName: "person.2")) { [weak self] _ in self?.onShareCollection(id) }])
            })
        }
        guard case .score(let s) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                self.collectionsMenu(for: s.id),
                UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in _ = try? self?.library.duplicate(s.id) },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.confirmDelete(s) { _ in } },
            ])
        })
    }
}

extension LibraryViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        apply()
    }
}
