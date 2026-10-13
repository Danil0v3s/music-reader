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
        coordinator.start()
        if let url = connectionOptions.urlContexts.first?.url { coordinator.importFile(url) }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { coordinator?.importFile(url) }
    }
}
