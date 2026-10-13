// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Daemon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Daemon"),

        // Runtime spike (daemon-7tl): EmbeddingGemma 2 on llama.cpp. Delete once the runtime is chosen.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11564/llama-b11564-xcframework.zip",
            checksum: "d1bb947787bcc226d858c46e4e56c72133ee29554449ba07e35810281bc283dd"
        ),
        .executableTarget(
            name: "EmbedSpike",
            dependencies: ["llama"],
            // SwiftPM copies llama.framework next to the binary but omits the rpath under Command Line Tools
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path"])]
        ),
    ]
)
