import Combine
import ScoreKit
import UIKit

/// The scores on this device, newest first, with the ways to add one: write it, import a file, scan paper.
final class LibraryViewController: UIViewController {
    private let library: ScoreLibrary
    private let onOpen: (UUID) -> Void
    private let onImportFile: () -> Void
    private let onImportPhoto: () -> Void
    private let onScan: () -> Void
    private let onNew: () -> Void

    private var collection: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, ScoreSummary>!
    private var bag = Set<AnyCancellable>()
    private var query = ""

    init(library: ScoreLibrary, onOpen: @escaping (UUID) -> Void, onImportFile: @escaping () -> Void,
         onImportPhoto: @escaping () -> Void, onScan: @escaping () -> Void, onNew: @escaping () -> Void) {
        self.library = library
        self.onOpen = onOpen
        self.onImportFile = onImportFile
        self.onImportPhoto = onImportPhoto
        self.onScan = onScan
        self.onNew = onNew
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
        search.searchBar.placeholder = "Title or composer"
        navigationItem.searchController = search

        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in self?.swipeActions(indexPath) }
        collection = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.delegate = self
        view.addSubview(collection)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, ScoreSummary> { cell, _, item in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = item.title
            content.textProperties.font = Fonts.serif(19, weight: .semibold)
            content.secondaryText = Self.subtitle(item)
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: item.source == .omr ? "doc.viewfinder" : item.source == .musicXML ? "doc.text" : "pencil.and.scribble")
            content.imageProperties.tintColor = Theme.accent
            content.textToSecondaryTextVerticalPadding = 4
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collection) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }

        library.summaries.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.apply() }.store(in: &bag)
    }

    static func subtitle(_ s: ScoreSummary) -> String {
        var parts: [String] = []
        if !s.composer.isEmpty { parts.append(s.composer) }
        parts.append(s.key.name)
        parts.append(s.time.description)
        parts.append("\(s.measures) bar\(s.measures == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private func addMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "New Score", subtitle: "Write music note by note", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in self?.onNew() },
            UIAction(title: "Scan Sheet Music", subtitle: "With the camera", image: UIImage(systemName: "doc.viewfinder")) { [weak self] _ in self?.onScan() },
            UIAction(title: "Choose Photo", subtitle: "From your photo library", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.onImportPhoto() },
            UIAction(title: "Import File", subtitle: "PDF, image or MusicXML from Files", image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in self?.onImportFile() },
        ])
    }

    private func apply() {
        let items = library.summaries.value.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.composer.localizedCaseInsensitiveContains(query)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, ScoreSummary>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        if library.summaries.value.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "music.note")
            empty.text = "No Scores Yet"
            empty.secondaryText = "Import a PDF of your sheet music, scan a printed page, or write a score yourself."
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

    private func swipeActions(_ indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.confirmDelete(item, done: done)
        }
        delete.image = UIImage(systemName: "trash")
        let duplicate = UIContextualAction(style: .normal, title: "Duplicate") { [weak self] _, _, done in
            _ = try? self?.library.duplicate(item.id)
            done(true)
        }
        duplicate.image = UIImage(systemName: "plus.square.on.square")
        duplicate.backgroundColor = Theme.accent
        return UISwipeActionsConfiguration(actions: [delete, duplicate])
    }

    private func confirmDelete(_ item: ScoreSummary, done: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: "Delete “\(item.title)”?", message: "This removes the score and its imported original from this device.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) })
        a.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.library.delete(item.id)
            done(true)
        })
        present(a, animated: true)
    }
}

extension LibraryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let item = dataSource.itemIdentifier(for: indexPath) { onOpen(item.id) }
    }
}

extension LibraryViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        apply()
    }
}
