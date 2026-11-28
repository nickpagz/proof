// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Proof",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CProofWebP", path: "Vendor/libwebp",
                exclude: ["AUTHORS", "COPYING", "PATENTS", "UPSTREAM.md"],
                cSettings: [.headerSearchPath("."), .define("WEBP_USE_THREAD")]),
        .executableTarget(
            name: "Proof",
            dependencies: ["CProofWebP"],
            path: "Sources/Proof",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ProofTests", dependencies: ["Proof"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
