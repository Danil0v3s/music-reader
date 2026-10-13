import ScoreKit
import UIKit

/// Builds screens, pulling collaborators from the composition root and wiring navigation to the coordinator.
@MainActor
final class ViewFactory {
    private let d: AppDependencies
    weak var coordinator: Coordinator?

    init(dependencies: AppDependencies) { self.d = dependencies }

    func library() -> LibraryViewController {
        LibraryViewController(library: d.library, onOpen: { [weak self] in self?.coordinator?.openScore($0) },
                              onImportFile: { [weak self] in self?.coordinator?.pickFileToImport() },
                              onScan: { [weak self] in self?.coordinator?.scanWithCamera() },
                              onNew: { [weak self] in self?.coordinator?.newScore() })
    }

    func score(_ id: UUID) -> ScoreViewController? {
        guard let score = try? d.library.load(id) else { return nil }
        let c = coordinator
        return ScoreViewController(score: score, library: d.library, player: d.player, settings: d.settings,
                                   onEdit: { c?.editScore(id) }, onPractice: { c?.practice(id, startMeasure: $0) },
                                   onOriginal: { c?.showOriginal(id) }, onShare: { c?.share($0, from: $1) })
    }

    func editor(_ id: UUID) -> EditorViewController? {
        guard let score = try? d.library.load(id) else { return nil }
        return EditorViewController(score: score, library: d.library, settings: d.settings, player: d.player)
    }

    func newScore(onCreate: @escaping (Score) -> Void) -> NewScoreViewController {
        NewScoreViewController(onCreate: onCreate)
    }

    func practice(_ id: UUID, startMeasure: Int) -> PracticeViewController? {
        guard let score = try? d.library.load(id) else { return nil }
        return PracticeViewController(score: score, startMeasure: startMeasure, settings: d.settings, player: d.player)
    }

    func importProgress(client: OMRClient, file: Data, filename: String, onDone: @escaping ([Score]) -> Void) -> ImportViewController {
        ImportViewController(client: client, file: file, filename: filename, onDone: onDone)
    }

    func original(_ id: UUID) -> OriginalViewController {
        OriginalViewController(url: d.library.originalURL(id))
    }

    func tuner() -> TunerViewController { TunerViewController(settings: d.settings) }

    func settings() -> SettingsViewController {
        SettingsViewController(settings: d.settings, library: d.library, sample: { [weak self] in self?.d.sampleScore() })
    }
}
