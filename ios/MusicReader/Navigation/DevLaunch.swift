#if DEBUG
import ScoreKit
import UIKit

/// Debug-only launch hooks for driving the app from the command line:
/// `SIMCTL_CHILD_MR_DEV_SCREEN=score xcrun simctl launch booted br.com.firstsoft.musicreader`
///  - MR_DEV_SCREEN: library | score | editor | practice | tuner | settings | new | import
///    (score/editor/practice open the bundled étude, saved fresh).
///  - MR_DEV_SERVER: sets the server address (e.g. http://localhost:8765).
///  - MR_DEV_GUEST=1: when signed out, continues as a guest (skips the sign-in screen).
///  - MR_DEV_IMPORT: a file path to import as if opened from Files (a PDF goes to the server).
///  - MR_DEV_EXPORT_PDF: writes the bundled étude, engraved, as a PDF at this path.
@MainActor
enum DevLaunch {
    static func run(coordinator: AppCoordinator, dependencies: AppDependencies) {
        let env = ProcessInfo.processInfo.environment
        if let server = env["MR_DEV_SERVER"] { dependencies.settings.update { $0.serverAddress = server } }
        if env["MR_DEV_GUEST"] == "1", dependencies.account.user == nil {
            Task { @MainActor in
                try? await dependencies.account.continueAsGuest()
                coordinator.root.dismiss(animated: false)
            }
        }
        if let path = env["MR_DEV_EXPORT_PDF"], let score = dependencies.sampleScore() {
            let view = ScoreView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
            view.score = score
            try? view.pdfData()?.write(to: URL(fileURLWithPath: path))
        }
        if let path = env["MR_DEV_IMPORT"] {
            DispatchQueue.main.async { coordinator.importFile(URL(fileURLWithPath: path)) }
            return
        }
        guard let screen = env["MR_DEV_SCREEN"] else { return }
        let sample: () -> UUID? = {
            guard let score = dependencies.sampleScore() else { return nil }
            let existing = dependencies.library.summaries.value.first { $0.title == score.title }
            if let existing { return existing.id }
            try? dependencies.library.save(score)
            return score.id
        }
        DispatchQueue.main.async {
            switch screen {
            case "score": if let id = sample() { coordinator.openScore(id) }
            case "editor": if let id = sample() { coordinator.openScore(id); coordinator.editScore(id) }
            case "practice": if let id = sample() { coordinator.openScore(id); coordinator.practice(id, startMeasure: 0) }
            case "tuner": coordinator.selectTab(1)
            case "settings": coordinator.selectTab(2)
            case "new": coordinator.newScore()
            case "import":
                if let url = dependencies.shared.appendingPathComponent("samples/etude-in-d.musicxml") as URL? { coordinator.importFile(url) }
            default: break
            }
        }
    }
}
#endif
