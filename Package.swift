// swift-tools-version: 5.10
import PackageDescription

// Ownership (one agent per target/folder; Contracts.swift and this file are shared, change only via integration):
//   DaemonCore/Library   storage: GRDB schema, file library, export
//   DaemonCore/Search    query parsing, vector index, hybrid ranking
//   DaemonCore/Extract   item -> segments (chunking, PDF, OCR, audio/video splitting)
//   DaemonCore/Embedding EmbedderClient (talks to DaemonEmbedder process)
//   DaemonEmbedder       background model process (llama.cpp)
//   DaemonCapture        hotkeys, context rules, selection/Finder/browser, screenshots, voice, paste-back
//   DaemonUI             Recall panel, toasts, menu bar, onboarding, settings, Theme
//   Daemon               app entry point and wiring
let package = Package(
    name: "Daemon",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "DaemonCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "DaemonUI", dependencies: ["DaemonCore", "KeyboardShortcuts"]),
        .target(name: "DaemonCapture", dependencies: ["DaemonCore", "KeyboardShortcuts"]),
        .executableTarget(
            name: "DaemonEmbedder",
            dependencies: ["DaemonCore", "llama"],
            linkerSettings: [rpathNextToBinary]
        ),
        .executableTarget(
            name: "Daemon",
            dependencies: ["DaemonCore", "DaemonUI", "DaemonCapture", "Sparkle", "KeyboardShortcuts"],
            linkerSettings: [rpathNextToBinary]
        ),

        .testTarget(name: "DaemonCoreTests", dependencies: ["DaemonCore"]),
        .testTarget(name: "DaemonUITests", dependencies: ["DaemonUI"]),
        .testTarget(name: "DaemonCaptureTests", dependencies: ["DaemonCapture"]),

        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11564/llama-b11564-xcframework.zip",
            checksum: "d1bb947787bcc226d858c46e4e56c72133ee29554449ba07e35810281bc283dd"
        ),
        // Runtime spike (daemon-7tl), kept as a benchmark for the embedder.
        .executableTarget(name: "EmbedSpike", dependencies: ["llama"], linkerSettings: [rpathNextToBinary]),
    ]
)

// SwiftPM copies llama.framework next to the binary but omits the rpath under Command Line Tools
var rpathNextToBinary: LinkerSetting { .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path"]) }
