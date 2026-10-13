import AppKit
import DaemonCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel's content: one card pinned top-trailing, under the menu bar.
struct ToastView: View {
    @ObservedObject var model: ToastModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            card
                .background(GeometryReader { geo in
                    let frame = geo.frame(in: .named(Self.space))
                    Color.clear
                        .onAppear { model.cardFrame = frame }
                        .onChange(of: frame) { model.cardFrame = $1 }
                })
                .id(model.serial)
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        }
        // Enter: drops 8 pt from the menu bar and settles. Exit: rises back the way it came, faster.
        .opacity(model.visible ? 1 : 0)
        .offset(y: model.visible || reduceMotion ? 0 : -8)
        .scaleEffect(model.visible || reduceMotion ? 1 : 0.98, anchor: .top)
        .padding(.top, 8).padding(.trailing, 10)
        .frame(width: Theme.Size.toast.width, height: Theme.Size.toast.height, alignment: .topTrailing)
        .coordinateSpace(name: Self.space)
    }

    static let space = "toast"

    @ViewBuilder private var card: some View {
        switch model.state {
        case .none: Color.clear.frame(width: 0, height: 0)
        case let .kept(item, url, count): KeptToast(model: model, item: item, thumbnail: url, count: count)
        case let .listening(start, ended): ListeningToast(levels: model.levels, start: start, ended: ended)
        case let .message(text): MessageToast(text: text)
        }
    }
}

extension View {
    /// Paper card: continuous corners, a hairline edge lit from the top, and a two-layer shadow
    /// (tight contact + soft ambient) tinted toward the surface instead of flat black.
    func toastCard() -> some View { modifier(ToastCard()) }
}

private struct ToastCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.toast, style: .continuous)
        let dark = scheme == .dark
        content
            .clipShape(shape)
            .background {
                shape.fill(.panelFill)
                    .shadow(color: Theme.toastShadow.opacity(dark ? 0.5 : 0.10), radius: 1, y: 0.5)
                    .shadow(color: Theme.toastShadow.opacity(dark ? 0.42 : 0.16), radius: 16, y: 8)
            }
            .overlay {
                shape.strokeBorder(contrast == .increased ? Theme.textTertiary : Theme.border, lineWidth: 1)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Theme.toastEdge.opacity(dark ? 0.55 : 0.9), .clear],
                                                  startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)),
                                   lineWidth: 1)
            }
    }
}

/// Secondary text that becomes primary under Increase Contrast.
private func secondaryText(_ contrast: ColorSchemeContrast) -> Color {
    contrast == .increased ? Theme.textPrimary : Theme.textSecondary
}

/// "Kept" set in the serif the menu and onboarding titles use, so every toast speaks with the same voice.
private func lead(_ word: String) -> Text {
    Text(word).font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(Theme.textPrimary)
}

// MARK: - Kept

struct KeptToast: View {
    @ObservedObject var model: ToastModel
    let item: Item
    let thumbnail: URL?
    var count = 1
    @FocusState private var noteFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let summary = KeptSummary(item: item, count: count)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ToastThumb(item: item, url: thumbnail, count: count)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        (lead("Kept")
                         + Text("  ·  ").foregroundStyle(Theme.textTertiary)
                         + Text(summary.header).foregroundStyle(secondaryText(contrast)))
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if !model.editingNote {
                            HStack(spacing: 5) {
                                Kbd(label: "⇥", font: Theme.Font.small)
                                Text("add a note").font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                            }
                            .fixedSize()
                            .transition(.opacity)
                        }
                    }
                    if let detail = summary.detail {
                        Text(detail)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(summary.detailIsFileName ? .middle : .tail)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.Size.toastCard.height)

            if model.editingNote {
                noteRow.transition(.opacity)
            }
        }
        .frame(width: Theme.Size.toastCard.width)
        .overlay(alignment: .bottom) {
            if !model.editingNote, let countdown = model.countdown {
                ProgressLine(countdown: countdown).transition(.opacity)
            }
        }
        .toastCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Kept, \(summary.header)\(summary.detail.map { ", \($0)" } ?? "")")
    }

    private var noteRow: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 10) {
                TextField("", text: $model.note, prompt: Text("Add a note").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($noteFocused)
                    .onSubmit {
                        let note = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !note.isEmpty { model.onNote(note) }
                        model.onNoteDone()
                    }
                    .onExitCommand { model.onNoteDone() }
                    .onAppear { noteFocused = true }
                Kbd(label: "↵", font: Theme.Font.small)
            }
            .padding(.leading, 12 + Theme.Size.toastThumb + 12)   // note text lines up with the line above it
            .padding(.trailing, 12)
            .frame(height: 40)
        }
    }
}

