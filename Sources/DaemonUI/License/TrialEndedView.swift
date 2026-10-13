import SwiftUI

/// Content for the window shown once when the trial runs out. Keep pauses; everything else keeps working.
public struct TrialEndedView: View {
    let onBuy: () -> Void
    let onEnterKey: () -> Void

    public init(onBuy: @escaping () -> Void, onEnterKey: @escaping () -> Void) {
        self.onBuy = onBuy; self.onEnterKey = onEnterKey
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LicenseMark()
            Text("Your 14-day trial has ended.")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Everything you kept is still here and Recall still works. Buy Daemon to keep new things.")
                .font(Theme.Font.query)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                Button("Buy Daemon", action: onBuy).buttonStyle(LicensePrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Enter License Key", action: onEnterKey).buttonStyle(LicenseLinkButtonStyle())
            }
            .padding(.top, 8)
        }
        .padding(44)
        .frame(width: 460, alignment: .leading)
        .background(Theme.window)
    }
}

/// The ⦿ mark from onboarding.
struct LicenseMark: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

struct LicensePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.title)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .contentShape(Rectangle())
    }
}

struct LicenseLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textSecondary)
            .underline(color: Theme.divider)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}
