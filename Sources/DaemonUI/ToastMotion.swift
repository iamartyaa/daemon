import AppKit
import CoreImage
import QuartzCore
import SwiftUI

// Motion for the Keep toast: the shimmer while keeping, the countdown line and the flight into the menu bar mark.
// All three are Core Animation layers. The app commits each animation once and the render server draws every
// frame, so a keep costs the app nothing per frame (a SwiftUI TimelineView re-ran its body 120 times a second,
// about one core). Removing the view or ordering the panel out stops the work. Each also takes a fixed phase,
// drawn with plain SwiftUI, so snapshots can render any frame.

private struct ToastMotionPhaseKey: EnvironmentKey { static let defaultValue: Double? = nil }
private struct ToastReduceMotionKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Freezes toast motion at a phase in 0...1 and skips entrances. For snapshots; nil when live.
    var toastMotionPhase: Double? {
        get { self[ToastMotionPhaseKey.self] }
        set { self[ToastMotionPhaseKey.self] = newValue }
    }

    /// Shows the Reduce Motion version regardless of the system setting. For snapshots.
    var toastReduceMotion: Bool {
        get { self[ToastReduceMotionKey.self] }
        set { self[ToastReduceMotionKey.self] = newValue }
    }
}

// MARK: - Shimmer

extension View {
    /// While `active`, a soft band sweeps across this view's own shape (its bars, lines, letters), then rests.
    /// Without a tint the band is light passing over a tile. With a tint the view dims and the band
    /// relights it in `tint`, which reads on bars and type in both appearances.
    /// Reduce Motion: nothing travels, the view breathes in opacity instead.
    func keepingShimmer(_ active: Bool, tint: Color? = nil) -> some View {
        ShimmerView(content: self, active: active, tint: tint)
    }
}

/// The shimmer's shape in time and space, shared by the live layer and fixed-phase snapshots.
enum Shimmer {
    /// Band position 0...1 (off left to off right): eases across in the first 85% of a cycle, then rests off-edge.
    static func sweep(_ phase: Double) -> Double {
        let p = min(1, max(0, phase / sweepShare))
        return p * p * (3 - 2 * p)
    }

    static let sweepShare = 0.85
    static let dim = 0.42
    static let slant = 16.0       // degrees: a slanted gleam on tiles; upright on bars and type

    /// Reduce Motion: full at the start of a cycle, 55% halfway, back again. Calm, no travel.
    static func breath(_ phase: Double) -> Double { 0.775 + 0.225 * cos(phase * 2 * .pi) }

    static func bandWidth(_ viewWidth: CGFloat) -> CGFloat { min(120, max(26, viewWidth * 0.5)) }

    /// The band's center x at sweep position `t` in a view `viewWidth` wide.
    static func bandCenter(_ t: Double, viewWidth: CGFloat) -> CGFloat {
        let width = bandWidth(viewWidth)
        return -0.8 * width + (viewWidth + 1.6 * width) * t
    }

    /// Where in its cycle every shimmer is now, so several on screen sweep together.
    static func phase(at date: Date = Date()) -> Double {
        (date.timeIntervalSinceReferenceDate / Theme.Motion.shimmerCycle).truncatingRemainder(dividingBy: 1)
    }
}

