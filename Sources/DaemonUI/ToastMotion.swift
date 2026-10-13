import AppKit
import SwiftUI

// Motion for the Keep toast: the shimmer while keeping and the flight into the menu bar mark.
// Both are driven by TimelineView(.animation), which only ticks while the view is on screen and unpaused,
// and both take a fixed phase so snapshots can render any frame.

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
    func keepingShimmer(_ active: Bool, tint: Color? = nil) -> some View { modifier(Shimmer(active: active, tint: tint)) }
}

struct Shimmer: ViewModifier {
    let active: Bool
    var tint: Color?
    @Environment(\.toastMotionPhase) private var fixedPhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.toastReduceMotion) private var forcedReduceMotion
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let reduceMotion = systemReduceMotion || forcedReduceMotion
        return TimelineView(.animation(paused: !active || fixedPhase != nil)) { context in
            let phase = fixedPhase ?? (context.date.timeIntervalSinceReferenceDate / Theme.Motion.shimmerCycle)
                .truncatingRemainder(dividingBy: 1)
            content
                .opacity(active ? (reduceMotion ? Self.breath(phase) : tint == nil ? 1 : Self.dim) : 1)
                .overlay {
                    if active && !reduceMotion {
                        band(at: Self.sweep(phase)).mask { content }.allowsHitTesting(false)
                    }
                }
        }
    }

    private func band(at t: Double) -> some View {
        GeometryReader { geo in
            let width = min(120, max(26, geo.size.width * 0.5))
            let color = tint ?? Theme.shimmer
            let peak = tint != nil ? 1 : scheme == .dark ? 0.45 : 0.85
            LinearGradient(stops: [.init(color: color.opacity(0), location: 0),
                                   .init(color: color.opacity(peak), location: 0.5),
                                   .init(color: color.opacity(0), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width, height: geo.size.height * 1.6)
                .rotationEffect(.degrees(tint == nil ? 16 : 0))   // a slanted gleam on tiles; upright on bars and type
                .offset(x: -1.3 * width + (geo.size.width + 1.6 * width) * t, y: -geo.size.height * 0.3)
        }
    }

    /// Band position 0...1 (off left to off right): eases across in the first 85% of a cycle, then rests off-edge.
    static func sweep(_ phase: Double) -> Double {
        let p = min(1, max(0, phase / 0.85))
        return p * p * (3 - 2 * p)
    }

    static let dim = 0.42

    /// Reduce Motion: full at the start of a cycle, 55% halfway, back again. Calm, no travel.
    static func breath(_ phase: Double) -> Double { 0.775 + 0.225 * cos(phase * 2 * .pi) }
}

// MARK: - Flight

/// The kept thumbnail's flight to the menu bar mark as a pure function of progress 0...1 (top-left coordinates):
/// it lifts off the card (a touch larger, shadow growing), then glides along a gentle arc, shrinking to the
/// mark's size, and melts into it as the mark starts to glow.
struct FlightPath {
    let from: CGPoint
    let to: CGPoint

    static let lift = 0.16        // share of the flight spent lifting off the card
    static let arrival = 0.84     // the mark starts glowing here, as the thumbnail sinks into it
    static let endScale = 0.3     // 40 pt thumbnail -> about the mark's 12 pt

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
                     scale: (1 + 0.06 * lifted * (1 - travel)) * (1 + (Self.endScale - 1) * travel),
                     opacity: 1 - fade * fade * (3 - 2 * fade),
                     shadow: lifted * (1 - travel))
    }

    /// Strong ease-in-out for on-screen movement.
    private static let glide = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.65, y: 0),
                                                endControlPoint: UnitPoint(x: 0.3, y: 1))
}

/// Draws one flight. `progress` fixes the frame (snapshots); nil plays it from `start`.
struct FlightView<Thumb: View>: View {
    let thumb: Thumb
    let path: FlightPath
    var start = Date()
    var progress: Double?

    var body: some View {
        TimelineView(.animation(paused: progress != nil)) { context in
            let f = path.frame(at: progress ?? context.date.timeIntervalSince(start) / Theme.Motion.flight)
            thumb
                .shadow(color: Theme.toastShadow.opacity(0.3 * f.shadow), radius: 2 + 8 * f.shadow, y: 1 + 5 * f.shadow)
                .scaleEffect(f.scale)
                .blur(radius: 1.5 * (1 - f.opacity))
                .opacity(f.opacity)
                .position(f.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A transparent, click-through window over the toast and the menu bar, shown only for the length of a flight.
@MainActor
final class ToastFlight {
    private var window: NSPanel?
    private var serial = 0

    func fly<Thumb: View>(_ thumb: Thumb, from: NSRect, to: NSRect) {
        let frame = from.union(to).insetBy(dx: -48, dy: -48)   // room for the lift shadow
        let local = { (r: NSRect) in CGPoint(x: r.midX - frame.minX, y: frame.maxY - r.midY) }
        let window = self.window ?? Self.makeWindow()
        self.window = window
        window.setFrame(frame, display: false)
        window.contentView = NSHostingView(rootView: FlightView(thumb: thumb, path: FlightPath(from: local(from), to: local(to))))
        window.orderFrontRegardless()
        serial &+= 1
        let current = serial
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Motion.flight + 0.05))
            guard let self, self.serial == current else { return }
            window.orderOut(nil)
            window.contentView = nil   // stops the timeline
        }
    }

    private static func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar               // above the menu bar, like the toast
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true        // never takes a click or focus from the toast's note field
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}
