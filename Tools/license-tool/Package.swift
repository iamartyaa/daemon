// swift-tools-version: 5.10
import PackageDescription

// Standalone; not part of the app package. LicenseKey.swift is a symlink to the app's copy so the format can't drift.
let package = Package(
    name: "license-tool",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "license-tool")]
)
