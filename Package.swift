// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Proof",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Proof",
            path: "Sources/Proof",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ProofTests", dependencies: ["Proof"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
