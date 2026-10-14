import DaemonCore
import SwiftUI

/// License block for the Settings window. `onBuy` opens the store (the URL can depend on region).
public struct LicenseSection: View {
    @ObservedObject var manager: LicenseManager
    let onBuy: () -> Void
    @State private var key = ""
    @State private var error: String?

    public init(manager: LicenseManager, onBuy: @escaping () -> Void) {
        self.manager = manager; self.onBuy = onBuy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(status).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                Spacer()
                if case .licensed = manager.state {
                    Button("Remove License") { manager.deactivate() }.buttonStyle(LicenseLinkButtonStyle())
                }
            }

            if !isLicensed {
                Text(detail)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("", text: $key, prompt: Text("Paste your license key").foregroundStyle(Theme.textSecondary))
                        .textFieldStyle(.plain)
                        .labelsHidden()   // in a grouped Form an unlabeled field otherwise sits right-aligned
                        .font(Theme.Font.body.monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                        .onSubmit(activate)
                        .onChange(of: key) { error = nil }
                    Button("Activate", action: activate)
                        .buttonStyle(LicenseLinkButtonStyle())
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let error {
                    Text(error).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                }

                Button("Buy Daemon", action: onBuy).buttonStyle(LicensePrimaryButtonStyle()).padding(.top, 4)
            }
        }
    }

    private var isLicensed: Bool {
        if case .licensed = manager.state { return true }
        return false
    }

    private var status: String {
        switch manager.state {
        case .trial(let days): "Free trial · \(days) \(days == 1 ? "day" : "days") left"
        case .trialExpired: "Trial ended"
        case .licensed(let email): "Licensed to \(email)"
        }
    }

    private var detail: String {
        manager.state == .trialExpired
            ? "Recall still works. Buy Daemon to keep new things."
            : "One purchase covers every 1.x version."
    }

    private var dotColor: Color {
        manager.state == .trialExpired ? Theme.textSecondary : Theme.accent
    }

    private func activate() {
        do {
            try manager.activate(key)
            key = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