struct ShimmerView<Content: View>: View {
    let content: Content
    let active: Bool
    var tint: Color?
    @Environment(\.toastMotionPhase) private var fixedPhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.toastReduceMotion) private var forcedReduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.font) private var font
    @Environment(\.lineLimit) private var lineLimit
    @State private var breathing = false

    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    private var color: Color { tint ?? Theme.shimmer }
    private var peak: Double { tint != nil ? 1 : scheme == .dark ? 0.45 : 0.85 }

    var body: some View {
        content
            .opacity(opacity)
            .animation(breathing ? .easeInOut(duration: Theme.Motion.shimmerCycle / 2).repeatForever() : .default,
                       value: breathing)
            .overlay {
                if active && !reduceMotion {
                    if let fixedPhase {
                        band(at: Shimmer.sweep(fixedPhase)).mask { content }
                    } else {
                        GeometryReader { geo in
                            ShimmerBand(color: NSColor(color), peak: peak, slanted: tint == nil) { scale in
                                mask(geo.size, scale: scale)
                            }
                        }
                    }
                }
            }
            .task(id: active && reduceMotion && fixedPhase == nil) { breathing = active && reduceMotion && fixedPhase == nil }
    }

    private var opacity: Double {
        guard active else { return 1 }
        if reduceMotion { return fixedPhase.map(Shimmer.breath) ?? (breathing ? Shimmer.breath(0.5) : 1) }
        return tint == nil ? 1 : Shimmer.dim
    }

    /// The view's own shape, for the band's mask. Rendered once per size; the content holds still while keeping.
    @MainActor private func mask(_ size: CGSize, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: content.font(font).lineLimit(lineLimit)
            .frame(width: size.width, height: size.height))
        renderer.scale = scale
        return renderer.cgImage
    }

    /// One frame of the band, for snapshots.
    private func band(at t: Double) -> some View {
        GeometryReader { geo in
            let width = Shimmer.bandWidth(geo.size.width)
            LinearGradient(stops: [.init(color: color.opacity(0), location: 0),
                                   .init(color: color.opacity(peak), location: 0.5),
                                   .init(color: color.opacity(0), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width, height: geo.size.height * 1.6)
                .rotationEffect(.degrees(tint == nil ? Shimmer.slant : 0))
                .position(x: Shimmer.bandCenter(t, viewWidth: geo.size.width), y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}

/// The live band: a gradient layer masked by the view's shape, swept by one repeating Core Animation.
struct ShimmerBand: NSViewRepresentable {
    let color: NSColor
    let peak: Double
    let slanted: Bool
    let mask: (CGFloat) -> CGImage?

    func makeNSView(context: Context) -> ShimmerBandView { ShimmerBandView() }

    func updateNSView(_ view: ShimmerBandView, context: Context) {
        view.renderMask = mask
        view.style = ShimmerBandView.Style(color: color, peak: peak, slanted: slanted)
    }
}

final class ShimmerBandView: NSView {
    struct Style: Equatable {
        var color: NSColor
        var peak: Double
        var slanted: Bool
    }

    var style: Style? { didSet { if style != oldValue { built = nil; build() } } }
    var renderMask: (CGFloat) -> CGImage? = { _ in nil }
    private let band = CAGradientLayer()
    private let maskLayer = CALayer()
    private var built: (size: CGSize, scale: CGFloat)?

    init() {
        super.init(frame: .zero)
        layer = CALayer()      // layer-hosting: these layers are ours, AppKit never redraws them
        wantsLayer = true
        layer?.mask = maskLayer
        layer?.addSublayer(band)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); build() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); build() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); built = nil; build() }

    /// Sets up the layers and the sweep once per size, scale, style and appearance.
    private func build() {
        guard let window, let style, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window.backingScaleFactor
        if let built, built.size == bounds.size, built.scale == scale { return }
        built = (bounds.size, scale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        maskLayer.contentsScale = scale
        maskLayer.contents = renderMask(scale)

        var cg = style.color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = style.color.cgColor }
        band.colors = [cg.copy(alpha: 0), cg.copy(alpha: cg.alpha * style.peak), cg.copy(alpha: 0)].compactMap { $0 }
        band.bounds = CGRect(x: 0, y: 0, width: Shimmer.bandWidth(bounds.width), height: bounds.height * 1.6)
        let clockwise = -Shimmer.slant * .pi / 180   // layer space is bottom-up
        band.setAffineTransform(CGAffineTransform(rotationAngle: style.slanted ? clockwise : 0))
        band.position = CGPoint(x: Shimmer.bandCenter(0, viewWidth: bounds.width), y: bounds.midY)

        let sweep = CAKeyframeAnimation(keyPath: "position.x")
        sweep.values = [Shimmer.bandCenter(0, viewWidth: bounds.width), Shimmer.bandCenter(1, viewWidth: bounds.width),
                        Shimmer.bandCenter(1, viewWidth: bounds.width)]
        sweep.keyTimes = [0, NSNumber(value: Shimmer.sweepShare), 1]
        // Bezier (1/3, 0), (2/3, 1) is exactly smoothstep, the curve `Shimmer.sweep` uses.
        sweep.timingFunctions = [CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1), CAMediaTimingFunction(name: .linear)]
        sweep.duration = Theme.Motion.shimmerCycle
        sweep.repeatCount = .infinity
        sweep.beginTime = band.convertTime(CACurrentMediaTime(), from: nil) - Shimmer.phase() * Theme.Motion.shimmerCycle
        sweep.isRemovedOnCompletion = false
        band.add(sweep, forKey: "sweep")
        CATransaction.commit()
    }
}

