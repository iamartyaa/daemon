import AppKit
import DaemonCore
import SwiftUI

/// The Daemon mark: a dot inside a ring.
struct Mark: View {
    var size: CGFloat = 18
    var color: Color = Theme.textPrimary
    var halo = false

    var body: some View {
        ZStack {
            if halo { Circle().fill(color.opacity(0.1)).shadow(color: color.opacity(0.35), radius: size / 5) }
            Circle().strokeBorder(color, lineWidth: max(1.3, size / 12))
            Circle().fill(color).frame(width: size * 0.3, height: size * 0.3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A key cap: "↵", "⌘C", "Space", "Esc".
struct Kbd: View {
    let label: String
    var font: Font = Theme.Font.caption

    var body: some View {
        Text(label)
            .font(font)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 18)
            .background(Theme.kbd, in: RoundedRectangle(cornerRadius: Theme.Radius.kbd))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.kbd).strokeBorder(Theme.kbdBorder, lineWidth: 1))
    }
}

/// Key cap followed by what it does, as in the panel footer.
struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Kbd(label: key)
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Static waveform bars; `levels` are 0...1.
struct Waveform: View {
    var levels: [Float]
    var color: Color = Theme.textSecondary
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 3
    var height: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: barWidth, height: max(3, height * CGFloat(levels[i])))
            }
        }
        .frame(height: height)
    }

    static let sample: [Float] = [0.3, 0.55, 0.4, 0.8, 0.5, 0.95, 0.6, 0.35, 0.7, 0.45, 0.9, 0.55, 0.3, 0.75,
                                  0.5, 1.0, 0.6, 0.4, 0.85, 0.5, 0.35, 0.65]
}

/// Decoded thumbnails, at the size they're drawn. `NSImage(contentsOf:)` decodes lazily while drawing, on the main
/// thread; here ImageIO decodes once, off the main thread, straight to the pixel size on screen (WWDC18 "Image and
/// Graphics Best Practices"), and the cache holds the ready bitmap.
@MainActor
enum ThumbnailCache {
    nonisolated static let rowPixels = 120      // 52 × 34 pt result rows at 2×
    nonisolated static let largePixels = 440    // recent cards, the preview pane, toasts (stored thumbnails are ≤ 400 px)
    private static let rows = makeCache(megabytes: 8)
    private static let large = makeCache(megabytes: 40)
    private static var loading: [URL: Task<NSImage?, Never>] = [:]

    private static func makeCache(megabytes: Int) -> NSCache<NSURL, NSImage> {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = megabytes << 20
        return cache
    }

    private static func cache(_ maxPixels: Int) -> NSCache<NSURL, NSImage> { maxPixels <= rowPixels ? rows : large }

    /// The size bucket for a view of this size.
    static func pixels(for size: CGSize, scale: CGFloat) -> Int {
        max(size.width, size.height) * scale <= CGFloat(rowPixels) ? rowPixels : largePixels
    }

    /// Already decoded, or nil; never touches the disk.
    static func cached(_ url: URL, maxPixels: Int) -> NSImage? { cache(maxPixels).object(forKey: url as NSURL) }

    /// Decoded now if needed (toasts show one at a time).
    static func image(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let hit = cached(url, maxPixels: largePixels) { return hit }
        return decode(url, maxPixels: largePixels).map { store($0, url, largePixels) }
    }

    /// Decodes off the main thread; concurrent requests for the same image share one decode.
    static func load(_ url: URL, maxPixels: Int) async -> NSImage? {
        if let hit = cached(url, maxPixels: maxPixels) { return hit }
        let key = maxPixels <= rowPixels ? url.appendingPathExtension("row") : url
        if let running = loading[key] { return await running.value }
        let task = Task { () -> NSImage? in
            let cgImage = await Task.detached(priority: .userInitiated) { decode(url, maxPixels: maxPixels) }.value
            loading[key] = nil
            return cgImage.map { store($0, url, maxPixels) }
        }
        loading[key] = task
        return await task.value
    }

    static func prefetch<S: Sequence>(_ urls: S, maxPixels: Int) where S.Element == URL {
        for url in urls where cached(url, maxPixels: maxPixels) == nil {
            Task { _ = await load(url, maxPixels: maxPixels) }
        }
    }

