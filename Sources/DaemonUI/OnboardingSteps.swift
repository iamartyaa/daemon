import SwiftUI

// MARK: - Layout and entrance

/// Text on the left, picture on the right, both centred in the space between the dots and the footer.
struct StepLayout<Text_: View, Media: View>: View {
    @ViewBuilder let text: Text_
    @ViewBuilder let media: Media

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) { text }
                .frame(width: Theme.Onboarding.column, alignment: .leading)
            Spacer(minLength: 0)
            media
                .frame(width: Theme.Onboarding.media.width, height: Theme.Onboarding.media.height)
                .stagger(3)
        }
        .padding(.horizontal, Theme.Onboarding.inset)
        .frame(maxHeight: .infinity)
    }
}

/// Content arrives in order (headline, body, media, button), ~60 ms apart.
private struct Stagger: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                withAnimation(Theme.Onboarding.enter.delay(Double(index) * Theme.Onboarding.stagger)) { shown = true }
            }
    }
}

extension View {
    func stagger(_ index: Int) -> some View { modifier(Stagger(index: index)) }
}

private func headline(_ text: String) -> some View {
    Text(text)
        .font(Theme.Font.headline)
        .foregroundStyle(Theme.textPrimary)
        .lineSpacing(-2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 14)
        .stagger(0)
}

private func lead(_ text: String) -> some View {
    Text(text)
        .font(Theme.Onboarding.lead)
        .foregroundStyle(Theme.textSecondary)
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
}

/// Icon tile and one line, as in the Keep and Recall lists.
struct TipRow: View {
    let icon: String
    let title: String
    var selected = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Theme.kbd, in: RoundedRectangle(cornerRadius: Theme.Radius.thumb))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.thumb).strokeBorder(Theme.kbdBorder, lineWidth: 1))
            Text(title)
                .font(Theme.Onboarding.rowTitle)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .contentShape(Rectangle())
    }
}

// MARK: - 1 Welcome

struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0)],
                                         center: .center, startRadius: 16, endRadius: 52))
                    .frame(width: 104, height: 104)
                    .scaleEffect(breathe ? 1 : 0.7)
                    .opacity(breathe ? 1 : 0.4)
                Mark(size: 40, color: Theme.accent)
            }
            .frame(height: 96)
            .padding(.bottom, 22)
            .stagger(0)
            .onAppear {
                guard !reduceMotion else { breathe = true; return }
                withAnimation(.easeInOut(duration: Theme.Onboarding.breathe).repeatForever()) { breathe = true }
            }

            Text("Your other self")
                .stagger(1)
            Text("remembers.")
                .stagger(2)
                .padding(.bottom, 16)
            Text("Keep anything with one key. Recall it by meaning with another. Nothing leaves your Mac.")
                .font(Theme.Onboarding.lead)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .frame(width: 340)
                .fixedSize(horizontal: false, vertical: true)
                .stagger(3)
            AccentButton(title: "Get started", action: model.advance)
                .padding(.top, 30)
                .stagger(4)
        }
        .font(Theme.Onboarding.display)
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
    }
}

// MARK: - 2 Keep

struct KeepStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var clip = 0

    static let clips = [("keep-text", "text.cursor", "Select text, press ⌃⌥S"),
                        ("keep-voice", "waveform", "Hold ⌃⌥S to speak a note"),
                        ("keep-region", "viewfinder", "Nothing selected? Drag to capture")]

    var body: some View {
        StepLayout {
            headline("Keep anything\nwith ⌃⌥S")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.clips.indices, id: \.self) { i in
                    Button { withAnimation(Theme.Onboarding.calm) { clip = i } } label: {
                        TipRow(icon: Self.clips[i].1, title: Self.clips[i].2, selected: clip == i)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, -8)
            .stagger(1)
            Text("Finder files and browser pages are kept the same way.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .stagger(2)
            AccentButton(title: "Continue", action: model.advance).padding(.top, 26).stagger(4)
        } media: {
            ExplainerVideo(name: Self.clips[clip].0) {
                withAnimation(Theme.Onboarding.calm) { clip = (clip + 1) % Self.clips.count }
            }
        }
    }
}

// MARK: - 3 Recall