// MARK: - Live level

/// The voice toast's waveform while recording: the bars as one shape layer, updated as each level arrives and
/// eased between levels by the render server.
struct LevelMeter: NSViewRepresentable {
    let model: ToastModel

    func makeNSView(context: Context) -> LevelMeterView {
        let view = LevelMeterView()
        view.levels = model.levels
        model.onLevels = { [weak view] in view?.levels = $0 }
        return view
    }

    func updateNSView(_ view: LevelMeterView, context: Context) { view.color = NSColor(Theme.accent) }
}

final class LevelMeterView: NSView {
    var levels: [Float] = [] { didSet { draw(animated: true) } }
    var color: NSColor = .clear { didSet { if color != oldValue { draw(animated: false) } } }
    private let bars = CAShapeLayer()
    private let fade = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(bars)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 0.4, y: 0.5)
        fade.colors = [CGColor(gray: 0, alpha: 0.3), CGColor(gray: 0, alpha: 1)]
        bars.mask = fade
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); draw(animated: false) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); draw(animated: false) }

    private func draw(animated: Bool) {
        guard bounds.width > 0 else { return }
        let path = CGMutablePath()
        for rect in LiveWaveform.bars(levels, in: bounds.size) {
            path.addRoundedRect(in: rect, cornerWidth: rect.width / 2, cornerHeight: min(rect.width, rect.height) / 2)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, let from = bars.presentation()?.path {
            let ease = CABasicAnimation(keyPath: "path")
            ease.fromValue = from
            ease.duration = 0.05   // levels arrive every 50 ms
            bars.add(ease, forKey: "level")
        }
        bars.frame = bounds
        fade.frame = bounds
        bars.path = path
        effectiveAppearance.performAsCurrentDrawingAppearance { bars.fillColor = color.cgColor }
        CATransaction.commit()
    }
}

// MARK: - Recording dot

/// The voice toast's dot, breathing while it records: one repeating Core Animation.
struct PulsingDot: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView() }
    func updateNSView(_ view: PulsingDotView, context: Context) { view.color = color }
}

final class PulsingDotView: NSView {
    var color: NSColor = .clear { didSet { if color != oldValue { build() } } }
    private let dot = CALayer()

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(dot)
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.35
        breathe.duration = 0.9
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.isRemovedOnCompletion = false
        dot.add(breathe, forKey: "breathe")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); build() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); build() }

    private func build() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
        effectiveAppearance.performAsCurrentDrawingAppearance { dot.backgroundColor = color.cgColor }
        CATransaction.commit()
    }
}

// MARK: - Countdown line