/// Time left, as a 2 pt line along the card's bottom edge. Freezes while the toast is held.
private struct ProgressLine: View {
    let countdown: Countdown
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TimelineView(.animation(paused: countdown.isPaused)) { context in
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.accent.opacity(contrast == .increased ? 1 : 0.55))
                    .frame(width: geo.size.width * countdown.progress(at: context.date))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// What was kept, at 40 pt: the real thumbnail when there is one, the Finder icon for files,
/// the opening words for text, a waveform for sound. Several items fan a second sheet behind.
struct ToastThumb: View {
    let item: Item
    let url: URL?
    var count = 1
    private let size = Theme.Size.toastThumb
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.toastThumb, style: .continuous) }

    var body: some View {
        ZStack {
            if count > 1 {
                back.rotationEffect(.degrees(-9), anchor: .bottom).offset(x: -2)
            }
            front
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var image: NSImage? { item.kind == .voice ? nil : ThumbnailCache.image(url) }
    private var usesFileIcon: Bool { image == nil && [.file, .pdf].contains(item.kind) }

    @ViewBuilder private var front: some View {
        if usesFileIcon {
            Image(nsImage: Self.fileIcon(item)).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            face
                .frame(width: size, height: size)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
        }
    }

    @ViewBuilder private var back: some View {
        if usesFileIcon {
            Image(nsImage: Self.fileIcon(item)).resizable().interpolation(.high).frame(width: size, height: size).opacity(0.7)
        } else {
            shape.fill(Theme.well).overlay(shape.strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder private var face: some View {
        if let image {
            if [.pdf, .file, .link].contains(item.kind) {
                // A page: keep its top (the title) rather than its middle.
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size, alignment: .top).background(Color.white)
            } else {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        } else {
            switch item.kind {
            case .text:
                ZStack(alignment: .topLeading) {
                    Theme.thumbLight
                    // The opening words as a page texture, not as something to read.
                    Text(String((item.text ?? "").prefix(220)))
                        .font(.system(size: 3.6))
                        .lineSpacing(1.1)
                        .foregroundStyle(Color(hex: 0x7A756D))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 5).padding(.top, 5)
                }
            case .voice, .audio:
                ZStack {
                    Theme.accent.opacity(0.12)
                    Waveform(levels: Array(Waveform.sample.prefix(8)), color: Theme.accent, barWidth: 1.6, spacing: 2, height: 18)
                }
            case .link:
                ZStack {
                    Theme.well
                    Image(systemName: "link").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
            default:
                Thumbnail(item: item, url: nil, radius: 0)
            }
        }
    }

    static func fileIcon(_ item: Item) -> NSImage {
        if let path = item.originalPath, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let ext = item.fileExtension ?? item.originalPath.map { ($0 as NSString).pathExtension }
        let type = ext.flatMap { UTType(filenameExtension: $0) } ?? (item.kind == .pdf ? .pdf : .data)
        return NSWorkspace.shared.icon(for: type)
    }
}

// MARK: - Voice

struct ListeningToast: View {
    let levels: [Float]
    let start: Date
    var ended: Date?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                HStack(spacing: 8) {
                    RecordingDot(active: ended == nil)
                    (lead(ended == nil ? "Listening" : "Keeping")
                     + Text(ended == nil ? "  ·  " : "").foregroundStyle(Theme.textTertiary)
                     + Text(ended == nil ? "release to keep" : "").foregroundStyle(secondaryText(contrast)))
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(timecode(ms: max(0, Int((ended ?? context.date).timeIntervalSince(start) * 1000))))
                        .font(Theme.Font.mono)
                        .foregroundStyle(secondaryText(contrast))
                }
            }
            LiveWaveform(levels: levels)
        }
        .padding(.horizontal, 14)
        .frame(width: Theme.Size.toastCard.width, height: Theme.Size.toastCard.height)
        .toastCard()
        .accessibilityElement(children: .combine)
    }
}

/// A small accent dot that breathes while recording; still under Reduce Motion and once the key is up.
private struct RecordingDot: View {
    let active: Bool
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(Theme.accent).frame(width: 7, height: 7)
            .opacity(active && dim && !reduceMotion ? 0.35 : 1)
            .animation(active && !reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: dim)
            .onAppear { dim = true }
    }
}

/// The live microphone level, newest at the right edge; older bars fade toward the left.
private struct LiveWaveform: View {
    let levels: [Float]
    private let bar: CGFloat = 2, gap: CGFloat = 3, height: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let fit = max(1, Int((geo.size.width + gap) / (bar + gap)))
            let shown = Array(repeating: ToastModel.floor, count: max(0, fit - levels.count)) + levels.suffix(fit)
            HStack(alignment: .center, spacing: gap) {
                ForEach(shown.indices, id: \.self) { i in
                    Capsule().fill(Theme.accent).frame(width: bar, height: max(2, height * CGFloat(shown[i])))
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .trailing)
            .mask(LinearGradient(colors: [.black.opacity(0.3), .black], startPoint: .leading,
                                 endPoint: UnitPoint(x: 0.4, y: 0.5)))
            .animation(.linear(duration: 0.05), value: levels)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Notices

/// "Copied, press ⌘V" or a calm error. Hugs short text; wraps longer text up to three lines.
struct MessageToast: View {
    let text: String
    private static let textWidth = Theme.Size.toastCard.width - 51   // card minus padding and mark

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Mark(size: 11, color: Theme.accent)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2.5)
                .lineLimit(3)
                .frame(width: fitsOneLine ? nil : Self.textWidth, alignment: .leading)
                .fixedSize(horizontal: fitsOneLine, vertical: true)
        }
        .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 12)
        .toastCard()
        .accessibilityElement(children: .combine)
    }

    private var fitsOneLine: Bool {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width <= Self.textWidth
    }
}
