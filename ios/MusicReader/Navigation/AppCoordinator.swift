import PhotosUI
import ScoreKit
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Navigation intents the screens call: a screen says "open this score", not "push ScoreViewController".
@MainActor
protocol Coordinator: AnyObject {
    func openScore(_ id: UUID)
    func editScore(_ id: UUID)
    func newScore()
    func practice(_ id: UUID, startMeasure: Int)
    func pickFileToImport()
    func pickPhotoToImport()
    func scanWithCamera()
    func importFile(_ url: URL)
    func showOriginal(_ id: UUID)
    func showServerSettings()
    func share(_ items: [Any], from source: UIBarButtonItem?)
    func pop()
}

/// Owns the tab bar (Library · Tuner · Settings) and everything pushed or presented over it.
@MainActor
final class AppCoordinator: NSObject, Coordinator {
    let root = UITabBarController()
    private let dependencies: AppDependencies
    private let factory: ViewFactory
    private let libraryNav = UINavigationController()
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
        root.setViewControllers([libraryNav, tunerNav, settingsNav], animated: false)
        #if DEBUG
        DevLaunch.run(coordinator: self, dependencies: dependencies)
        #endif
    }

    func selectTab(_ index: Int) { root.selectedIndex = index }

    private var top: UIViewController {
        var top: UIViewController = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    func openScore(_ id: UUID) {
        root.selectedIndex = 0
        guard let vc = factory.score(id) else { return }
        libraryNav.pushViewController(vc, animated: true)
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
            let a = UIAlertController(title: "Set up the recognition server",
                                      message: "Reading sheet music from a PDF or photo uses your Audiveris server. Add its address in Settings.",
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
