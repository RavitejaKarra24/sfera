import SferaCore
import SwiftUI

/// Top-down view of the listener and the speakers Sfera renders around them.
///
/// Surround and Atmos light the channels that are really arriving (teal). Stereo lights the
/// virtual 7.0.4 layout the upmix creates (violet). Original lights only L and R. The glow
/// follows the output level while the panel is open.
struct SoundField: View {
    enum Mode { case off, native, upmix, original }

    let mode: Mode
    /// Bit i = loopback channel i is active (native mode).
    let activeChannels: UInt32
    let level: Float

    private static let upmixSpeakers: Set<Speaker> = [.l, .r, .c, .lss, .rss, .lrs, .rrs, .ltf, .rtf, .ltr, .rtr]

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 14
            let on = mode != .off
            let level = CGFloat(min(1, max(0, self.level) * 1.8))

            // Floor rings and azimuth ticks.
            for (i, f) in [1.0, 0.72, 0.44].enumerated() {
                let r = radius * f
                let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                context.stroke(ring, with: .color(.white.opacity(i == 0 ? 0.08 : 0.045)),
                               style: StrokeStyle(lineWidth: 1, dash: i == 0 ? [] : [2, 4]))
            }
            for k in 0..<12 {
                let a = Double(k) * .pi / 6
                var tick = Path()
                tick.move(to: point(c, radius * 1.0 + 3, a))
                tick.addLine(to: point(c, radius * 1.0 + (k % 3 == 0 ? 8 : 6), a))
                context.stroke(tick, with: .color(.white.opacity(k % 3 == 0 ? 0.18 : 0.08)), lineWidth: 1)
            }

            // Level glow around the head.
            if on {
                let tint = mode == .upmix ? Theme.violet : (mode == .original ? Theme.text.opacity(0.5) : Theme.teal)
                let g = 26 + 40 * level
                context.fill(
                    Path(ellipseIn: CGRect(x: c.x - g, y: c.y - g, width: 2 * g, height: 2 * g)),
                    with: .radialGradient(Gradient(colors: [tint.opacity(0.22 + 0.25 * Double(level)), tint.opacity(0)]),
                                          center: c, startRadius: 0, endRadius: g))
            }

            // Speakers: rays to the head, then dots.
            var dots: [(CGPoint, CGFloat, Color, Double, Bool)] = []
            for speaker in Layout.loopback where !speaker.isLFE {
                let (lit, strength) = state(speaker)
                let p = position(speaker, c, radius)
                let tint = mode == .native ? Theme.teal : (mode == .original ? Theme.text : Theme.violet)
                if lit {
                    var ray = Path()
                    ray.move(to: p)
                    ray.addLine(to: c)
                    context.stroke(ray, with: .linearGradient(Gradient(colors: [tint.opacity(0.28 * strength), tint.opacity(0)]),
                                                             startPoint: p, endPoint: c), lineWidth: 1)
                }
                dots.append((p, speaker.isHeight ? 4.2 : 5.2, tint, lit ? strength : 0, speaker.isHeight))
            }
            for (p, r, tint, strength, height) in dots {
                if strength > 0 {
                    let halo = r * 3.2
                    context.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: 2 * halo, height: 2 * halo)),
                                 with: .radialGradient(Gradient(colors: [tint.opacity(0.35 * strength), tint.opacity(0)]),
                                                       center: p, startRadius: 0, endRadius: halo))
                    let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                    context.fill(dot, with: .color(tint.opacity(0.55 + 0.45 * strength)))
                } else {
                    let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                    context.fill(dot, with: .color(.white.opacity(0.07)))
                    context.stroke(dot, with: .color(.white.opacity(0.14)), lineWidth: 1)
                }
                if height {
                    // Heights: a small ring marks them as overhead.
                    let o = r + 3
                    context.stroke(Path(ellipseIn: CGRect(x: p.x - o, y: p.y - o, width: 2 * o, height: 2 * o)),
                                   with: .color((strength > 0 ? tint : .white).opacity(strength > 0 ? 0.45 : 0.1)), lineWidth: 0.8)
                }
            }

            // LFE: a short bar behind the head.
            let lfeLit = mode == .native && activeChannels & Speaker.lfe.bit != 0
            let bar = Path(roundedRect: CGRect(x: c.x - 9, y: c.y + 22, width: 18, height: 3), cornerRadius: 1.5)
            context.fill(bar, with: .color(lfeLit ? Theme.teal.opacity(0.8) : .white.opacity(0.08)))

            // The listener (front is up).
            let head = CGRect(x: c.x - 11, y: c.y - 12.5, width: 22, height: 25)
            var nose = Path()
            nose.move(to: CGPoint(x: c.x - 4, y: c.y - 11))
            nose.addLine(to: CGPoint(x: c.x, y: c.y - 17))
            nose.addLine(to: CGPoint(x: c.x + 4, y: c.y - 11))
            nose.closeSubpath()
            context.fill(nose, with: .color(Color(hex: 0x2A2D36)))
            for side in [-1.0, 1.0] {
                let ear = Path(roundedRect: CGRect(x: c.x + side * 11.5 - 2.5, y: c.y - 5, width: 5, height: 10), cornerRadius: 2.5)
                context.fill(ear, with: .color(Color(hex: on ? 0x3A3E4A : 0x2A2D36)))
            }
            context.fill(Path(ellipseIn: head), with: .linearGradient(
                Gradient(colors: [Color(hex: 0x353945), Color(hex: 0x1D1F26)]),
                startPoint: CGPoint(x: head.midX, y: head.minY), endPoint: CGPoint(x: head.midX, y: head.maxY)))
            context.stroke(Path(ellipseIn: head), with: .color(.white.opacity(on ? 0.22 : 0.1)), lineWidth: 1)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch mode {
        case .off: "Sound field, off"
        case .native: "Sound field: \(Layout.describe(activeChannels: activeChannels)) channels around you"
        case .upmix: "Sound field: stereo upmixed to 7.0.4 around you"
        case .original: "Sound field: original stereo"
        }
    }

    private func state(_ s: Speaker) -> (Bool, Double) {
        switch mode {
        case .off: return (false, 0)
        case .native: return (activeChannels & s.bit != 0, 1)
        case .original: return (s == .l || s == .r, 0.8)
        case .upmix:
            guard Self.upmixSpeakers.contains(s) else { return (false, 0) }
            switch s {
            case .l, .r, .c: return (true, 1)
            case .lss, .rss: return (true, 0.75)
            default: return (true, 0.55)
            }
        }
    }

    /// Ear-plane speakers on the outer ring, front heights on the middle ring, the top
    /// centre near the middle.
    private func position(_ s: Speaker, _ c: CGPoint, _ radius: CGFloat) -> CGPoint {
        let a = s.azimuth * .pi / 180
        switch s {
        case .cts: return point(c, radius * 0.24, a)
        default: return point(c, radius * (s.isHeight ? 0.58 : 1.0), a)
        }
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
    }
}