struct RecallStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepLayout {
            headline("Recall it\nby meaning")
            lead("Press ⌃⌥Space from anywhere.").padding(.bottom, 14).stagger(1)
            VStack(alignment: .leading, spacing: 2) {
                TipRow(icon: "text.quote", title: "Describe what you remember")
                TipRow(icon: "return", title: "↵ pastes it where you were")
            }
            .padding(.leading, -8)
            .stagger(2)
            AccentButton(title: "Continue", action: model.advance).padding(.top, 26).stagger(4)
        } media: {
            ExplainerVideo(name: "recall")
        }
    }
}

// MARK: - 4 Accessibility

struct AccessibilityStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepLayout {
            headline("Let Daemon read\nwhat you select")
            lead("Accessibility lets Daemon see the text you have selected when you press ⌃⌥S, and paste into the same app when you press ↵.")
                .stagger(1)
            AccentButton(title: "Open System Settings", action: model.openAccessibilitySettings)
                .padding(.top, 24)
                .stagger(4)
            Button("Why this is safe") { withAnimation(Theme.Onboarding.calm) { model.showWhySafe.toggle() } }
                .buttonStyle(QuietButtonStyle(underline: true))
                .padding(.top, 12)
                .stagger(4)
            if model.showWhySafe {
                Text("Daemon reads the selection only when you press ⌃⌥S, and never logs keystrokes.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        } media: {
            PrivacyIllustration(daemonOn: model.trusted)
        }
    }
}

// MARK: - 5 Try it

struct PracticeStep: View {
    @ObservedObject var model: OnboardingModel
    static let sentence = "Default the pricing page to yearly plans, and show monthly in small type."

    var body: some View {
        StepLayout {
            headline("Try it once")
            if !model.trusted {
                lead("Without Accessibility, Daemon keeps a picture of what you drag over.").stagger(1)
            }
            VStack(alignment: .leading, spacing: 10) {
                checkRow(1, model.trusted ? "Select the sentence, press ⌃⌥S" : "Press ⌃⌥S, drag over anything", done: model.kept)
                checkRow(2, "Press ⌃⌥Space to Recall it", done: false)
            }
            .padding(.top, model.trusted ? 6 : 20)
            .stagger(2)
        } media: {
            PracticeCard(trusted: model.trusted, kept: model.kept, sentence: Self.sentence)
        }
    }

    private func checkRow(_ number: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(done ? Theme.accent : Theme.kbdBorder, lineWidth: 1)
                Circle().fill(Theme.accent).opacity(done ? 1 : 0)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onAccent)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(number)").font(Theme.Font.small).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(title).font(Theme.Onboarding.rowTitle)
                .foregroundStyle(done ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(done, color: Theme.textTertiary)
        }
        .animation(Theme.Onboarding.step, value: done)
    }
}

/// The practice sentence (real selectable text, so ⌃⌥S reads it like any app's selection) and what to do next.
/// Without Accessibility there is no selection to read, so it explains the drag instead.
struct PracticeCard: View {
    let trusted: Bool
    let kept: Bool
    let sentence: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(trusted ? "SELECT THIS SENTENCE AND PRESS ⌃⌥S" : "PRESS ⌃⌥S WITH NOTHING SELECTED")
                .font(Theme.Font.label).tracking(0.8).foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 12)
            Group {
                if trusted {
                    SelectableText(text: sentence, font: Theme.Onboarding.practiceNS)
                } else {
                    Text("Then drag over anything on your screen: a chart, a photo, part of a page.")
                        .font(Theme.Onboarding.practice).foregroundStyle(Theme.textPrimary).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
            .background(Theme.panelTop, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(kept ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1))
            ZStack(alignment: .leading) {
                if kept { keptStatus }
            }
            .frame(height: 24)
            .padding(.top, 16)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mediaFrame()
        .animation(Theme.Onboarding.step, value: kept)
    }

    private var keptStatus: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
            (Text("Kept. ").foregroundStyle(Theme.textPrimary).fontWeight(.semibold)
                + Text(trusted ? "Now press ⌃⌥Space and type \u{201C}yearly\u{201D}." : "Now press ⌃⌥Space to see it.")
                    .foregroundStyle(Theme.textSecondary))
                .font(Theme.Font.body)
        }
        .transition(.opacity.combined(with: .offset(y: 6)))
    }
}

// MARK: - 6 Done

struct DoneStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        StepLayout {
            headline("Daemon lives\nin your menu bar")
            lead("Click the mark at the top right for Recall, Recent and Settings.")
                .stagger(1)
            AccentButton(title: "Start using Daemon", action: model.advance).padding(.top, 26).stagger(4)
        } media: {
            MenuBarIllustration()
        }
    }
}