/// Time left, as a 2 pt line along the card's bottom edge. Live, one Core Animation runs it to the end;
/// held (hover, a note), it freezes where it was. Snapshots pause the countdown, so they draw the SwiftUI line.
struct ProgressLine: View {
    let countdown: Countdown
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let color = Theme.accent.opacity(contrast == .increased ? 1 : 0.55)
        Group {
            if countdown.isPaused {
                GeometryReader { geo in
                    Rectangle().fill(color).frame(width: geo.size.width * countdown.progress(at: Date()))
                }
            } else {
                ProgressLayer(countdown: countdown, color: NSColor(color))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

private struct ProgressLayer: NSViewRepresentable {
    let countdown: Countdown
    let color: NSColor

    func makeNSView(context: Context) -> ProgressLayerView { ProgressLayerView() }

    func updateNSView(_ view: ProgressLayerView, context: Context) {
        view.color = color
        view.countdown = countdown
    }
}

final class ProgressLayerView: NSView {
    var countdown: Countdown? { didSet { if countdown != oldValue { built = nil; build() } } }
    var color: NSColor = .clear { didSet { if color != oldValue { built = nil; build() } } }
    private let line = CALayer()
    private var built: CGSize?

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(line)
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); build() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); build() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); built = nil; build() }

    private func build() {
        guard window != nil, let countdown, bounds.width > 0, built != bounds.size else { return }
        built = bounds.size
        let now = Date()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance { line.backgroundColor = color.cgColor }
        line.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        line.position = CGPoint(x: 0, y: bounds.midY)
        line.transform = CATransform3DMakeScale(1, 1, 1)
        let grow = CABasicAnimation(keyPath: "transform.scale.x")
        grow.fromValue = countdown.progress(at: now)
        grow.toValue = 1
        grow.duration = max(0.01, countdown.total - countdown.elapsed(at: now))
        // A countdown that starts after the morph holds at its first value until then.
        grow.beginTime = line.convertTime(CACurrentMediaTime(), from: nil) + max(0, countdown.remaining(at: now) - grow.duration)
        grow.fillMode = .backwards
        line.add(grow, forKey: "progress")
        CATransaction.commit()
    }
}

// MARK: - Flight

/// The kept thumbnail's flight to the menu bar mark as a pure function of progress 0...1 (top-left coordinates):
/// it lifts off the card (a touch larger, shadow growing), then glides along a gentle arc, shrinking to the
/// mark's size, and melts into it as the mark starts to glow.
struct FlightPath {
    let from: CGPoint
    let to: CGPoint
    /// Size at the mark relative to the start: 0.3 takes a 40 pt thumbnail to the mark's ~12 pt.
    var endScale = Self.endScale

    static let lift = 0.16        // share of the flight spent lifting off the card
    static let arrival = 0.84     // the mark starts glowing here, as the thumbnail sinks into it
    static let endScale = 0.3

    struct Frame: Equatable {
        var center: CGPoint
        var scale: Double
        var opacity: Double
        var shadow: Double        // 0...1, how lifted it looks
    }

    func frame(at progress: Double) -> Frame {
        let p = min(1, max(0, progress))
        let lifted = UnitCurve.easeOut.value(at: min(1, p / Self.lift))
        let travel = Self.glide.value(at: max(0, (p - Self.lift * 0.5) / (1 - Self.lift * 0.5)))
        let start = CGPoint(x: from.x, y: from.y - 4 * lifted)
        // A gentle arc: the control point sits off the midpoint, bowed upward by an eighth of the distance.
        let dx = to.x - start.x, dy = to.y - start.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        var normal = CGPoint(x: dy / length, y: -dx / length)
        if normal.y > 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
        let control = CGPoint(x: (start.x + to.x) / 2 + normal.x * length * 0.12,
                              y: (start.y + to.y) / 2 + normal.y * length * 0.12)
        let t = travel, u = 1 - travel
        let center = CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * to.x,
                             y: u * u * start.y + 2 * u * t * control.y + t * t * to.y)
        let fade = max(0, (p - 0.8) / 0.2)
        return Frame(center: center,
                     scale: (1 + 0.06 * lifted * (1 - travel)) * (1 + (endScale - 1) * travel),
                     opacity: 1 - fade * fade * (3 - 2 * fade),
                     shadow: lifted * (1 - travel))
    }

    /// Strong ease-in-out for on-screen movement.
    private static let glide = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.65, y: 0),
                                                endControlPoint: UnitPoint(x: 0.3, y: 1))

    /// The whole flight as Core Animation keyframes, sampled from `frame(at:)`, for a layer in a view
    /// `height` points tall (bottom-left origin). Linear between 64 samples is smooth at 120 Hz.
    func animation(height: CGFloat, duration: Double, samples: Int = 64) -> CAAnimationGroup {
        let frames = (0..<samples).map { frame(at: Double($0) / Double(samples - 1)) }
        func track(_ keyPath: String, _ value: (Frame) -> Any) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: keyPath)
            a.values = frames.map(value)
            a.calculationMode = .linear
            return a
        }
        let group = CAAnimationGroup()
        group.animations = [
            track("position") { NSValue(point: NSPoint(x: $0.center.x, y: height - $0.center.y)) },
            track("transform.scale") { $0.scale },
            track("opacity") { $0.opacity },
            track("shadowOpacity") { 0.3 * $0.shadow },
            track("shadowRadius") { 2 + 8 * $0.shadow },
            track("shadowOffset") { NSValue(size: NSSize(width: 0, height: -(1 + 5 * $0.shadow))) },
            track("filters.blur.inputRadius") { 1.5 * (1 - $0.opacity) },
        ]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        return group
    }
}

