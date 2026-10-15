import Combine
import PhotosUI
import ScoreKit
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Navigation intents the screens call: a screen says "open this score", not "push ScoreViewController".
@MainActor
protocol Coordinator: AnyObject {
    func openScore(_ id: UUID, resume: LastPlayed?)
    func openCollection(_ id: UUID)
    func closeCollection(_ id: UUID)
    func editScore(_ id: UUID)
    func newScore()
    func practice(_ id: UUID, startMeasure: Int)
    func pickFileToImport()
    func pickPhotoToImport()
    func scanWithCamera()
    func importFile(_ url: URL)
    func showOriginal(_ id: UUID)
    func showServerSettings()
    func signIn(upgrade: Bool)
    func shareScore(_ id: UUID)
    func shareCollection(_ id: UUID)
    func openSharedCode(_ code: String?)
    func showMyShares()
    func signOut()
    func deleteAccount()
    func share(_ items: [Any], from source: UIBarButtonItem?)
    func pop()
}

extension Coordinator {
    func openScore(_ id: UUID) { openScore(id, resume: nil) }
}

/// Owns the tab bar (Library · Tuner · Settings) and everything pushed or presented over it.
@MainActor
final class AppCoordinator: NSObject, Coordinator {
    let root = UITabBarController()
    private let dependencies: AppDependencies
    private let factory: ViewFactory
    private let libraryNav = UINavigationController()
    /// iPad: the library in a sidebar, the open score beside it (nil on iPhone, where scores push onto the library).
    private var split: UISplitViewController?
    private let detailNav = UINavigationController()
    private let tunerNav = UINavigationController()
    private let settingsNav = UINavigationController()

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        self.factory = ViewFactory(dependencies: dependencies)
        super.init()
        factory.coordinator = self
    }

    func start() {
        libraryNav.navigationBar.prefersLargeTitles = true
        settingsNav.navigationBar.prefersLargeTitles = true
        libraryNav.setViewControllers([factory.library()], animated: false)
        tunerNav.setViewControllers([factory.tuner()], animated: false)
        settingsNav.setViewControllers([factory.settings()], animated: false)
        libraryNav.tabBarItem = UITabBarItem(title: "Library", image: UIImage(systemName: "music.note.list"), tag: 0)
        tunerNav.tabBarItem = UITabBarItem(title: "Tuner", image: UIImage(systemName: "tuningfork"), tag: 1)
        settingsNav.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gearshape"), tag: 2)
        if Device.isPad {
            let split = UISplitViewController(style: .doubleColumn)
            split.setViewController(libraryNav, for: .primary)
            split.setViewController(detailNav, for: .secondary)
            split.preferredDisplayMode = .oneBesideSecondary
            split.preferredSplitBehavior = .tile
            split.preferredPrimaryColumnWidthFraction = 0.36
            split.maximumPrimaryColumnWidth = 420
            split.delegate = self
            split.tabBarItem = libraryNav.tabBarItem
            detailNav.setViewControllers([EmptyDetailViewController()], animated: false)
            self.split = split
            root.setViewControllers([split, tunerNav, settingsNav], animated: false)
            // A score deleted (here or on another device) leaves the detail column.
            dependencies.library.summaries.receive(on: DispatchQueue.main).sink { [weak self] summaries in
                guard let self, let shown = self.detailNav.viewControllers.first as? ScoreViewController,
                      !summaries.contains(where: { $0.id == shown.scoreId }) else { return }
                self.detailNav.setViewControllers([EmptyDetailViewController()], animated: false)
            }.store(in: &bag)
        } else {
            root.setViewControllers([libraryNav, tunerNav, settingsNav], animated: false)
        }
        // Nobody signed in (first launch, or the session ended): the sign-in screen, over everything.
        dependencies.account.state.map { $0 == .signedOut }.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] signedOut in if signedOut { self?.showWelcome() } }.store(in: &bag)
        #if DEBUG
        DevLaunch.run(coordinator: self, dependencies: dependencies)
        #endif
    }

    private var bag = Set<AnyCancellable>()

    private func showWelcome() {
        guard !(top is SignInViewController) else { return }
        let vc = factory.signIn(mode: .welcome) { [weak self] in self?.root.dismiss(animated: true) }
        vc.modalPresentationStyle = .fullScreen
        // On launch the window may not be on screen yet: present on the next turn of the run loop.
        DispatchQueue.main.async { self.dismissAll { self.root.present(vc, animated: false) } }
    }

    func signIn(upgrade: Bool) {
        let nav = UINavigationController(rootViewController: factory.signIn(mode: upgrade ? .upgrade : .welcome) { [weak self] in
            self?.top.dismiss(animated: true)
        })
        top.present(nav, animated: true)
    }

    // MARK: Sharing

    func shareScore(_ id: UUID) {
        let name = dependencies.library.summaries.value.first { $0.id == id }?.title ?? "Score"
        presentShareCode(.score, id: id, name: name)
    }

    func shareCollection(_ id: UUID) {
        presentShareCode(.collection, id: id, name: dependencies.library.collections.value.collection(id)?.name ?? "Collection")
    }

    private func presentShareCode(_ kind: Share.Kind, id: UUID, name: String) {
        guard let client = dependencies.shareClient() else {
            alert("Sign In to Share", "Sharing needs the server and an account.")
            return
        }
        let sync = dependencies.sync
        let vc = ShareCodeViewController(kind: kind, id: id, name: name, client: client) { await sync.syncNow()?.value }
        let nav = UINavigationController(rootViewController: vc)
        if let s = nav.sheetPresentationController { s.detents = [.large()]; s.prefersGrabberVisible = true }
        top.present(nav, animated: true)
    }

    /// Opens shared music: asks for the code when there isn't one (typed, or a link pasted).
    func openSharedCode(_ code: String?) {
        guard let code else {
            let a = UIAlertController(title: "Open Shared Code", message: "Enter the code someone shared with you, or paste their link.", preferredStyle: .alert)
            a.addTextField { f in
                f.placeholder = "ABCD-EFGH"
                f.autocapitalizationType = .allCharacters
                f.autocorrectionType = .no
            }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            a.addAction(UIAlertAction(title: "Open", style: .default) { [weak self, weak a] _ in
                let text = a?.textFields?.first?.text ?? ""
                guard let code = ShareClient.code(in: text) else {
                    self?.alert("That Isn't a Code", "Share codes have 8 letters and numbers, like ABCD-EFGH.")
                    return
                }
                self?.openSharedCode(code)
            })
            top.present(a, animated: true)
            return
        }
        guard let client = dependencies.shareClient() else {
            alert("Sign In First", "Open the code again once you've signed in (or continued as a guest).")
            return
        }
        Task { @MainActor in
            do {
                let item = try await client.open(code)
                showShared(item, client: client)
            } catch {
                alert("Couldn't Open the Code", error.localizedDescription)
            }
        }
    }

    private func showShared(_ item: SharedItem, client: ShareClient) {
        let nav = UINavigationController()
        let importIt: () -> Void = { [weak self] in self?.importShared(item, client: client, from: nav) }
        if item.kind == .score, let score = item.score {
            nav.viewControllers = [factory.sharedScore(score, onImport: importIt)]
        } else {
            nav.viewControllers = [SharedCollectionViewController(item: item, onOpen: { [weak self, weak nav] score in
                guard let self else { return }
                nav?.pushViewController(self.factory.sharedScore(score, onImport: importIt), animated: true)
            }, onImport: importIt)]
        }
        nav.viewControllers.first?.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak nav] _ in
            nav?.dismiss(animated: true)
        })
        nav.modalPresentationStyle = .fullScreen
        dismissAll { self.top.present(nav, animated: true) }
    }

    private func importShared(_ item: SharedItem, client: ShareClient, from nav: UINavigationController) {
        Task { @MainActor in
            do {
                let result = try await client.importCopy(item.code)
                await dependencies.sync.syncNow()?.value
                nav.dismiss(animated: true) {
                    if let collection = result.collectionId { self.openCollection(collection) }
                    else if let first = result.scoreIds.first { self.openScore(first) }
                }
            } catch {
                nav.topViewController.map { vc in
                    let a = UIAlertController(title: "Couldn't Import", message: error.localizedDescription, preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "OK", style: .default))
                    vc.present(a, animated: true)
                }
            }
        }
    }

    func showMyShares() {
        guard let client = dependencies.shareClient() else { return }
        let vc = MySharesViewController(client: client) { [weak self] share in
            guard let self, let id = UUID(uuidString: share.id) else { return }
            share.kind == .score ? self.shareScore(id) : self.shareCollection(id)
        }
        root.selectedIndex = 2
        settingsNav.pushViewController(vc, animated: true)
    }

    func signOut() {
        Task { @MainActor in
            if await dependencies.signOut() { return }
            let a = UIAlertController(title: "Some Changes Haven't Synced",
                                      message: "Signing out now removes them from this \(Device.name). Connect to the server and try again to keep them.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            a.addAction(UIAlertAction(title: "Sign Out Anyway", style: .destructive) { _ in
                Task { @MainActor in _ = await self.dependencies.signOut(force: true) }
            })
            top.present(a, animated: true)
        }
    }

    func deleteAccount() {
        let a = UIAlertController(title: "Delete Your Account?",
                                  message: "This deletes your account and every score, original and collection in it, on the server and on this \(Device.name). It can't be undone.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Delete Account", style: .destructive) { _ in
            Task { @MainActor in
                do {
                    try await self.dependencies.account.deleteAccount()
                    self.dependencies.accountDeleted()
                } catch {
                    self.alert("Couldn't Delete the Account", error.localizedDescription)
                }
            }
        })
        top.present(a, animated: true)
    }

    func selectTab(_ index: Int) { root.selectedIndex = index }

    private var top: UIViewController {
        var top: UIViewController = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    /// Opens a score; `resume` brings back the bars on repeat and the practice tempo it was last played with.
    func openScore(_ id: UUID, resume: LastPlayed? = nil) {
        root.selectedIndex = 0
        guard let vc = factory.score(id, resume: resume) else { return }
        if let split {
            detailNav.setViewControllers([vc], animated: false)
            split.show(.secondary)
        } else {
            libraryNav.pushViewController(vc, animated: true)
        }
    }

    func openCollection(_ id: UUID) {
        root.selectedIndex = 0
        libraryNav.pushViewController(factory.collection(id), animated: true)
    }

    /// The collection was deleted (here or by sync): leave its screen.
    func closeCollection(_ id: UUID) {
        guard let i = libraryNav.viewControllers.firstIndex(where: { $0 is CollectionViewController }) else { return }
        libraryNav.setViewControllers(Array(libraryNav.viewControllers.prefix(i)), animated: true)
    }

    func editScore(_ id: UUID) {
        guard let vc = factory.editor(id) else { return }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        top.present(nav, animated: true)
    }

    func newScore() {
        let sheet = factory.newScore { [weak self] score in
            guard let self else { return }
            try? self.dependencies.library.save(score)
            self.top.dismiss(animated: true) {
                self.openScore(score.id)
                self.editScore(score.id)
            }
        }
        let nav = UINavigationController(rootViewController: sheet)
        if let s = nav.sheetPresentationController { s.detents = [.large()] }
        top.present(nav, animated: true)
    }

    func practice(_ id: UUID, startMeasure: Int) {
        guard let vc = factory.practice(id, startMeasure: startMeasure) else { return }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        top.present(nav, animated: true)
    }

    // MARK: Import

    func pickFileToImport() {
        var types: [UTType] = [.pdf, .image, .xml]
        if let musicxml = UTType("org.musicxml.musicxml") { types.append(musicxml) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        top.present(picker, animated: true)
    }

    func pickPhotoToImport() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        top.present(picker, animated: true)
    }

    /// Photos are framed first: recognition works far better on one tightly cropped piece.
    private func cropThenRecognise(_ image: UIImage, name: String) {
        let crop = CropViewController(image: image) { [weak self] cropped in
            guard let self, let data = cropped.jpegData(compressionQuality: 0.92) else { return }
            self.recognise(data, filename: name, keepOriginal: false)
        }
        let nav = UINavigationController(rootViewController: crop)
        nav.modalPresentationStyle = .fullScreen
        dismissAll { self.top.present(nav, animated: true) }
    }

    func scanWithCamera() {
        guard VNDocumentCameraViewController.isSupported else {
            alert("Scanning isn't available", "This device has no document camera. Import a PDF or photo instead.")
            return
        }
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = self
        top.present(scanner, animated: true)
    }

    /// MusicXML is read on the device; PDFs and images go to the recognition server.
    func importFile(_ url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            alert("Couldn't open the file", url.lastPathComponent)
            return
        }
        let ext = url.pathExtension.lowercased()
        if ext == "musicxml" || ext == "xml" {
            do {
                let score = try MusicXMLReader.read(data)
                try dependencies.library.save(score)
                dismissAll { self.openScore(score.id) }
            } catch {
                alert("Couldn't read the MusicXML", error.localizedDescription)
            }
            return
        }
        if ["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(ext), let image = UIImage(data: data) {
            cropThenRecognise(image, name: (url.deletingPathExtension().lastPathComponent) + ".jpg")
            return
        }
        if ext == "mxl" {
            alert("Compressed MusicXML", "Export as uncompressed MusicXML (.musicxml) from your notation app, then import that.")
            return
        }
        recognise(data, filename: url.lastPathComponent, keepOriginal: ext == "pdf")
    }

    private func recognise(_ data: Data, filename: String, keepOriginal: Bool) {
        guard let client = dependencies.omrClient() else {
            let a = UIAlertController(title: "Set up the server",
                                      message: "Reading sheet music from a PDF or photo uses the Music Reader server. Add its address in Settings and sign in.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Not Now", style: .cancel))
            a.addAction(UIAlertAction(title: "Settings", style: .default) { _ in self.showServerSettings() })
            top.present(a, animated: true)
            return
        }
        let vc = factory.importProgress(client: client, file: data, filename: filename) { [weak self] scores in
            guard let self else { return }
            for score in scores { try? self.dependencies.library.save(score, original: keepOriginal ? data : nil) }
            self.dismissAll { if let first = scores.first { self.openScore(first.id) } }
        }
        let nav = UINavigationController(rootViewController: vc)
        if let s = nav.sheetPresentationController { s.detents = [.medium()]; s.prefersGrabberVisible = true }
        nav.isModalInPresentation = true
        dismissAll { self.top.present(nav, animated: true) }
    }

    func showOriginal(_ id: UUID) {
        let vc = factory.original(id)
        top.present(UINavigationController(rootViewController: vc), animated: true)
    }

    func showServerSettings() {
        dismissAll {
            self.root.selectedIndex = 2
            self.settingsNav.popToRootViewController(animated: false)
        }
    }

    func share(_ items: [Any], from source: UIBarButtonItem?) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = source
        top.present(vc, animated: true)
    }

    func pop() { libraryNav.popViewController(animated: true) }

    private func dismissAll(_ then: @escaping () -> Void) {
        if root.presentedViewController != nil { root.dismiss(animated: true, completion: then) } else { then() }
    }

    private func alert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(a, animated: true)
    }
}

