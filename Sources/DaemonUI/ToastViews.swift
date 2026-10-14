import AppKit
import DaemonCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel's content: one card pinned top-trailing, under the menu bar.
struct ToastView: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            card
                .background(GeometryReader { geo in
                    let frame = geo.frame(in: .named(Self.space))
                    Color.clear
                        .onAppear { model.cardFrame = frame }
                        .onChange(of: frame) { model.cardFrame = $1 }
                })
        }
        // Entering and leaving are the presenter's: it moves this whole view as one layer.
        .padding(.top, 8).padding(.trailing, 10)
        .frame(width: Theme.Size.toast.width, height: Theme.Size.toast.height, alignment: .topTrailing)
        .coordinateSpace(name: Self.space)
    }

    static let space = "toast"

    @ViewBuilder private var card: some View {
        switch model.state {
        case .none: Color.clear.frame(width: 0, height: 0)
        case .keeping, .kept, .listening: KeepCard(model: model)
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

// MARK: - Keep card

/// Listening, Keeping and Kept share one card: moving between them changes only what's inside,
/// so a keep reads as one object settling (Keeping -> Kept) rather than toasts swapping.
/// Changes inside it are never SwiftUI animations: SwiftUI on macOS redraws the card's text and shapes on the CPU
/// every frame of one (about 10 ms a frame here, a whole core at 120 Hz). The presenter cross-fades the card's
/// layer instead, which the render server does on its own.
struct KeepCard: View {
    @ObservedObject var model: ToastModel
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if case let .listening(start, ended) = model.state {
                    ListeningRow(levels: model.levels, start: start, ended: ended, live: model)
                } else if let phase = KeepRow.Phase(model.state) {
                    KeepRow(model: model, phase: phase)
                }
            }
            .frame(width: Theme.Size.toastCard.width, height: Theme.Size.toastCard.height)

            if model.editingNote {
                noteRow.transition(.opacity)
            }
        }
        .frame(width: Theme.Size.toastCard.width)
        .overlay(alignment: .bottom) {
            // Only Kept counts down; its line starts once the morph has settled.
            if case .kept = model.state, !model.editingNote, let countdown = model.countdown {
                ProgressLine(countdown: countdown).transition(.opacity)
            }
        }
        .toastCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch model.state {
        case let .kept(item, _, count):
            let summary = KeptSummary(item: item, count: count)
            return "Kept, \(summary.header)\(summary.detail.map { ", \($0)" } ?? "")"
        case let .keeping(_, summary): return "Keeping, \(summary.header)"
        case .listening(_, nil): return "Listening, release to keep"
        default: return "Keeping voice note"
        }
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

/// Thumbnail, "Keeping"/"Kept · header", and the detail line. The same view for both phases, so the
/// lead word morphs, the header slides, the placeholder develops into the real thumbnail and the
/// detail line follows a beat later.
struct KeepRow: View {
    enum Phase {
        case keeping(KeepKindHint, KeepingSummary)
        case kept(Item, URL?, count: Int)

        init?(_ state: ToastModel.State) {
            switch state {
            case let .keeping(kind, summary): self = .keeping(kind, summary)
            case let .kept(item, url, count): self = .kept(item, url, count: count)
            default: return nil
            }
        }
    }

    @ObservedObject var model: ToastModel
    let phase: Phase
    @Environment(\.colorSchemeContrast) private var contrast

    private var isKept: Bool { if case .kept = phase { true } else { false } }

    private var text: (header: String, detail: String?, middle: Bool) {
        switch phase {
        case let .keeping(_, summary): return (summary.header, summary.detail, false)
        case let .kept(item, _, count):
            let summary = KeptSummary(item: item, count: count)
            return (summary.header, summary.detail, summary.detailIsFileName)
        }
    }

    var body: some View {
        let text = text
        HStack(spacing: 12) {
            thumb
                .frame(width: Theme.Size.toastThumb, height: Theme.Size.toastThumb)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    title(text.header)
                    Spacer(minLength: 0)
                    if isKept && !model.editingNote {
                        HStack(spacing: 5) {
                            Kbd(label: "⇥", font: Theme.Font.small)
                            Text("add a note").font(Theme.Font.small).foregroundStyle(Theme.textTertiary)
                        }
                        .fixedSize()
                    }
                }
                if let detail = text.detail {
                    Text(detail)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(text.middle ? .middle : .tail)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// "Keeping · Notes" -> "Kept · Notes": only the lead word changes; the presenter cross-fades the card.
    /// For a link, the domain is what's being fetched, so the domain line carries the shimmer.
    private func title(_ header: String) -> some View {
        var shimmerHeader = false
        if case .keeping(.link, _) = phase { shimmerHeader = true }
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            lead(isKept ? "Kept" : "Keeping")
            if !header.isEmpty {
                Text("  ·  ").foregroundStyle(Theme.textTertiary)
                Text(header).foregroundStyle(secondaryText(contrast))
                    .keepingShimmer(shimmerHeader, tint: Theme.textPrimary)
            }
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
    }

    @ViewBuilder private var thumb: some View {
        ZStack {
            switch phase {
            case let .keeping(kind, _):
                HintThumb(kind: kind)
                    .keepingShimmer(kind != .link)
            case let .kept(item, url, count):
                ToastThumb(item: item, url: url, count: count)
            }
        }
    }
}

/// What's being kept before it exists: a quiet stand-in for its kind, shimmering until the real thumbnail arrives.
struct HintThumb: View {
    let kind: KeepKindHint
    private let size = Theme.Size.toastThumb
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.toastThumb, style: .continuous) }

    var body: some View {
        Group {
            switch kind {
            case .text: tile(Theme.thumbLight) { lines(widths: [0.82, 0.94, 0.7, 0.88, 0.5]) }
            case .image: tile(Theme.well) { glyph("photo") }
            case .voice:
                tile(Theme.accent.opacity(0.12)) {
                    Waveform(levels: Array(Waveform.sample.prefix(8)), color: Theme.accent, barWidth: 1.6, spacing: 2, height: 18)
                }
            case .link: tile(Theme.well) { glyph("link") }
            case .files:
                ZStack {
                    sheet(Theme.well).rotationEffect(.degrees(-9), anchor: .bottom).offset(x: -3)
                    sheet(Theme.thumbLight).overlay(alignment: .topLeading) {
                        lines(widths: [0.8, 0.6, 0.75], inset: 5)
                    }
                }
            case .unknown: tile(Theme.well) { Mark(size: 13, color: Theme.textTertiary) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func tile<Content: View>(_ fill: Color, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack { fill; content() }
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.textPrimary.opacity(0.1), lineWidth: 1))
    }

    private func sheet(_ fill: Color) -> some View {
        let page = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return page.fill(fill).overlay(page.strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1))
            .frame(width: 30, height: 37)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textSecondary)
    }

    /// A page of text as texture, the way the Kept text thumbnail reads.
    private func lines(widths: [CGFloat], inset: CGFloat = 6) -> some View {
        VStack(alignment: .leading, spacing: 3.6) {
            ForEach(widths.indices, id: \.self) { i in
                Capsule().fill(Color(hex: 0x7A756D).opacity(0.55)).frame(width: (size - 2 * inset) * widths[i], height: 2.2)
            }
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var image: NSImage? {
        guard item.kind != .voice else { return nil }
        return url.flatMap { ToastImages.cache.object(forKey: $0 as NSURL) } ?? ThumbnailCache.image(url)
    }
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

/// Kept thumbnails, decoded off the main thread before Kept shows them.
enum ToastImages {
    nonisolated(unsafe) static let cache = NSCache<NSURL, NSImage>()   // NSCache is thread-safe

    static func load(_ url: URL) async {
        guard cache.object(forKey: url as NSURL) == nil else { return }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            // Drawn into a bitmap here, so Core Animation gets pixels and never decodes the JPEG on the main thread.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let jpeg = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: jpeg.width, height: jpeg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            context.draw(jpeg, in: CGRect(x: 0, y: 0, width: jpeg.width, height: jpeg.height))
            guard let pixels = context.makeImage() else { return nil }
            return NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
    }
}

// MARK: - Voice

/// "Listening · release to keep" over the live level. When the key comes up it reads "Keeping":
/// the waveform freezes where it was and light sweeps across its bars until Kept takes its place.
struct ListeningRow: View {
    let levels: [Float]
    let start: Date
    var ended: Date?
    /// While recording, the presenter's model feeds the level straight to a layer (see `ToastModel.levels`).
    var live: ToastModel?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.toastMotionPhase) private var fixedPhase

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
            if let live, ended == nil, fixedPhase == nil {
                LevelMeter(model: live).frame(height: LiveWaveform.height)
            } else {
                LiveWaveform(levels: levels).keepingShimmer(ended != nil, tint: Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Theme.Size.toastCard.width, height: Theme.Size.toastCard.height)
    }
}

/// The voice toast on its own card (onboarding shows it outside the presenter).
struct ListeningToast: View {
    let levels: [Float]
    let start: Date

    var body: some View {
        ListeningRow(levels: levels, start: start).toastCard().accessibilityElement(children: .combine)
    }
}

/// A small accent dot that breathes while recording; still under Reduce Motion and once the key is up.
private struct RecordingDot: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.toastMotionPhase) private var fixedPhase

    var body: some View {
        Group {
            if active && !reduceMotion && fixedPhase == nil {
                // An overlay on a plain view, so the layer view never lends the row a text baseline.
                Color.clear.overlay { PulsingDot(color: NSColor(Theme.accent)) }
            } else {
                Circle().fill(Theme.accent)
            }
        }
        .frame(width: 7, height: 7)
    }
}

/// The live microphone level, newest at the right edge; older bars fade toward the left.
/// Drawn once per state with SwiftUI (snapshots, onboarding, the frozen waveform that shimmers as Keeping);
/// while recording, `LevelMeter` draws the same bars in a layer.
struct LiveWaveform: View {
    let levels: [Float]
    static let bar: CGFloat = 2, gap: CGFloat = 3, height: CGFloat = 18
    private var bar: CGFloat { Self.bar }
    private var gap: CGFloat { Self.gap }
    private var height: CGFloat { Self.height }

    var body: some View {
        Canvas { context, size in
            for rect in Self.bars(levels, in: size) {
                context.opacity = Self.fade(rect.minX, width: size.width)
                context.fill(Capsule().path(in: rect), with: .color(Theme.accent))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// The newest levels that fit, right-aligned, each a bar centered on the middle line.
    static func bars(_ levels: [Float], in size: CGSize) -> [CGRect] {
        let fit = max(1, Int((size.width + gap) / (bar + gap)))
        let shown = Array(repeating: ToastModel.floor, count: max(0, fit - levels.count)) + levels.suffix(fit)
        let start = size.width - CGFloat(fit) * bar - CGFloat(fit - 1) * gap
        return shown.enumerated().map { i, level in
            let h = max(2, height * CGFloat(level))
            return CGRect(x: start + CGFloat(i) * (bar + gap), y: (size.height - h) / 2, width: bar, height: h)
        }
    }

    /// Older bars fade toward the left: 30% at the edge, full from 40% of the way across.
    static func fade(_ x: CGFloat, width: CGFloat) -> Double { 0.3 + 0.7 * min(1, max(0, x / (width * 0.4))) }
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
