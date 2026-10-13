import AppKit
import DaemonCore
import SwiftUI

/// First run: welcome → Accessibility (advances on its own once trusted) → the two keys.
/// After `onFinish`, call `MenuBarController.showLivesHereHint()` for the last step.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: OnboardingModel
    private var window: NSWindow?
    private var pollTask: Task<Void, Never>?
    private let isAccessibilityTrusted: () -> Bool

    public init(isAccessibilityTrusted: @escaping () -> Bool, openAccessibilitySettings: @escaping () -> Void,
                onFinish: @escaping () -> Void) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        model = OnboardingModel(openAccessibilitySettings: openAccessibilitySettings, onFinish: onFinish)
        super.init()
        model.finish = { [weak self] in
            self?.close()
            onFinish()
        }
        model.stepChanged = { [weak self] in self?.pollIfNeeded() }
    }

    public func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.Size.onboarding),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = Theme.windowNS
            window.contentView = NSHostingView(rootView: OnboardingView(model: model))
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        pollTask?.cancel()
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) { pollTask?.cancel() }

    private func pollIfNeeded() {
        pollTask?.cancel()
        guard model.step == .accessibility else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isAccessibilityTrusted() {
                    self.model.advance()
                    NSApp.activate(ignoringOtherApps: true)
                    self.window?.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .seconds(Theme.Motion.accessibilityPoll))
            }
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, accessibility, keys }

    @Published private(set) var step = Step.welcome
    @Published var showWhySafe = false
    let openAccessibilitySettings: () -> Void
    var finish: () -> Void
    var stepChanged: () -> Void = {}

    init(step: Step = .welcome, openAccessibilitySettings: @escaping () -> Void = {}, onFinish: @escaping () -> Void = {}) {
        self.step = step
        self.openAccessibilitySettings = openAccessibilitySettings
        finish = onFinish
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
        stepChanged()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack(alignment: .top) {
            Theme.window
            pageDots.padding(.top, 17)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Mark(size: 20, color: Theme.accent, halo: true)
                        .padding(.leading, 2)
                        .padding(.bottom, 26)
                    content
                    Spacer(minLength: 0)
                }
                .frame(width: 270, alignment: .leading)
                Spacer(minLength: 0)
                illustration.frame(width: 250)
            }
            .padding(.leading, 46).padding(.trailing, 44).padding(.top, 64).padding(.bottom, 40)
            .id(model.step)
            .transition(.opacity)
        }
        .frame(width: Theme.Size.onboarding.width, height: Theme.Size.onboarding.height)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle().fill(step == model.step ? Theme.textPrimary : Theme.textTertiary.opacity(0.6))
                    .frame(width: 5, height: 5)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:
            headline("Keep it now.\nRecall it later.")
            paragraph("Press one key to keep whatever you are looking at. Later, describe it in your own words and it comes back. Everything stays on this Mac.")
            AccentButton(title: "Continue", action: model.advance).padding(.top, 28)
        case .accessibility:
            headline("Let Daemon read\nwhat you select")
            paragraph("Accessibility lets Daemon see the text you have selected when you press ⌃⌥S, and paste into the same app when you press ↵. Nothing leaves this Mac.")
            AccentButton(title: "Open System Settings", action: model.openAccessibilitySettings).padding(.top, 26)
            Button { model.showWhySafe.toggle() } label: {
                Text("Why this is safe").underline().font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            if model.showWhySafe {
                Text("Daemon only reads the selection when you press ⌃⌥S. It never logs keystrokes, and it has no servers to send anything to.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        case .keys:
            headline("Two keys\nto remember")
            keyRow(["⌃", "⌥", "S"], title: "Keep", detail: "Whatever you are looking at.\nHold it to speak a note.")
                .padding(.top, 2)
            keyRow(["⌃", "⌥", "Space"], title: "Recall", detail: "Search by meaning, press ↵ to paste it where you were.")
                .padding(.top, 16)
            AccentButton(title: "Start using Daemon", action: model.advance).padding(.top, 26)
        }
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.headline)
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(-2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 18)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func keyRow(_ keys: [String], title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { Kbd(label: $0, font: .system(size: 14)) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var illustration: some View {
        switch model.step {
        case .welcome: WelcomeIllustration()
        case .accessibility: PrivacyIllustration()
        case .keys: NotesIllustration()
        }
    }
}

struct AccentButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text("↵").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 18)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 32)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.button))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Illustrations (static drawings, not live state)