extension AppCoordinator: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        let name = (provider.suggestedName ?? "Photo") + ".jpg"
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage else { return }
            Task { @MainActor in self.cropThenRecognise(image, name: name) }
        }
    }
}

extension AppCoordinator: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importFile(url)
    }
}

extension AppCoordinator: @preconcurrency VNDocumentCameraViewControllerDelegate {
    /// Scanned pages become one PDF, which goes to the server like any other.
    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
        controller.dismiss(animated: true) {
            guard let first = pages.first else { return }
            let bounds = CGRect(origin: .zero, size: first.size)
            let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
                for page in pages {
                    ctx.beginPage(withBounds: CGRect(origin: .zero, size: page.size), pageInfo: [:])
                    page.draw(in: CGRect(origin: .zero, size: page.size))
                }
            }
            let name = "Scan \(Date().formatted(date: .abbreviated, time: .shortened)).pdf"
            self.recognise(pdf, filename: name.replacingOccurrences(of: ":", with: "."), keepOriginal: true)
        }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true) { self.alert("Scanning failed", error.localizedDescription) }
    }
}

extension AppCoordinator: UISplitViewControllerDelegate {
    /// iPad in a narrow window (Split View, Slide Over): with no score open, show the library, not the
    /// empty placeholder.
    func splitViewController(_ svc: UISplitViewController,
                             topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        detailNav.viewControllers.first is EmptyDetailViewController ? .primary : proposedTopColumn
    }
}

/// The iPad's detail column before a score is chosen.
final class EmptyDetailViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.paper
        let icon = UIImageView(image: UIImage(systemName: "music.note.list"))
        icon.tintColor = Theme.accent.withAlphaComponent(0.5)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .light)
        let label = UILabel()
        label.text = "Choose a score to read, play and practise."
        label.font = Fonts.display(22)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)]
                                    + NSLayoutConstraint.readable(stack, in: view.safeAreaLayoutGuide, maxWidth: 360, inset: 24))
    }
}
