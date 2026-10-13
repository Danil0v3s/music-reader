import Foundation
import ScoreKit

/// Composition root: builds the long-lived collaborators once.
@MainActor
final class AppDependencies {
    let library: ScoreLibrary
    let settings: SettingsStore
    let player: ScorePlayer
    /// `shared/` (Bravura, sample scores; the same files Android bundles) is a folder resource.
    let shared: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        library = ScoreLibrary(directory: documents.appendingPathComponent("Scores", isDirectory: true))
        settings = SettingsStore()
        player = ScorePlayer()
        shared = Bundle.main.url(forResource: "shared", withExtension: nil) ?? Bundle.main.bundleURL
        seedSampleIfFirstLaunch()
    }

    func omrClient() -> OMRClient? {
        settings.omrConfig.map { OMRClient(config: $0) }
    }

    /// The bundled étude, so a first launch has something to read, play and practise.
    func sampleScore() -> Score? {
        let url = shared.appendingPathComponent("samples/etude-in-d.musicxml")
        return (try? Data(contentsOf: url)).flatMap { try? MusicXMLReader.read($0) }
    }

    private func seedSampleIfFirstLaunch() {
        let key = "seededSample"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if library.summaries.value.isEmpty, let sample = sampleScore() { try? library.save(sample) }
    }
}
