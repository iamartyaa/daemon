import AppKit
import CryptoKit
import SwiftUI
import XCTest
import DaemonCore
@testable import DaemonUI

private final class MemoryStore: LicenseStore {
    var values: [String: String] = [:]
    func read(_ account: String) -> String? { values[account] }
    func write(_ value: String?, _ account: String) { values[account] = value }
}

/// Renders the license views to .build/ui-snapshots/ for eyeballing (not compared, not committed).
@MainActor
final class LicenseViewTests: XCTestCase {
    let signer = Curve25519.Signing.PrivateKey()

    func manager(daysAgo: Int) -> LicenseManager {
        let store = MemoryStore()
        store.values["trialStart"] = String(Date().addingTimeInterval(-Double(daysAgo) * 86_400).timeIntervalSince1970)
        return LicenseManager(store: store, publicKey: signer.publicKey)
    }

    func testRenderTrialEnded() throws {
        try render(TrialEndedView(onBuy: {}, onEnterKey: {}), "trial-ended")
    }

    func testRenderLicenseSection() throws {
        let section = { (m: LicenseManager) in
            LicenseSection(manager: m, onBuy: {}).padding(24).frame(width: 480).background(Theme.window)
        }
        try render(section(manager(daysAgo: 5)), "license-trial")
        try render(section(manager(daysAgo: 20)), "license-expired")

        let licensed = manager(daysAgo: 20)
        try licensed.activate(LicenseKey.issue(License(email: "ana@example.com"), privateKey: signer))
        try render(section(licensed), "license-licensed")
    }

    private func render(_ view: some View, _ name: String) throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../.build/ui-snapshots").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (suffix, appearance) in [("ivory", NSAppearance.Name.aqua), ("smoked", .darkAqua)] {
            // NSHostingView rather than ImageRenderer: ImageRenderer draws AppKit-backed TextFields as placeholders.
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(host.bounds.width, 0)
            try png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
