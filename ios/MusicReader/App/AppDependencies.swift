import Foundation
import ScoreKit

/// Composition root: builds the long-lived collaborators once.
@MainActor
final class AppDependencies {
    let library: ScoreLibrary
    let settings: SettingsStore
    let player: ScorePlayer
    let sync: SyncService
    /// `shared/` (Bravura, sample scores; the same files Android bundles) is a folder resource.
    let shared: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        library = ScoreLibrary(directory: documents.appendingPathComponent("Scores", isDirectory: true))
        settings = SettingsStore()
        player = ScorePlayer()
        sync = SyncService(library: library, settings: settings)
        shared = Bundle.main.url(forResource: "shared", withExtension: nil) ?? Bundle.main.bundleURL
        seedSampleIfFirstLaunch()
    }

    func omrClient() -> OMRClient? {
        settings.omrConfig.map { OMRClient(config: $0) }
    }

    /// The bundled étude, so a first launch has something to read, play and practise. It has a fixed id, so
    /// every device's copy is the same score as far as sync is concerned.
    func sampleScore() -> Score? {
        let url = shared.appendingPathComponent("samples/etude-in-d.musicxml")
        guard var score = (try? Data(contentsOf: url)).flatMap({ try? MusicXMLReader.read($0) }) else { return nil }
        score.id = UUID(uuidString: "E7D0E7D0-0000-4000-8000-000000000001")!
        score.created = Date(timeIntervalSince1970: 1_790_000_000)
        score.modified = score.created
        return score
    }

    private func seedSampleIfFirstLaunch() {
        let key = "seededSample"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if library.summaries.value.isEmpty, let sample = sampleScore() { try? library.save(sample, touch: false, origin: .sync) }
    }
}
