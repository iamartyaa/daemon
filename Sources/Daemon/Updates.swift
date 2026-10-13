import Foundation
import Sparkle

/// Sparkle automatic updates (PRD: the update check is the only regular network use, and can be turned off).
/// Sparkle refuses to run without an EdDSA key and shows an error alert, so it only starts once
/// SUPublicEDKey is in Info.plist (generate with Sparkle's generate_keys before the first release).
@MainActor
final class Updates {
    private let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        controller = (key?.isEmpty == false)
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkNow() { controller?.checkForUpdates(nil) }
}
