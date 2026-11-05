import SpatialCore
import SwiftUI

/// The whole window: one button, what's playing, room, source. Everything else lives in
/// Settings (⌘,).
struct ListenView: View {
    private var listen: ListenModel { AppEnv.listen }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                SettingsLink {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .frame(height: 34)
            .padding(.horizontal, 12)

            Spacer(minLength: 8)

            PowerButton()

            VStack(spacing: 6) {
                Text(listen.headline)
                    .font(Theme.sans(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(listen.detail)
                    .font(Theme.sans(12))
                    .foregroundStyle(listen.permissionProblem ? Theme.amber : Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = listen.routeNote {
                    Text(note)
                        .font(Theme.sans(10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 28)

            Spacer(minLength: 12)

            if listen.source == .files {
                FileBar(dropTargeted: listen.dropTargeted)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
            } else if let tip = listen.tip {
                TipLine(id: tip.id, text: tip.text)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
            }

            VStack(spacing: 10) {
                RoomPicker()
                SourcePicker()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .dropDestination(for: URL.self) { urls, _ in
            listen.addFiles(urls)
            return true
        } isTargeted: { AppEnv.listen.dropTargeted = $0 }
        .alert("Sfera", isPresented: Binding(
            get: { listen.errorMessage != nil },
            set: { if !$0 { AppEnv.listen.errorMessage = nil } }
        )) {
            Button("OK") { AppEnv.listen.errorMessage = nil }
        } message: {
            Text(listen.errorMessage ?? "")
        }
        .onAppear { listen.launch() }
    }
}

/// Spatial on / off. Glows with the music while it's working.
private struct PowerButton: View {
    private var listen: ListenModel { AppEnv.listen }
    private let size: CGFloat = 168

    var body: some View {
        let on = listen.settings.spatial
        let working = listen.isActive
        let tint = on ? Theme.teal : Theme.textSecondary
        let glow = working ? Double(min(1, listen.level * 1.6)) : 0

        Button { listen.toggleSpatial() } label: {
            ZStack {
                Circle()
                    .fill(tint.opacity(on && working ? 0.10 + glow * 0.10 : 0.03))
                    .blur(radius: 28)
                    .scaleEffect(1.18 + glow * 0.08)
                Circle()
                    .fill(Theme.panel)
                Circle()
                    .strokeBorder(tint.opacity(on ? (working ? 0.9 : 0.45) : 0.25), lineWidth: 2)
                Circle()
                    .strokeBorder(tint.opacity(on && working ? 0.25 + glow * 0.5 : 0), lineWidth: 7)
                    .blur(radius: 3)
                    .padding(-2)
                VStack(spacing: 10) {
                    Image(systemName: "headphones")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(on ? Theme.text : Theme.textSecondary)
                    Text(on ? "SPATIAL" : "ORIGINAL")
                        .font(Theme.mono(10, weight: .semibold))
                        .tracking(2.4)
                        .foregroundStyle(tint)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: glow)
            .animation(.smooth(duration: 0.25), value: on)
        }
        .buttonStyle(.plain)
        .help(on ? "Spatial is on. Click to hear the original (same loudness)." : "Original. Click for spatial.")
    }
}

/// Transport and scrubber, or a drop target when nothing is loaded.
private struct FileBar: View {
    let dropTargeted: Bool
    private var listen: ListenModel { AppEnv.listen }

    var body: some View {
        if listen.queue.isEmpty {
            Button { listen.presentOpenPanel() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18, weight: .light))
                    Text("Drop songs, albums or movies, or click to choose")
                        .font(Theme.sans(12, weight: .medium))
                }
                .foregroundStyle(dropTargeted ? Theme.teal : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 86)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(dropTargeted ? Theme.teal : Theme.strokeStrong)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text(Fmt.duration(listen.position))
                        .frame(width: 44, alignment: .leading)
                    Scrubber(fraction: listen.duration > 0 ? listen.position / listen.duration : 0) { listen.seek(fraction: $0) }
                    Text(Fmt.duration(listen.duration))
                        .frame(width: 44, alignment: .trailing)
                }
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()

                HStack(spacing: 22) {
                    queueMenu
                    Spacer()
                    transportButton("backward.fill", size: 14) { listen.previous() }
                    transportButton(listen.isPlayingFile ? "pause.fill" : "play.fill", size: 20) { listen.togglePlay() }
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.panelRaised))
                    transportButton("forward.fill", size: 14) { listen.next() }
                    Spacer()
                    Button { listen.presentOpenPanel() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Add files")
                }
            }
        }
    }

    private var queueMenu: some View {
        Menu {
            let next = listen.upNext
            if next.isEmpty { Text("Nothing up next") }
            ForEach(Array(next.prefix(40)), id: \.index) { entry in
                Button(entry.title) { listen.play(index: entry.index) }
            }
            Divider()
            Button("Clear queue") { listen.clearQueue() }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .fixedSize()
        .help("Up next")
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Thin seek bar; click or drag anywhere. The drag preview lives in the model.
struct Scrubber: View {
    let fraction: Double
    let onSeek: (Double) -> Void
    private var dragging: Double? { AppEnv.listen.scrubPreview }

    var body: some View {
        GeometryReader { geo in
            let shown = min(max(dragging ?? fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 3)
                Capsule().fill(Theme.teal).frame(width: max(3, geo.size.width * shown), height: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { AppEnv.listen.scrubPreview = $0.location.x / max(1, geo.size.width) }
                    .onEnded { value in
                        onSeek(min(max(value.location.x / max(1, geo.size.width), 0), 1))
                        AppEnv.listen.scrubPreview = nil
                    }
            )
        }
        .frame(height: 16)
    }
}

enum RoomNames {
    static let all: [(DistanceModel, String)] = [(.off, "Dry"), (.near, "Near"), (.mid, "Mid"), (.far, "Far")]
    static func name(_ mode: DistanceModel) -> String { all.first { $0.0 == mode }?.1 ?? "Mid" }
}

private struct RoomPicker: View {
    private var listen: ListenModel { AppEnv.listen }

    var body: some View {
        HStack(spacing: 10) {
            label("ROOM")
            Pills(options: RoomNames.all.map(\.1), selection: RoomNames.name(listen.settings.renderMode), tint: Theme.teal) { title in
                if let mode = RoomNames.all.first(where: { $0.1 == title })?.0 { listen.setRoom(mode) }
            }
        }
        .help("How much virtual room you hear. Mid sounds most like speakers.")
    }
}

private struct SourcePicker: View {
    private var listen: ListenModel { AppEnv.listen }

    var body: some View {
        HStack(spacing: 10) {
            label("SOURCE")
            Pills(options: ListenModel.Source.allCases.map(\.rawValue), selection: listen.source.rawValue, tint: Theme.violet) { title in
                if let source = ListenModel.Source(rawValue: title) { listen.selectSource(source) }
            }
        }
    }
}

private func label(_ text: String) -> some View {
    Text(text)
        .font(Theme.mono(9, weight: .semibold))
        .tracking(1.2)
        .foregroundStyle(Theme.textTertiary)
        .frame(width: 52, alignment: .leading)
}

/// Equal-width segmented pills.
private struct Pills: View {
    let options: [String]
    let selection: String
    let tint: Color
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let active = option == selection
                Button { onSelect(option) } label: {
                    Text(option)
                        .font(Theme.sans(11, weight: .semibold))
                        .foregroundStyle(active ? Color.black.opacity(0.85) : Theme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? tint : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panelSunken))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// One setup hint for the current route, shown until dismissed.
private struct TipLine: View {
    let id: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.textTertiary)
            Text(LocalizedStringKey(text))
                .font(Theme.sans(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { AppEnv.listen.dismissTip(id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
    }
}

/// Settings window: tuning a listener rarely needs.
struct ListenSettingsView: View {
    private var listen: ListenModel { AppEnv.listen }

    var body: some View {
        Form {
            Section {
                Toggle("Start listening when Sfera opens", isOn: Binding(
                    get: { AppEnv.listen.listenOnLaunch }, set: { AppEnv.listen.listenOnLaunch = $0 }))
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: binding(\.outputGainDB), in: -12...6, step: 0.5)
                        Text(String(format: "%+.1f dB", listen.settings.outputGainDB))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }

            Section {
                percentSlider("Centre", \.upmix.centerExtraction, help: "How much of the vocal and centre image is placed in front of you.")
                percentSlider("Width", \.upmix.width, help: "How far beyond the headphones the front stage spreads.")
                percentSlider("Surround", \.upmix.surround, help: "Ambience around and behind you.")
                percentSlider("Height", \.upmix.height, help: "Ambience above you.")
                Toggle("Add bass channel (LFE)", isOn: binding(\.upmix.generateLFE))
                Button("Reset to defaults") { AppEnv.listen.settings.upmix = UpmixSettings() }
            } header: {
                Text("Stereo to spatial")
            } footer: {
                Text("Used for stereo songs and apps. 5.1, 7.1 and Atmos keep their own channels.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use BlackHole for surround and Atmos", isOn: Binding(
                    get: { AppEnv.listen.useLoopback }, set: { AppEnv.listen.useLoopback = $0 }))
                if let name = listen.loopbackName {
                    LabeledContent("Loopback", value: name)
                } else {
                    LabeledContent("Loopback", value: "Not installed")
                    Link("Get BlackHole 16ch (free)…", destination: ListenModel.blackHoleURL)
                }
                if listen.route == .loopback, let output = listen.outputName {
                    LabeledContent("Playing to", value: output)
                }
            } header: {
                Text("Surround")
            } footer: {
                Text("With BlackHole installed, Sfera points the Mac's sound output at it while listening and plays the spatial result to your headphones, so Apple Music's Dolby Atmos and a video player's 5.1 arrive with every channel. Sfera hands the output back when it stops. Without BlackHole, Sfera hears every app's stereo mix.")
                    .foregroundStyle(.secondary)
            }

            Section("For the best result") {
                Text("With BlackHole: Music › Settings › Playback › Dolby Atmos: **Automatic** or **Always On**, so Atmos mixes arrive in surround.")
                Text("Without BlackHole: set Dolby Atmos to **Off**, so Sfera spatialises the stereo master instead of Apple's own headphone mix.")
                Text("AirPods or Beats: Control Center › Sound › Spatial Audio: **Off**, so the sound isn't spatialised twice.")
                Text("macOS asks once for **Microphone** access (BlackHole counts as one) or **Screen & System Audio Recording** access (without BlackHole). Audio is processed on this Mac only; nothing is recorded or sent anywhere.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ path: WritableKeyPath<LiveSettings, T>) -> Binding<T> {
        Binding(get: { AppEnv.listen.settings[keyPath: path] }, set: { AppEnv.listen.settings[keyPath: path] = $0 })
    }

    private func percentSlider(_ title: String, _ path: WritableKeyPath<LiveSettings, Double>, help: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: binding(path), in: 0...1)
                Text("\(Int((listen.settings[keyPath: path] * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .help(help)
    }
}

/// Menu bar: the same controls, so Sfera can run without its window.
struct ListenMenu: View {
    private var listen: ListenModel { AppEnv.listen }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Spatial", isOn: Binding(get: { listen.settings.spatial }, set: { _ in listen.toggleSpatial() }))
        Text("\(listen.headline): \(listen.detail)")
        Divider()
        Picker("Source", selection: Binding(get: { listen.source }, set: { listen.selectSource($0) })) {
            ForEach(ListenModel.Source.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Room", selection: Binding(get: { listen.settings.renderMode }, set: { listen.setRoom($0) })) {
            ForEach(RoomNames.all, id: \.0) { Text($0.1).tag($0.0) }
        }
        Divider()
        Button("Show Sfera") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Sfera") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
