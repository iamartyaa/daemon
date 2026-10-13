import AppKit
import DaemonCore
import KeyboardShortcuts
import SwiftUI

/// Toasts near the menu bar: "Kept", the voice-note listener, and short notices.
/// One panel is created up front so a toast appears in the same frame as the hotkey.
@MainActor
public final class ToastPresenter {
    private let model = ToastModel()
    private let panel: ToastPanel
    private var hideTask: Task<Void, Never>?
    private var tabTask: Task<Void, Never>?

    public init() {
        panel = ToastPanel(contentRect: NSRect(origin: .zero, size: Theme.Size.toast),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the SwiftUI card draws its own soft shadow
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ToastView(model: model))
        model.onNoteDone = { [weak self] in self?.dismiss() }
    }

    /// "Kept · from Figma · Pricing …". Tab while it shows opens a one-line note; Enter calls `onNote`.
    public func showKept(item: Item, thumbnailURL: URL?, onNote: @escaping (String) -> Void) {
        model.onNote = onNote
        model.note = ""
        model.state = .kept(item, thumbnailURL)
        present(for: Theme.Motion.toastVisible)
        listenForTab()
    }

    public func showListening() {
        model.levels = Array(repeating: 0.08, count: ToastModel.barCount)
        model.state = .listening(Date())
        present(for: nil)
    }

    /// Microphone level, 0...1. Call ~20 times a second.
    public func updateLevel(_ level: Float) {
        model.levels.removeFirst()
        model.levels.append(min(1, max(0.08, level)))
    }

    public func finishListening() {
        if case .listening = model.state { dismiss() }
    }

    /// Short notices like "Copied, press ⌘V".
    public func showMessage(_ message: String) {
        model.state = .message(message)
        present(for: 2)
    }

    // MARK: -

    private func present(for seconds: Double?) {
        hideTask?.cancel()
        tabTask?.cancel()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - Theme.Size.toast.width - 4, y: f.maxY - Theme.Size.toast.height))
        }
        model.shownAt = Date()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = Theme.Motion.toastFade; panel.animator().alphaValue = 1 }
        guard let seconds else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.model.editingNote else { return }
            self.dismiss()
        }
    }

    private func dismiss() {
        hideTask?.cancel()
        tabTask?.cancel()
        model.editingNote = false
        NSAnimationContext.runAnimationGroup({ $0.duration = Theme.Motion.toastFade; panel.animator().alphaValue = 0 },
                                            completionHandler: { [panel] in
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    /// Tab is grabbed system-wide only while the Kept toast is up.
    private func listenForTab() {
        tabTask = Task { [weak self] in
            for await event in KeyboardShortcuts.events(for: .init(.tab)) where event == .keyDown {
                self?.beginNote()
                return
            }
        }
    }

    private func beginNote() {
        tabTask?.cancel()
        hideTask?.cancel()
        model.editingNote = true
        panel.makeKey()
    }
}

final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ToastModel: ObservableObject {
    enum State { case none, kept(Item, URL?), listening(Date), message(String) }
    static let barCount = 26

    @Published var state = State.none
    @Published var levels = Array(repeating: Float(0.08), count: barCount)
    @Published var editingNote = false
    @Published var note = ""
    @Published var shownAt = Date()
    var onNote: (String) -> Void = { _ in }
    var onNoteDone: () -> Void = {}
}

struct ToastView: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        Group {
            switch model.state {
            case .none: Color.clear.frame(width: 0, height: 0)
            case let .kept(item, url): KeptToast(model: model, item: item, thumbnail: url)
            case let .listening(start): ListeningToast(levels: model.levels, start: start)
            case let .message(text):
                Text(text).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16).frame(height: 40)
                    .toastCard()
            }
        }
        .padding(.top, 8).padding(.trailing, 12).padding(.leading, 28).padding(.bottom, 24)
        .frame(width: Theme.Size.toast.width, height: Theme.Size.toast.height, alignment: .topTrailing)
    }
}

extension View {
    func toastCard() -> some View {
        background(.panelFill, in: RoundedRectangle(cornerRadius: Theme.Radius.toast))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.toast).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.toast))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
}

struct KeptToast: View {
    @ObservedObject var model: ToastModel
    let item: Item
    let thumbnail: URL?
    @FocusState private var noteFocused: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(item: item, url: thumbnail, radius: 7).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("Kept").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                }
                if model.editingNote {
                    TextField("", text: $model.note, prompt: Text("Add a note…").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                        .focused($noteFocused)
                        .onSubmit {
                            let note = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !note.isEmpty { model.onNote(note) }
                            model.onNoteDone()
                        }
                        .onExitCommand { model.onNoteDone() }
                        .onAppear { noteFocused = true }
                } else {
                    Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !model.editingNote {
                KeyHint(key: "⇥", label: "add a note")
            } else {
                Kbd(label: "↵", font: Theme.Font.small)
            }
        }
        .padding(.leading, 12).padding(.trailing, 14)
        .frame(width: Theme.Size.toastCard.width, height: Theme.Size.toastCard.height)
        .overlay(alignment: .bottomLeading) {
            if !model.editingNote {
                Rectangle().fill(Theme.accent.opacity(0.7)).frame(width: Theme.Size.toastCard.width * progress, height: 2)
            }
        }
        .toastCard()
        .onAppear(perform: runProgress)
        .onChange(of: model.shownAt) { runProgress() }
    }

    private var subtitle: String {
        ["from \(item.sourceLabel)", item.windowTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private func runProgress() {
        progress = 0
        withAnimation(.linear(duration: Theme.Motion.toastVisible)) { progress = 1 }
    }
}

struct ListeningToast: View {
    let levels: [Float]
    let start: Date

    var body: some View {
        HStack(spacing: 14) {
            Mark(size: 18, color: Theme.accent, halo: true)
            VStack(alignment: .leading, spacing: 6) {
                Waveform(levels: levels, color: Theme.accent, barWidth: 2, spacing: 3.5, height: 24)
                    .animation(.easeOut(duration: 0.08), value: levels)
                (Text("Listening… ").foregroundStyle(Theme.textPrimary)
                    + Text("release to keep").foregroundStyle(Theme.textSecondary))
                    .font(Theme.Font.body)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(timecode(ms: max(0, Int(context.date.timeIntervalSince(start) * 1000))))
                        .font(Theme.Font.mono).foregroundStyle(Theme.textSecondary)
                }
                Text("⌃⌥S held").font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: Theme.Size.toastCard.width, height: Theme.Size.toastCard.height)
        .toastCard()
    }
}