    private static func store(_ cgImage: CGImage, _ url: URL, _ maxPixels: Int) -> NSImage {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache(maxPixels).setObject(image, forKey: url as NSURL, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    nonisolated static func decode(_ url: URL, maxPixels: Int) -> CGImage? {
        Perf.measure("thumbnail decode") {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,      // decode here, not later during drawing
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        }
    }
}

/// Real thumbnail when there is one, otherwise a quiet drawing of the item's kind. Decoded thumbnails draw at once;
/// others are decoded in the background and replace the drawing when ready.
struct Thumbnail: View {
    let item: Item
    let url: URL?
    var radius: CGFloat = Theme.Radius.thumb
    @Environment(\.displayScale) private var scale
    @State private var loaded: (url: URL, image: NSImage)?

    var body: some View {
        GeometryReader { geo in
            let pixels = ThumbnailCache.pixels(for: geo.size, scale: scale)
            Group {
                if let image = image(pixels) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    KindDrawing(kind: item.kind, size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border, lineWidth: 1))
            .task(id: url) {
                guard let url, ThumbnailCache.cached(url, maxPixels: pixels) == nil,
                      let image = await ThumbnailCache.load(url, maxPixels: pixels) else { return }
                loaded = (url, image)
            }
        }
    }

    private func image(_ pixels: Int) -> NSImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return ThumbnailCache.cached(url, maxPixels: pixels)
    }
}

/// A quiet drawing of an item's kind, used when there is no thumbnail.
/// Tuned at row size (52 × 34); larger sizes grow the strokes up to 2× and the line lengths with the width.
private struct KindDrawing: View {
    let kind: ItemKind
    let size: CGSize
    private var s: CGFloat { min(2, size.width / 52) }
    private var w: CGFloat { size.width }

    private func line(_ fraction: CGFloat, _ color: Color = Color(hex: 0xB9B6B0), height: CGFloat = 1.2) -> some View {
        Capsule().fill(color).frame(width: w * fraction, height: height * s)
    }

    var body: some View {
        switch kind {
        case .voice, .audio:
            ZStack {
                Theme.well
                Waveform(levels: Waveform.sample, color: Theme.textSecondary, barWidth: max(1, s), spacing: 2 * s, height: 16 * s)
            }
        case .video:
            ZStack(alignment: .bottomLeading) {
                Theme.thumbDark
                Image(systemName: "play.fill").font(.system(size: 9 * s)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Capsule().fill(Theme.accent).frame(width: w * 0.7, height: s).padding(4 * s)
            }
        case .image, .screenshot:
            ZStack(alignment: .topLeading) {
                Theme.thumbDark
                VStack(alignment: .leading, spacing: 4 * s) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14)).frame(width: 28 * s, height: 6 * s)
                        Capsule().fill(Theme.accent).frame(width: 13 * s, height: 6 * s)
                    }
                    .padding(.bottom, s)
                    line(0.6, Theme.thumbLine)
                    line(0.43, Theme.thumbLine)
                    line(0.52, Theme.thumbLine)
                }
                .padding(.leading, 7 * s).padding(.top, 7 * s)
            }
        case .text:
            ZStack(alignment: .topLeading) {
                Theme.thumbLight
                VStack(alignment: .leading, spacing: 4 * s) {
                    HStack(spacing: 4 * s) {
                        Circle().fill(Color(hex: 0xCFC8BE)).frame(width: 7 * s, height: 7 * s)
                        line(0.35, Color(hex: 0x8F8A82))
                    }
                    line(0.73)
                    line(0.6)
                    Spacer(minLength: 0)
                    Capsule().fill(Color(hex: 0xE6E0D6)).frame(width: w * 0.8, height: 7 * s)
                        .overlay(alignment: .leading) { line(0.4, Color(hex: 0x8F8A82)).padding(.leading, 4 * s) }
                }
                .padding(7 * s)
            }
        case .pdf, .file:
            ZStack(alignment: .topLeading) {
                Color.white
                VStack(alignment: .leading, spacing: 3.5 * s) {
                    line(0.36, Color(hex: 0x4A4D55), height: 2).padding(.bottom, s)
                    line(0.8)
                    line(0.8)
                    line(0.8)
                    line(0.5)
                }
                .padding(.leading, 9 * s).padding(.top, 8 * s)
            }
        case .link:
            ZStack(alignment: .topLeading) {
                Theme.thumbLight
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 2 * s) {
                        ForEach(0..<2, id: \.self) { _ in Circle().fill(Color(hex: 0xC9C4BC)).frame(width: 2.5 * s, height: 2.5 * s) }
                        Capsule().fill(Color.white.opacity(0.9)).frame(height: 3 * s).padding(.leading, 2 * s)
                    }
                    .padding(.horizontal, 3 * s)
                    .frame(height: 7 * s)
                    .background(Color(hex: 0xE6E0D6))
                    VStack(alignment: .leading, spacing: 3.5 * s) {
                        line(0.5, Color(hex: 0x6E6A64), height: 1.6).padding(.bottom, s)
                        line(0.75)
                        line(0.62)
                        line(0.66)
                    }
                    .padding(.leading, 7 * s).padding(.top, 5 * s)
                }
            }
        }
    }
}
