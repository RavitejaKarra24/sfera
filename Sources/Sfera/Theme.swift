import SwiftUI

enum Theme {
    static let background = Color(hex: 0x0A0B0E)
    static let panel = Color(hex: 0x121318)
    static let panelRaised = Color(hex: 0x191A20)
    static let panelSunken = Color(hex: 0x0E0F13)
    static let stroke = Color.white.opacity(0.075)
    static let strokeStrong = Color.white.opacity(0.14)

    static let text = Color(hex: 0xEDEAE3)
    static let textSecondary = Color(hex: 0x9A9CA6)
    static let textTertiary = Color(hex: 0x64666F)

    static let violet = Color(hex: 0x8F7BFF)
    static let teal = Color(hex: 0x4FD6C2)
    static let green = Color(hex: 0x4ADE80)
    static let amber = Color(hex: 0xF5B54B)
    static let orange = Color(hex: 0xF08B4B)
    static let red = Color(hex: 0xF26D6D)
    static let blue = Color(hex: 0x5AA9FF)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Primitives

struct Panel<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text.uppercased())
                .font(Theme.sans(9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.textTertiary)
            if let trailing {
                Text(trailing.uppercased())
                    .font(Theme.mono(9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
    }
}

struct Hairline: View {
    var color: Color = Theme.stroke
    var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

struct Chip: View {
    let title: String
    var isActive: Bool = false
    var tint: Color = Theme.violet
    var wide: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.sans(10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(isActive ? Color.black.opacity(0.85) : Theme.textSecondary)
                .padding(.horizontal, wide ? 14 : 9)
                .frame(height: 24)
                .frame(maxWidth: wide ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? tint : Theme.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isActive ? tint.opacity(0.9) : Theme.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct IconToggle: View {
    let symbol: String
    var isActive: Bool
    var tint: Color = Theme.violet
    var help: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Color.black.opacity(0.85) : Theme.textSecondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? tint : Theme.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isActive ? tint.opacity(0.9) : Theme.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ValueBadge: View {
    let value: String
    var unit: String? = nil
    var tint: Color = Theme.text

    var body: some View {
        HStack(spacing: 3) {
            Text(value)
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(tint)
            if let unit {
                Text(unit)
                    .font(Theme.mono(8.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Vertical LED-style meter used for output levels.
struct LevelMeter: View {
    var level: Double
    var peak: Double
    var segments: Int = 24
    var tint: Color = Theme.green

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let lit = Int((level.clamped(to: -60...0) + 60) / 60 * Double(segments))
            VStack(spacing: 1.5) {
                ForEach((0..<segments).reversed(), id: \.self) { index in
                    let active = index < lit
                    let segmentColor: Color = {
                        let db = Double(index) / Double(segments) * 60 - 60
                        if db > -3 { return Theme.red }
                        if db > -12 { return Theme.amber }
                        return tint
                    }()
                    RoundedRectangle(cornerRadius: 1)
                        .fill(active ? segmentColor : Theme.textTertiary.opacity(0.13))
                        .frame(height: max(2, (height - CGFloat(segments) * 1.5) / CGFloat(segments)))
                }
            }
            .overlay(alignment: .bottom) {
                let peakNorm = (peak.clamped(to: -60...0) + 60) / 60
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(height: 1.5)
                    .offset(y: -CGFloat(peakNorm) * height)
            }
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Formatting

enum Fmt {
    static func timecode(_ seconds: Double, frameRate: Double) -> String {
        let safe = max(0, seconds)
        let hours = Int(safe / 3600)
        let minutes = Int(safe.truncatingRemainder(dividingBy: 3600) / 60)
        let secs = Int(safe.truncatingRemainder(dividingBy: 60))
        let frames = Int((safe - floor(safe)) * frameRate)
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, secs, frames)
    }

    static func db(_ value: Double) -> String {
        if value <= -120 || value.isNaN || value.isInfinite { return "−∞" }
        return String(format: "%.1f", value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    static func signed(_ value: Double, digits: Int = 2) -> String {
        String(format: "%+.\(digits)f", value)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
