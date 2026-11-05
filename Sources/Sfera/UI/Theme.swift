import SwiftUI

enum Theme {
    static let top = Color(hex: 0x17191F)
    static let bottom = Color(hex: 0x0C0D11)
    static let card = Color.white.opacity(0.045)
    static let cardStrong = Color.white.opacity(0.08)
    static let stroke = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.06)

    static let text = Color(hex: 0xEFECE6)
    static let secondary = Color(hex: 0x9EA0AA)
    static let tertiary = Color(hex: 0x666873)

    static let teal = Color(hex: 0x4FD6C2)
    static let tealDeep = Color(hex: 0x2BA897)
    static let violet = Color(hex: 0x9B8AFF)
    static let amber = Color(hex: 0xF5B54B)

    static let accent = LinearGradient(colors: [Color(hex: 0x5BE3CF), Color(hex: 0x37B9D9)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
    static let background = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)

    static func label(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .semibold) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label(9.5))
            .tracking(1.2)
            .foregroundStyle(Theme.tertiary)
    }
}

/// Capsule on/off switch (drawn, so it matches the panel and renders in snapshots).
struct Switch: View {
    @Binding var isOn: Bool
    var size: CGFloat = 1

    var body: some View {
        let w = 34 * size, h = 20 * size
        Button { withAnimation(.snappy(duration: 0.22)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0.0 : 0.06), lineWidth: 1))
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .padding(2 * size)
            }
            .frame(width: w, height: h)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

/// Segmented control with a sliding highlight.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var height: CGFloat = 30
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let selected = value == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.text : Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: height - 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: (height - 4) / 2.6, style: .continuous)
                                    .fill(Color.white.opacity(0.11))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: (height - 4) / 2.6, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                                    )
                                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "highlight", in: space)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: height / 2.6, style: .continuous)
                .fill(Color.black.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: height / 2.6, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        )
    }
}

/// Thin slider with a value readout.
struct TuningSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded())) %" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            GeometryReader { geo in
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = CGFloat(fraction) * geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09)).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: max(4, x), height: 4)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: min(max(0, x - 7), geo.size.width - 14))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = min(max(0, g.location.x / geo.size.width), 1)
                    let v = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                    value = (v * 100).rounded() / 100
                })
            }
            .frame(height: 14)
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

/// A row with a title, an optional caption, and a trailing control.
struct SettingRow<Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                if let caption {
                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Rounded card.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Plain text button that lights up while pressed.
struct QuietButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(QuietStyle())
    }

    private struct QuietStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(configuration.isPressed ? Theme.text : Theme.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
    }
}
