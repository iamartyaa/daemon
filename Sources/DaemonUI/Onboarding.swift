import AppKit
import DaemonCore
import SwiftUI

// Onboarding-only tokens. ponytail: kept next to their only user; move into Theme.swift when another view needs them.
extension Theme {
    enum Onboarding {
        static let window = CGSize(width: 860, height: 520)
        static let media = CGSize(width: 448, height: 288)       // 560 × 360 explainer videos at 0.8
        static let column: CGFloat = 300
        static let inset: CGFloat = 44

        static let display = SwiftUI.Font.system(size: 40, design: .serif)  // welcome headline
        static let lead = SwiftUI.Font.system(size: 14)
        static let rowTitle = SwiftUI.Font.system(size: 13, weight: .medium)
        static let button = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let practice = SwiftUI.Font.system(size: 17, design: .serif)
        static let practiceNS = NSFont(descriptor: NSFont.systemFont(ofSize: 17).fontDescriptor.withDesign(.serif)!,
                                       size: 17)!

        static let step = Animation.spring(duration: 0.45, bounce: 0)
        static let calm = Animation.easeInOut(duration: 0.25)       // Reduce Motion stand-in for springs and slides
        static let enter = Animation.easeOut(duration: 0.4)
        static let stagger = 0.06
        static let stepOffset: CGFloat = 36
        static let windowFade = 0.3
        static let breathe = 2.8
        static let trustedHold = 0.9      // the switch turns on, then the next step
        static let clipDwell = 5.0        // how long a placeholder stands in for one explainer loop
    }
}

