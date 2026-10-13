import AppKit
import AVFoundation
import DaemonCore
import SwiftUI

// MARK: - Explainer videos

/// Finds `<name>-ivory.mp4` / `<name>-smoked.mp4`: in the app bundle's Resources/Onboarding, or for
/// `swift run` and tests in the repo's Resources/Onboarding, found by walking up from the running binaries.
enum OnboardingVideo {
    static let directories: [URL] = {
        var dirs = Bundle.main.resourceURL.map { [$0.appending(path: "Onboarding")] } ?? []
        for bundle in [Bundle.main] + Bundle.allBundles {
            var dir = bundle.bundleURL
            while dir.pathComponents.count > 1 {
                dir.deleteLastPathComponent()
                let candidate = dir.appending(path: "Resources/Onboarding")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    dirs.append(candidate)
                    break
                }
            }
        }
        return dirs
    }()

    static func url(_ name: String, dark: Bool, in dirs: [URL] = directories) -> URL? {
        let file = "\(name)-\(dark ? "smoked" : "ivory").mp4"
        return dirs.lazy.map { $0.appending(path: file) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func exists(_ name: String) -> Bool { url(name, dark: false) != nil || url(name, dark: true) != nil }
}

/// A looping, muted explainer for the current appearance, or a still drawing when the file isn't there.
/// `onLoop` runs after each pass (the drawing stands in for one pass every few seconds).
struct ExplainerVideo: View {
    let name: String
    var onLoop: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let url = OnboardingVideo.url(name, dark: colorScheme == .dark) {
                LoopingPlayer(url: url, onLoop: onLoop)
            } else {
                placeholder.task {
                    try? await Task.sleep(for: .seconds(Theme.Onboarding.clipDwell))
                    if !Task.isCancelled { onLoop() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(name)
        .transition(.opacity)
        .mediaFrame()
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var placeholder: some View {
        switch name {
        case "keep-text": KeepTextIllustration()
        case "keep-voice": KeepVoiceIllustration()
        case "keep-region": KeepRegionIllustration()
        case "filters": RecallIllustration(query: "pricing from:figma last week")
        default: RecallIllustration(query: "the pricing toggle, dark")
        }
    }

    private var accessibilityText: String {
        switch name {
        case "keep-text": "Selecting text and pressing Control Option S keeps it."
        case "keep-voice": "Holding Control Option S records a voice note."
        case "keep-region": "With nothing selected, drag over part of the screen to keep it."
        default: "Describing something in Recall brings it back."
        }
    }
}

struct LoopingPlayer: NSViewRepresentable {
    let url: URL
    let onLoop: () -> Void

    func makeNSView(context: Context) -> PlayerView { PlayerView() }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.onLoop = onLoop
        view.play(url)     // a new URL when the appearance changes
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.stop() }
}

final class PlayerView: NSView {
    var onLoop: () -> Void = {}
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var url: URL?
    private var endObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.cornerRadius = Theme.Radius.card
        playerLayer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { playerLayer }

    func play(_ url: URL) {
        guard url != self.url else { return }
        stop()
        self.url = url
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        self.looper = looper
        playerLayer.player = player
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item, self.looper?.loopingPlayerItems.contains(item) == true else { return }
                self.onLoop()
            }
        }
        player.play()
    }

    func stop() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playerLayer.player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.player = nil
        url = nil
    }
}

extension View {
    /// The rounded, outlined well every video and drawing sits in.
    func mediaFrame() -> some View {
        background(Theme.well.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Selectable practice text

/// Real selectable text, so ⌃⌥S reads it like any other app's selection.
struct SelectableText: NSViewRepresentable {
    let text: String
    let font: NSFont

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.selectedTextAttributes = [.backgroundColor: Theme.accentNS.withAlphaComponent(0.22)]
        view.setAccessibilityLabel("Practice sentence")
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(Theme.textPrimary), .paragraphStyle: style,
        ]))
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}

// MARK: - Drawings (stand-ins for the videos, and the steps without one)

/// A small window with a title bar, as the mock apps in the drawings.
private struct MockWindow<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.kbdBorder).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .padding(.leading, 6)
                Spacer()
                if let trailing {
                    Text(trailing).font(Theme.Font.label).tracking(1).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12).frame(height: 30)
            Divider().overlay(Theme.divider)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.panelTop, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.thumb).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}

private struct NoteBody: View {
    var highlight = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Pricing page review").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Group {
                Text("Keep the plan cards simple.")
                Text("Default to yearly, show monthly small.")
                    .padding(.horizontal, 2)
                    .background(highlight ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 2))
                    .padding(.horizontal, -2)
                Text("Annual discount badge on Pro only.")
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
    }
}

/// A Kept toast in miniature.
private struct MiniKeptToast: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.alignleft").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.thumb).strokeBorder(Theme.kbdBorder, lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text("Kept").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                }
                Text("from Notes").font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 10)
            Kbd(label: "⇥", font: Theme.Font.small)
        }
        .padding(9)
        .frame(width: 196)
        .toastCard()
    }
}

struct KeepTextIllustration: View {
    var body: some View {
        MockWindow(title: "Notes") { NoteBody() }
            .padding(EdgeInsets(top: 44, leading: 28, bottom: -20, trailing: 64))
            .overlay(alignment: .topTrailing) { MiniKeptToast().padding(16) }
    }
}

