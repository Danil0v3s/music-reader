// swift-tools-version: 5.9
import PackageDescription

// ScoreKit — the platform-agnostic core: music theory (pitch, intervals, keys, clefs, durations, tempo,
// tuning systems), the score model, MusicXML import/export, notation layout, the playback schedule,
// pitch detection for intonation, the OMR server client and score storage. UI-free: no UIKit, so it
// runs and tests on macOS (`swift test`) and is the reference the Android `:core:*` modules port.
let package = Package(
    name: "ScoreKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "ScoreKit", targets: ["ScoreKit"])
    ],
    targets: [
        .target(name: "ScoreKit"),
        .testTarget(name: "ScoreKitTests", dependencies: ["ScoreKit"], resources: [.copy("Fixtures")])
    ]
)
