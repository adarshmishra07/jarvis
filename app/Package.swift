// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pikachu",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to the revision proven in the sandbox by spike S2.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", revision: "624fd5410b2fc8ea06f955500c9ac078e405261f"),
        // Renders Jarvis's Markdown answers (lists, code, tables, links). MIT.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
        // Runs Smart Turn (end-of-turn detection, BSD-2) on the CPU. MIT.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(name: "PikachuCore", dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]),
        .executableTarget(name: "PikachuApp", dependencies: [
            "PikachuCore",
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        ], exclude: ["Fonts"]), // copied into the app bundle by scripts/build-app.sh
        .testTarget(name: "PikachuCoreTests", dependencies: ["PikachuCore"]),
    ]
)
