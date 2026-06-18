// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nuvi",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Included fallback engine for Auto/WhisperKit modes. A true
        // SpeechAnalyzer-only build would need a separate manifest/target.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        // NVIDIA Parakeet (TDT) CoreML ASR for Apple Silicon. WhisperKit only
        // runs Whisper, so Parakeet needs its own engine backed by this.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Nuvi",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Nuvi",
            resources: [
                .process("Infrastructure/Settings/ModelsCatalog.json")
            ],
            // AppKit / AVFoundation / Metal interop is far smoother under the
            // Swift 5 language mode. We still build with the Swift 6.3 toolchain;
            // we just opt out of strict-concurrency hard errors at the boundaries
            // with the system frameworks. Domain code stays clean either way.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NuviTests",
            dependencies: ["Nuvi"],
            path: "Tests/NuviTests"
        )
    ]
)
