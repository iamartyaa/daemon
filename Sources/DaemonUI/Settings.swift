import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// Values and actions the Settings window shows. The app owns persistence: observe the published
/// properties (e.g. `model.$excludedApps.sink { ... }`) and supply the closures.
@MainActor
public final class SettingsModel: ObservableObject {
    @Published public var excludedApps: [URL]
    @Published public var checkForUpdates: Bool
    @Published public var sendCrashReports: Bool
    @Published public var storageLocation: URL
    @Published public var librarySize: Int64
    @Published public var isFileVaultOn: Bool
    public var version: String
    public var onMoveStorage: () -> Void
    public var onExport: () -> Void
    /// Numbers only (counts, sizes, timings). "Copy my stats" puts this on the clipboard.
    public var stats: () -> String

    public init(excludedApps: [URL] = [], checkForUpdates: Bool = true, sendCrashReports: Bool = false,
                storageLocation: URL, librarySize: Int64 = 0, isFileVaultOn: Bool = true, version: String,
                onMoveStorage: @escaping () -> Void = {}, onExport: @escaping () -> Void = {},
                stats: @escaping () -> String = { "" }) {
        self.excludedApps = excludedApps
        self.checkForUpdates = checkForUpdates
        self.sendCrashReports = sendCrashReports
        self.storageLocation = storageLocation
        self.librarySize = librarySize
        self.isFileVaultOn = isFileVaultOn
        self.version = version
        self.onMoveStorage = onMoveStorage
        self.onExport = onExport
        self.stats = stats
    }
}

@MainActor
public final class SettingsWindowController {
    private let window: NSWindow

    public init(keepShortcut: KeyboardShortcuts.Name, recallShortcut: KeyboardShortcuts.Name, model: SettingsModel) {
        let view = SettingsView(keepShortcut: keepShortcut, recallShortcut: recallShortcut, model: model)
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Daemon Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.windowNS
    }

    public func show() {
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let keepShortcut: KeyboardShortcuts.Name
    let recallShortcut: KeyboardShortcuts.Name
    @ObservedObject var model: SettingsModel
    @State private var copiedStats = false

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Keep") { KeyboardShortcuts.Recorder(for: keepShortcut) }
                LabeledContent("Recall") { KeyboardShortcuts.Recorder(for: recallShortcut) }
                caption("Hold Keep to speak a note.")
            }

            Section("Excluded apps") {
                caption("Daemon never keeps anything from these apps.")
                ForEach(model.excludedApps, id: \.self) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 18, height: 18)
                        Text(app.deletingPathExtension().lastPathComponent)
                        Spacer()
                        Button { model.excludedApps.removeAll { $0 == app } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(app.deletingPathExtension().lastPathComponent)")
                    }
                }
                Button("Add App…", action: addApps)
            }

            Section("Storage") {
                LabeledContent("Location") {
                    HStack {
                        Text(model.storageLocation.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(Theme.textSecondary)
                        Button("Move…", action: model.onMoveStorage)
                    }
                }
                LabeledContent("Library size",
                               value: ByteCountFormatter.string(fromByteCount: model.librarySize, countStyle: .file))
                Button("Export everything…", action: model.onExport)
            }

            Section("Privacy") {
                if !model.isFileVaultOn {
                    Label {
                        Text("FileVault is off, so your library is stored unencrypted. Turn it on in System Settings › Privacy & Security › FileVault.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                    }
                }
                Toggle("Check for updates", isOn: $model.checkForUpdates)
                Toggle(isOn: $model.sendCrashReports) {
                    Text("Send crash reports")
                    Text("Off unless you turn it on. Reports never include what you kept.")
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy my stats")
                        caption("Counts and timings only, never content.")
                    }
                    Spacer()
                    Button(copiedStats ? "Copied" : "Copy", action: copyStats)
                }
            }

            Section("About") {
                LabeledContent("Version", value: model.version)
                LabeledContent("Meaning model", value: "EmbeddingGemma 2 · Apache 2.0")
                caption("Everything Daemon keeps stays on this Mac.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.window)
        .tint(Theme.accent)
        .frame(width: 520, height: 640)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        model.excludedApps += panel.urls.filter { !model.excludedApps.contains($0) }
    }

    private func copyStats() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.stats(), forType: .string)
        copiedStats = true
    }
}
