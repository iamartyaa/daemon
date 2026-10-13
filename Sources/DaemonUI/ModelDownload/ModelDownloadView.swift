import DaemonCore
import SwiftUI

/// First-launch screen while the model downloads. State in, actions out; the app drives `ModelDownloader`.
public struct ModelDownloadView: View {
    public enum Phase: Equatable {
        case downloading
        case paused
        case failed(problem: String, remedy: String)   // e.g. error.localizedDescription, error.recoverySuggestion
    }

    let progress: ModelDownloadProgress
    let phase: Phase
    let onPause: () -> Void
    let onResume: () -> Void   // also "Try again"

    public init(progress: ModelDownloadProgress, phase: Phase,
                onPause: @escaping () -> Void, onResume: @escaping () -> Void) {
        self.progress = progress; self.phase = phase; self.onPause = onPause; self.onResume = onResume
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Mark(size: 22, color: Theme.accent)
            Text("Getting Daemon\nready")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 28)
            Text("A one-time \(Self.bytes(progress.bytesTotal)) download. Then everything stays on this Mac.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 14)

            ProgressBar(fraction: progress.fraction, dimmed: phase != .downloading)
                .padding(.top, 36)
            Text(Self.caption(progress, phase))
                .font(Theme.Font.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)

            if case .failed(let problem, let remedy) = phase {
                VStack(alignment: .leading, spacing: 4) {
                    Text(problem).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                    Text(remedy).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 20)
            }

            Spacer(minLength: 24)
            switch phase {
            case .downloading: QuietButton(title: "Pause", action: onPause)
            case .paused: AccentButton(title: "Resume", action: onResume)
            case .failed: AccentButton(title: "Try again", action: onResume)
            }
        }
        .padding(.horizontal, 72)
        .padding(.vertical, 56)
        .frame(width: 560, height: 480, alignment: .topLeading)
        .background(Theme.window)
    }

    /// Whole megabytes ("865 MB"), so the caption doesn't jitter.
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useMB
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: count)
    }

    /// "312 MB of 865 MB · about 2 min left"
    static func caption(_ progress: ModelDownloadProgress, _ phase: Phase) -> String {
        let amount = "\(bytes(progress.bytesDone)) of \(bytes(progress.bytesTotal))"
        switch phase {
        case .paused: return amount + " · Paused"
        case .failed: return amount
        case .downloading:
            guard let seconds = progress.secondsRemaining else { return amount }
            return amount + " · " + timeLeft(seconds)
        }
    }

    static func timeLeft(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds < 60 { return "less than a minute left" }
        if minutes < 60 { return "about \(minutes) min left" }
        return "about \(minutes / 60) hr \(minutes % 60) min left"
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let dimmed: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                Capsule()
                    .fill(Theme.accent.opacity(dimmed ? 0.45 : 1))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.3), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

private struct QuietButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
    }
}
