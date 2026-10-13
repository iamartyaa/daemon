import Foundation

/// Data at rest relies on FileVault (PRD); Settings warns when it is off.
public enum FileVault {
    /// nil when the status can't be read.
    public static func isOn() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        p.arguments = ["status"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if text.contains("FileVault is On") { return true }
        if text.contains("FileVault is Off") { return false }
        return nil
    }
}