/// One frame of a flight, for snapshots (the live flight is `ToastFlight`'s layer).
struct FlightView<Thumb: View>: View {
    let thumb: Thumb
    let path: FlightPath
    var progress: Double

    var body: some View {
        let f = path.frame(at: progress)
        thumb
            .shadow(color: Theme.toastShadow.opacity(0.3 * f.shadow), radius: 2 + 8 * f.shadow, y: 1 + 5 * f.shadow)
            .scaleEffect(f.scale)
            .blur(radius: 1.5 * (1 - f.opacity))
            .opacity(f.opacity)
            .position(f.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A transparent, click-through window over the toast and the menu bar, shown only for the length of a flight.
/// The thumbnail is drawn once into a layer; Core Animation moves it.
@MainActor
final class ToastFlight {
    private var window: NSPanel?
    private var serial = 0

    /// Creates the window ahead of the first flight.
    func prewarm() { window = window ?? Self.makeWindow() }

    func fly<Thumb: View>(_ thumb: Thumb, from: NSRect, to: NSRect, appearance: NSAppearance) {
        let scale = Self.backingScale(for: from.union(to))
        let scheme: ColorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(content: thumb.environment(\.colorScheme, scheme))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return }
        fly(image: image, scale: scale, from: from, to: to, endScale: FlightPath.endScale, appearance: appearance)
    }

    /// Flies an already drawn image (the toast card itself) from `from` into `to`, shrinking to `endScale`.
    func fly(image: CGImage, scale: CGFloat, from: NSRect, to: NSRect, endScale: Double, appearance: NSAppearance) {
        let frame = from.union(to).insetBy(dx: -48, dy: -48)   // room for the lift shadow
        let local = { (r: NSRect) in CGPoint(x: r.midX - frame.minX, y: frame.maxY - r.midY) }
        let window = self.window ?? Self.makeWindow()
        self.window = window
        window.setFrame(frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.layer = CALayer()
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = scale
        layer.bounds = CGRect(origin: .zero, size: from.size)
        layer.position = CGPoint(x: from.midX - frame.minX, y: from.midY - frame.minY)
        appearance.performAsCurrentDrawingAppearance { layer.shadowColor = NSColor(Theme.toastShadow).cgColor }
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.name = "blur"
        blur?.setValue(0, forKey: kCIInputRadiusKey)
        layer.filters = blur.map { [$0] }
        let path = FlightPath(from: local(from), to: local(to), endScale: endScale)
        layer.opacity = 0   // where it ends, so nothing lingers once the animation is done
        layer.add(path.animation(height: frame.height, duration: Theme.Motion.flight), forKey: "flight")
        view.layer?.addSublayer(layer)
        window.contentView = view
        window.orderFrontRegardless()

        serial &+= 1
        let current = serial
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Motion.flight + 0.05))
            guard let self, self.serial == current else { return }
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    static func backingScale(for rect: NSRect) -> CGFloat {
        (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.backingScaleFactor ?? 2
    }

    private static func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar               // above the menu bar, like the toast
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true        // never takes a click or focus from the toast's note field
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}
