import ScoreKit
import UIKit

/// UIKit entry point. The window lives in `SceneDelegate`.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        true
    }
}

/// Builds the composition root and the coordinator, shows the window, and routes files opened from
/// other apps (a PDF from Mail, a MusicXML from Files) into the import flow.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var coordinator: AppCoordinator?
    private var dependencies: AppDependencies?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let dependencies = AppDependencies()
        let coordinator = AppCoordinator(dependencies: dependencies)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = coordinator.root
        window.tintColor = Theme.accent
        window.makeKeyAndVisible()
        self.window = window
        self.coordinator = coordinator
        self.dependencies = dependencies
        coordinator.start()
        if let url = connectionOptions.urlContexts.first?.url { open(url) }
    }

    /// Coming back to the app picks up changes made on other devices. While the app is in front the screen
    /// stays on: both hands are on the cello, so nobody can tap it awake mid-piece.
    func sceneDidBecomeActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = true
        dependencies?.sync.syncNow()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { open(url) }
    }

    /// A shared link (musicreader://share/CODE) opens the shared music; a file goes to the import flow.
    private func open(_ url: URL) {
        if url.scheme == "musicreader", let code = ShareClient.code(in: url.absoluteString) {
            DispatchQueue.main.async { self.coordinator?.openSharedCode(code) }
        } else {
            coordinator?.importFile(url)
        }
    }
}
