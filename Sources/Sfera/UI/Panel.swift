import AppKit
import SferaCore
import SwiftUI

/// The menu-bar panel: one switch, the sound field, A/B and room. Tuning sits behind
/// the gear, on the panel's second page.
struct Panel: View {
    let model: Controller

    static let width: CGFloat = 320

    var body: some View {
        ZStack {
            if model.panelPage == .main {
                MainPage(model: model, openSettings: { withAnimation(.snappy(duration: 0.3)) { model.panelPage = .settings } })
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            } else {
                SettingsPage(model: model, back: { withAnimation(.snappy(duration: 0.3)) { model.panelPage = .main } })
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .frame(width: Self.width)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .clipped()
    }
}

private struct MainPage: View {
    let model: Controller
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)

            SoundField(mode: fieldMode, activeChannels: model.activeChannels, level: model.level)
                .frame(width: 236, height: 236)
                .padding(.top, 6)
                .animation(.easeOut(duration: 0.3), value: model.activeChannels)

            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.headline)
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(model.wantsOn ? Theme.text : Theme.secondary)
                        .contentTransition(.opacity)
                    if model.receiving, model.route != .none {
                        Chip(text: model.settings.spatial ? "SPATIAL" : "ORIGINAL", accent: model.settings.spatial)
                    }
                }
                Text(model.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.top, 2)
            .animation(.easeOut(duration: 0.2), value: model.headline)

            VStack(spacing: 10) {
                Segmented(options: [(true, "Spatial"), (false, "Original")],
                          selection: Binding(get: { model.settings.spatial }, set: { model.settings.spatial = $0 }),
                          height: 32)
                HStack(spacing: 10) {
                    Text("Room")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 40, alignment: .leading)
                    Segmented(options: RoomMode.allCases.map { ($0, $0.label) },
                              selection: Binding(get: { model.settings.renderMode }, set: { model.settings.renderMode = $0 }),
                              height: 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .opacity(model.wantsOn ? 1 : 0.45)
            .disabled(!model.wantsOn)

            RouteLine(model: model)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 12)

            HStack(spacing: 2) {
                QuietButton(title: "Settings", systemImage: "slider.horizontal.3", action: openSettings)
                Spacer()
                QuietButton(title: "Quit", systemImage: "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            AppGlyph(on: model.wantsOn)
            VStack(alignment: .leading, spacing: 0) {
                Text("Sfera").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Spatial audio for headphones").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Switch(isOn: Binding(get: { model.wantsOn }, set: { model.setOn($0) }))
                .help(model.wantsOn ? "Stop listening and give the Mac's sound back" : "Spatialise everything the Mac plays")
        }
    }

    private var fieldMode: SoundField.Mode {
        guard model.wantsOn, model.route != .none, model.receiving else { return .off }
        if !model.settings.spatial { return .original }
        return model.incoming == "Stereo" ? .upmix : .native
    }
}

/// Where the sound goes; amber with a fix when surround isn't available.
private struct RouteLine: View {
    let model: Controller

    var body: some View {
        if let note = model.routeNote {
            HStack(spacing: 7) {
                Image(systemName: model.routeNeedsAttention ? "exclamationmark.circle.fill" : "headphones")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.routeNeedsAttention ? Theme.amber : Theme.tertiary)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(model.routeNeedsAttention ? Theme.amber.opacity(0.9) : Theme.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.loopbackName == nil {
                    GetBlackHole(size: 11)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(model.routeNeedsAttention ? Theme.amber.opacity(0.08) : Color.white.opacity(0.03)))
        } else if let error = model.errorMessage {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(Theme.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Opens the BlackHole download page (a button rather than Link, so snapshots draw it).
private struct GetBlackHole: View {
    let size: CGFloat
    var body: some View {
        Button { NSWorkspace.shared.open(Controller.blackHoleURL) } label: {
            Text("Get")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.teal))
        }
        .buttonStyle(.plain)
        .help("Download BlackHole 16ch (free)")
    }
}

private struct Chip: View {
    let text: String
    let accent: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(accent ? Theme.teal : Theme.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill((accent ? Theme.teal : Color.white).opacity(0.12)))
            .offset(y: -3)
    }
}

/// The app mark: concentric rings around a dot.
struct AppGlyph: View {
    let on: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x262A33), Color(hex: 0x15171C)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            Circle().strokeBorder(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.tertiary), lineWidth: 1.5)
                .frame(width: 20, height: 20)
            Circle().strokeBorder((on ? Theme.teal : Theme.tertiary).opacity(0.5), lineWidth: 1)
                .frame(width: 12, height: 12)
            Circle().fill(on ? Theme.teal : Theme.tertiary).frame(width: 4, height: 4)
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    let model: Controller
    let back: () -> Void

    private func binding<T>(_ keyPath: WritableKeyPath<LiveSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { model.settings[keyPath: keyPath] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                QuietButton(title: "Back", systemImage: "chevron.left", action: back)
                Spacer()
                Text("Settings").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Color.clear.frame(width: 62, height: 1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Stereo upmix")
                    Card {
                        VStack(spacing: 13) {
                            TuningSlider(title: "Centre", value: binding(\.upmix.centerExtraction))
                            TuningSlider(title: "Width", value: binding(\.upmix.width))
                            TuningSlider(title: "Surround", value: binding(\.upmix.surround))
                            TuningSlider(title: "Height", value: binding(\.upmix.height))
                            SettingRow(title: "Bass to LFE", caption: "Low-passed mono bass on its own channel") {
                                Switch(isOn: binding(\.upmix.generateLFE), size: 0.85)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Output")
                    Card {
                        VStack(spacing: 13) {
                            TuningSlider(title: "Volume trim", value: binding(\.outputGainDB), range: -12...6) {
                                String(format: "%+.1f dB", $0)
                            }
                            SettingRow(title: "Surround via BlackHole",
                                       caption: model.loopbackName.map { "\($0) installed · Atmos and 5.1/7.1 keep every channel" }
                                           ?? "Not installed · stereo only") {
                                if model.loopbackName == nil {
                                    GetBlackHole(size: 12)
                                } else {
                                    Switch(isOn: Binding(get: { model.useLoopback }, set: { model.useLoopback = $0 }), size: 0.85)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "General")
                    Card {
                        VStack(spacing: 12) {
                            SettingRow(title: "Listen when Sfera opens") {
                                Switch(isOn: Binding(get: { model.listenOnLaunch }, set: { model.listenOnLaunch = $0 }), size: 0.85)
                            }
                            SettingRow(title: "Open at login") {
                                Switch(isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }), size: 0.85)
                            }
                        }
                    }
                }

                Text(model.loopbackName != nil
                     ? "Apple Music: set Settings › Playback › Dolby Atmos to Automatic for Atmos mixes. With AirPods, turn their own Spatial Audio off."
                     : "Apple Music: set Settings › Playback › Dolby Atmos to Off. With AirPods, turn their own Spatial Audio off.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 14)

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 14)
            HStack {
                QuietButton(title: "Reset tuning", systemImage: "arrow.counterclockwise") { model.resetTuning() }
                Spacer()
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.trailing, 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}
