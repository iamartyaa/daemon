import AppKit
import DaemonCore
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
    /// Persist and purge on change (`model.$retention.dropFirst().sink { ... }`).
    @Published public var retention: RetentionPolicy
    @Published public var oldestItemDate: Date?
    /// Set while the user is asked to confirm a shorter window that removes items now.
    @Published public var pendingRetention: RetentionChange?
    /// How many items a policy would remove right now.
    public var countRemoved: (RetentionPolicy) async -> Int = { _ in 0 }
    public var version: String
    public var onMoveStorage: () -> Void
    public var onExport: () -> Void
    /// Numbers only (counts, sizes, timings). "Copy my stats" puts this on the clipboard.
    public var stats: () -> String
    /// Shown as a License section when set.
    public var license: LicenseManager?
    public var onBuy: () -> Void = {}

    public init(excludedApps: [URL] = [], checkForUpdates: Bool = true, sendCrashReports: Bool = false,
                storageLocation: URL, librarySize: Int64 = 0, isFileVaultOn: Bool = true,
                retention: RetentionPolicy = .default, oldestItemDate: Date? = nil, version: String,
                onMoveStorage: @escaping () -> Void = {}, onExport: @escaping () -> Void = {},
                stats: @escaping () -> String = { "" }) {
        self.excludedApps = excludedApps
        self.checkForUpdates = checkForUpdates
        self.sendCrashReports = sendCrashReports
        self.storageLocation = storageLocation
        self.librarySize = librarySize
        self.isFileVaultOn = isFileVaultOn
        self.retention = retention
        self.oldestItemDate = oldestItemDate
        self.version = version
        self.onMoveStorage = onMoveStorage
        self.onExport = onExport
        self.stats = stats
    }

    /// Lengthening, or shortening with nothing to remove, applies at once; otherwise asks first.
    public func requestRetention(_ policy: RetentionPolicy) async {
        guard policy != retention else { return }
        if policy.days < retention.days {
            let count = await countRemoved(policy)
            if count > 0 {
                pendingRetention = RetentionChange(policy: policy, count: count)
                return
            }
        }
        retention = policy
    }

    public func confirmRetention() {
        if let change = pendingRetention { retention = change.policy }
        pendingRetention = nil
    }

    /// "Oldest item: 23 days ago"
    public static func oldestText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return "Oldest item: today"
        case 1: return "Oldest item: 1 day ago"
        default: return "Oldest item: \(days) days ago"
        }
    }
}

public struct RetentionChange: Equatable, Sendable {
    public var policy: RetentionPolicy
    public var count: Int
    /// "12 items older than 7 days will be removed now."
    public var message: String {
        "\(count) \(count == 1 ? "item" : "items") older than \(policy.title) will be removed now."
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
            if let license = model.license {
                Section { LicenseSection(manager: license, onBuy: model.onBuy) }
            }

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
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Keep items for", selection: Binding(
                        get: { model.retention },
                        set: { policy in Task { await model.requestRetention(policy) } })) {
                        ForEach(RetentionPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    caption("Older items are removed automatically, including their files.")
                    if let oldest = SettingsModel.oldestText(model.oldestItemDate) { caption(oldest) }
                }
                Button("Export everything…", action: model.onExport)
            }
            .alert("Keep items for \(model.pendingRetention?.policy.title ?? "")?",
                   isPresented: Binding(get: { model.pendingRetention != nil },
                                        set: { if !$0 { model.pendingRetention = nil } }),
                   presenting: model.pendingRetention) { _ in
                Button("Remove", role: .destructive) { model.confirmRetention() }
                Button("Cancel", role: .cancel) {}
            } message: { change in
                Text(change.message)
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
