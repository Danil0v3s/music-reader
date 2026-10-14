// swift-tools-version: 5.9
import PackageDescription

// Builds shared/sounds/cello from the University of Iowa cello recordings. Run once (see README); the result is
// committed, so the app never needs this tool.
let package = Package(
    name: "SampleBuilder",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../ios/ScoreKit")],
    targets: [.executableTarget(name: "SampleBuilder", dependencies: ["ScoreKit"])]
)
