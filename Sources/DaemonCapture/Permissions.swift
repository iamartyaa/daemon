import AppKit
import ApplicationServices
import AVFoundation

/// Status and request helpers for the permissions Daemon asks for. No Full Disk Access.
public enum Permissions {
    public enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case microphone = "Privacy_Microphone"
        case automation = "Privacy_Automation"
    }

    /// Selected text and pasting. Asked at onboarding.
    public static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once) pointing at System Settings. Returns the current status.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Screenshots. Asked on the first screenshot.
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// Voice notes. Asked on the first voice note.
    public static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    public static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    public static func openSettings(_ pane: Pane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}