struct KeepVoiceIllustration: View {
    @State private var start = Date().addingTimeInterval(-4)

    var body: some View {
        ZStack(alignment: .top) {
            MockWindow(title: "Notes") { NoteBody(highlight: false) }
                .padding(EdgeInsets(top: 44, leading: 28, bottom: -20, trailing: 64))
                .opacity(0.55)
            ListeningToast(levels: Waveform.sample + Waveform.sample.prefix(4), start: start)
                .scaleEffect(0.9)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
        }
    }
}

struct KeepRegionIllustration: View {
    var body: some View {
        ZStack {
            MockWindow(title: "Figma") {
                HStack(spacing: 12) {
                    ForEach(["Starter", "Pro"], id: \.self) { plan in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan).font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
                            Text(plan == "Pro" ? "$12" : "$8").font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Capsule().fill(Theme.divider).frame(width: 70, height: 4)
                            Capsule().fill(Theme.divider).frame(width: 50, height: 4)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.thumb)
                            .strokeBorder(plan == "Pro" ? Theme.accent : Theme.border, lineWidth: 1))
                    }
                }
                .padding(18)
            }
            .padding(EdgeInsets(top: 28, leading: 28, bottom: -20, trailing: 28))
            Color.black.opacity(0.18)
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Theme.textPrimary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .background(Theme.panelTop.opacity(0.35))
                .frame(width: 196, height: 106)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .light)).foregroundStyle(Theme.textPrimary)
                        .offset(x: 8, y: 8)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("196 × 106").font(Theme.Font.small).monospacedDigit().foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5).frame(height: 18)
                        .background(Theme.panelTop, in: RoundedRectangle(cornerRadius: Theme.Radius.kbd))
                        .offset(y: 24)
                }
                .offset(x: 52, y: 26)
        }
    }
}

struct RecallIllustration: View {
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Mark(size: 14, color: Theme.textSecondary)
                Text(query).font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
                Rectangle().fill(Theme.accent).frame(width: 1.5, height: 17)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 46)
            Divider().overlay(Theme.divider)
            VStack(spacing: 2) {
                ForEach(Array(MockRecallDataSource.sampleHits.prefix(4).enumerated()), id: \.offset) { i, hit in
                    ResultRow(hit: hit, thumbnail: nil, selected: i == 0)
                }
            }
            .padding(6)
        }
        .background(.panelFill, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.thumb).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .padding(EdgeInsets(top: 22, leading: 28, bottom: -20, trailing: 28))
    }
}

/// System Settings › Accessibility, with Daemon's switch following the real permission.
struct PrivacyIllustration: View {
    var daemonOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Privacy & Security").foregroundStyle(Theme.textSecondary)
                Text("›").foregroundStyle(Theme.textTertiary)
                Text("Accessibility").foregroundStyle(Theme.textPrimary)
            }
            .font(Theme.Font.caption)
            VStack(spacing: 0) {
                row("Raycast", on: false, daemon: false)
                Divider().overlay(Theme.divider)
                row("Daemon", on: daemonOn, daemon: true)
                Divider().overlay(Theme.divider)
                row("Rectangle", on: false, daemon: false)
            }
            .background(Theme.panelTop, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.thumb).strokeBorder(Theme.border, lineWidth: 1))
            Text(daemonOn ? "Daemon is on. Continuing…" : "Turn on Daemon, then come back here.\nDaemon continues by itself.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineSpacing(2)
                .contentTransition(.opacity)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .mediaFrame()
        .animation(reduceMotion ? Theme.Onboarding.calm : Theme.Onboarding.step, value: daemonOn)
    }

    private func row(_ name: String, on: Bool, daemon: Bool) -> some View {
        HStack(spacing: 10) {
            if daemon {
                Mark(size: 15, color: Theme.textPrimary)
            } else {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.kbdBorder, lineWidth: 1).frame(width: 15, height: 15)
            }
            Text(name).font(.system(size: 13, weight: daemon ? .semibold : .regular)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Capsule().fill(on ? Theme.accent : Theme.well)
                .overlay(Capsule().strokeBorder(Theme.kbdBorder.opacity(on ? 0 : 1), lineWidth: 1))
                .frame(width: 34, height: 19)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 15, height: 15).padding(2)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                }
        }
        .padding(.horizontal, 12).frame(height: 44)
    }
}

/// The top right of the screen: the mark in the menu bar, glowing, with its hint underneath.
struct MenuBarIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 18) {
                Spacer()
                Mark(size: 15, color: Theme.accent)
                    .background(Circle()
                        .fill(RadialGradient(colors: [Theme.accent.opacity(glow ? 0.3 : 0), Theme.accent.opacity(0)],
                                             center: .center, startRadius: 6, endRadius: 18))
                        .frame(width: 36, height: 36))
                Image(systemName: "battery.75percent").font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
                Text("Mon 12 Oct  9:41").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Theme.panelTop.opacity(0.9))
            .overlay(alignment: .bottom) { Divider().overlay(Theme.divider) }

            LivesHereHint()
                .background(.panelFill, in: RoundedRectangle(cornerRadius: Theme.Radius.toast))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.toast).strokeBorder(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
                .padding(.top, 12)
                .padding(.trailing, 46)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mediaFrame()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: Theme.Motion.keepGlowFade).repeatForever()) { glow = true }
        }
    }
}
