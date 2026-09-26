// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Triage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TriageCore"),
        .executableTarget(name: "Triage", dependencies: ["TriageCore"]),
        .testTarget(name: "TriageCoreTests", dependencies: ["TriageCore"]),
    ],
    swiftLanguageModes: [.v5]
)