private struct IllustrationFrame<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .background(Theme.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
    }
}

struct WelcomeIllustration: View {
    var body: some View {
        IllustrationFrame {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Mark(size: 12, color: Theme.textSecondary)
                    Text("the pricing toggle, dark").font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 38)
                Divider().overlay(Theme.divider)
                VStack(spacing: 2) {
                    ForEach(Array(MockRecallDataSource.sampleHits.prefix(4).enumerated()), id: \.offset) { i, hit in
                        ResultRow(hit: hit, thumbnail: nil, selected: i == 0)
                    }
                }
                .padding(6)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 300)
    }
}

struct PrivacyIllustration: View {
    var body: some View {
        IllustrationFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Privacy & Security").foregroundStyle(Theme.textSecondary)
                    Text("›").foregroundStyle(Theme.textTertiary)
                    Text("Accessibility").foregroundStyle(Theme.textPrimary)
                }
                .font(Theme.Font.small)
                VStack(spacing: 0) {
                    row("Raycast", on: false, daemon: false)
                    Divider().overlay(Theme.divider)
                    row("Daemon", on: true, daemon: true)
                    Divider().overlay(Theme.divider)
                    row("Rectangle", on: false, daemon: false)
                }
                .background(Theme.panelTop, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
                Text("Turn on Daemon, then return here.\nDaemon continues automatically.")
                    .font(Theme.Font.small).foregroundStyle(Theme.textSecondary).lineSpacing(2)
            }
            .padding(12)
        }
        .padding(.top, 34)
    }

    private func row(_ name: String, on: Bool, daemon: Bool) -> some View {
        HStack(spacing: 8) {
            if daemon {
                Mark(size: 13, color: Theme.textPrimary)
            } else {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.kbdBorder, lineWidth: 1).frame(width: 13, height: 13)
            }
            Text(name).font(.system(size: 12, weight: daemon ? .semibold : .regular)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Capsule().fill(on ? Theme.accent : Theme.well)
                .overlay(Capsule().strokeBorder(Theme.kbdBorder.opacity(on ? 0 : 1), lineWidth: 1))
                .frame(width: 30, height: 17)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                }
        }
        .padding(.horizontal, 10).frame(height: 38)
    }
}

struct NotesIllustration: View {
    var body: some View {
        IllustrationFrame {
            VStack(spacing: 0) {
                HStack {
                    Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("KEPT").font(Theme.Font.label).tracking(1).foregroundStyle(Theme.textSecondary)
                    Mark(size: 10, color: Theme.accent)
                }
                .padding(.horizontal, 10).frame(height: 28)
                Divider().overlay(Theme.divider)
                ZStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pricing page review").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Group {
                            Text("Keep the plan cards simple.")
                            Text("Default to yearly, show monthly small.")
                                .background(Theme.accent.opacity(0.14))
                            Text("Annual discount badge on Pro only.")
                        }
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panelTop, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 10).padding(.top, 52)

                    HStack(spacing: 8) {
                        Image(systemName: "text.alignleft").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 26, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.kbdBorder, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                                Text("Kept").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            }
                            Text("from Notes").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Kbd(label: "⇥", font: .system(size: 10))
                    }
                    .padding(8)
                    .frame(width: 186)
                    .background(Theme.panelTop, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                }
            }
        }
        .frame(height: 330)
    }
}
