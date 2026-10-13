// swift-tools-version: 6.2
// Runtime spike (daemon-7tl), MLX side. Separate package so the app never resolves MLX.
// Build with xcodebuild (SwiftPM alone cannot compile MLX's Metal shaders).
import PackageDescription

let package = Package(
    name: "MLXSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 4cc5504 = main after ml-explore/mlx-swift-lm#684 (EmbeddingGemma 2) merged
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "4cc55045125335a245f74ab1d817e9d261a7e85a",
                 traits: []),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "MLXSpike",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)] // throwaway spike; skip strict Sendable checks
        ),
    ]
)