/// First run: welcome → Keep → Recall → Accessibility (advances on its own once trusted) → try it → done.
/// `onFinish` runs after the last step; the app then shows `MenuBarController.showLivesHereHint()`.
/// Call `didKeep()` and `didOpenRecall()` from the app so the practice step can react.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private var window: NSWindow?
    private var keyMonitor: Any?

    public init(isAccessibilityTrusted: @escaping () -> Bool, openAccessibilitySettings: @escaping () -> Void,
                onFinish: @escaping () -> Void) {
        model = OnboardingModel(isTrusted: isAccessibilityTrusted, openAccessibilitySettings: openAccessibilitySettings)
        super.init()
        model.finish = { [weak self] in
            self?.close()
            onFinish()
        }
        model.onTrusted = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Something was kept (any way). Moves the practice step on.
    public func didKeep() { model.didKeep() }
    /// The Recall panel opened. Finishes the practice step once something was kept.
    public func didOpenRecall() { model.didOpenRecall() }

    public func show() {
        let firstShow = window == nil
        if firstShow {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.Onboarding.window),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = Theme.windowNS
            window.contentView = NSHostingView(rootView: OnboardingView(model: model))
            window.delegate = self
            window.center()
            window.alphaValue = 0
            self.window = window
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.handleArrow(event) else { return event }
                return nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if firstShow, let window {
            NSAnimationContext.runAnimationGroup { $0.duration = Theme.Onboarding.windowFade; window.animator().alphaValue = 1 }
        }
    }

    public func close() {
        model.stop()
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        model.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// ← and → page through the explainer steps; text views keep their arrows.
    private func handleArrow(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !(window?.firstResponder is NSTextView) else { return false }
        switch event.keyCode {
        case 123: return model.arrowBack()
        case 124: return model.arrowForward()
        default: return false
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, keep, recall, accessibility, practice, done }

    @Published private(set) var step: Step
    @Published private(set) var forward = true          // direction of the last step change, for the slide
    @Published private(set) var trusted: Bool
    @Published private(set) var kept = false            // practice: something was kept
    @Published var showWhySafe = false

    let isTrusted: () -> Bool
    let openAccessibilitySettings: () -> Void
    var finish: () -> Void
    var onTrusted: () -> Void = {}
    private let pollInterval: Duration
    private let trustedHold: Duration
    private var poll: Task<Void, Never>?

    init(step: Step = .welcome, isTrusted: @escaping () -> Bool = { false },
         openAccessibilitySettings: @escaping () -> Void = {}, onFinish: @escaping () -> Void = {},
         pollInterval: Duration = .seconds(Theme.Motion.accessibilityPoll),
         trustedHold: Duration = .seconds(Theme.Onboarding.trustedHold)) {
        self.step = step
        self.isTrusted = isTrusted
        self.openAccessibilitySettings = openAccessibilitySettings
        finish = onFinish
        self.pollInterval = pollInterval
        self.trustedHold = trustedHold
        trusted = isTrusted()
        pollIfNeeded()
    }

    var canGoBack: Bool { step != .welcome }

    func advance() {
        guard step != .done else { return finish() }
        var next = Step(rawValue: step.rawValue + 1)!
        if next == .accessibility, isTrusted() { next = .practice }
        go(to: next)
    }

    func back() {
        guard var previous = Step(rawValue: step.rawValue - 1) else { return }
        if previous == .accessibility, isTrusted() { previous = .recall }
        go(to: previous)
    }

    /// → only pages through the explainers; the later steps want a deliberate click.
    func arrowForward() -> Bool {
        guard [.welcome, .keep, .recall].contains(step) else { return false }
        advance()
        return true
    }

    func arrowBack() -> Bool {
        guard canGoBack else { return false }
        back()
        return true
    }

    func didKeep() {
        guard step == .practice else { return }
        kept = true
    }

    func didOpenRecall() {
        guard step == .practice, kept else { return }
        advance()
    }

    func stop() { poll?.cancel() }

    private func go(to next: Step) {
        forward = next.rawValue > step.rawValue
        step = next
        showWhySafe = false
        trusted = isTrusted()
        if next == .practice { kept = false }
        pollIfNeeded()
    }

    private func pollIfNeeded() {
        poll?.cancel()
        guard step == .accessibility else { return }
        poll = Task { [weak self, pollInterval, trustedHold] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isTrusted() {
                    self.trusted = true                  // the switch in the illustration turns on
                    try? await Task.sleep(for: trustedHold)
                    guard !Task.isCancelled, self.step == .accessibility else { return }
                    self.advance()
                    self.onTrusted()
                    return
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            Theme.window
            ZStack {
                stepView
                    .id(model.step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 52).padding(.bottom, 56)
            PageDots(current: model.step).padding(.top, 17)
            footer
        }
        .animation(reduceMotion ? Theme.Onboarding.calm : Theme.Onboarding.step, value: model.step)
        .frame(width: Theme.Onboarding.window.width, height: Theme.Onboarding.window.height)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.98)
        .onAppear { withAnimation(Theme.Onboarding.step) { appeared = true } }
    }

    /// New content slides in from the side it comes from; old content only fades, so a change of direction never jumps.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset = model.forward ? Theme.Onboarding.stepOffset : -Theme.Onboarding.stepOffset
        return .asymmetric(insertion: .offset(x: offset).combined(with: .opacity), removal: .opacity)
    }

    @ViewBuilder private var stepView: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .keep: KeepStep(model: model)
        case .recall: RecallStep(model: model)
        case .accessibility: AccessibilityStep(model: model)
        case .practice: PracticeStep(model: model)
        case .done: DoneStep(model: model)
        }
    }

    private var footer: some View {
        HStack {
            if model.canGoBack {
                Button("← Back", action: model.back).buttonStyle(QuietButtonStyle())
            }
            Spacer()
            switch model.step {
            case .accessibility: Button("Not now", action: model.advance).buttonStyle(QuietButtonStyle())
            case .practice: Button("Skip", action: model.advance).buttonStyle(QuietButtonStyle())
            default: EmptyView()
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 20)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

/// Page dots: the current one stretches into a pill.
struct PageDots: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Theme.textPrimary : Theme.textTertiary.opacity(0.5))
                    .frame(width: step == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
    }
}

/// The primary action, ↵ triggers it.
struct AccentButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title).font(Theme.Onboarding.button)
                Text("↵").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 18)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.kbd))
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 32)
        }
        .buttonStyle(AccentButtonStyle())
        .keyboardShortcut(.defaultAction)
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.button))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button)
                    .fill(Color.white.opacity(configuration.isPressed ? 0 : hovering ? 0.08 : 0)))
                .brightness(configuration.isPressed ? -0.06 : 0)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: Theme.Motion.toastFade), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// Secondary text actions: Back, Skip, Why this is safe.
struct QuietButtonStyle: ButtonStyle {
    var underline = false

    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, underline: underline) }

    private struct Styled: View {
        let configuration: Configuration
        let underline: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.Font.body)
                .underline(underline)
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: Theme.Motion.toastFade), value: hovering)
        }
    }
}
