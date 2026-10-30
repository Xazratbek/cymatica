// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cymatica",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Cymatica",
            path: "Sources/Cymatica"
        )
    ],
    // The Core Audio IO block and the Metal draw loop share plain buffers on purpose;
    // Swift 5 mode keeps strict-concurrency checking from fighting the real-time path.
    swiftLanguageModes: [.v5]
)
