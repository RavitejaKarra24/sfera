import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Observation
import SpatialCore
import UniformTypeIdentifiers

/// The whole app for a listener: spatialise everything the Mac plays, or play songs and
/// movies through the same engine.
///
/// - **Mac audio with BlackHole installed:** the Mac's output is pointed at BlackHole and
///   Sfera reads all 16 channels, so Apple Music's Dolby Atmos (a 9.1.6 bed), a video
///   player's 5.1 and plain stereo all arrive as they are. Surround is rendered from its
///   own channels; stereo is upmixed. Sfera plays to your real headphones/DAC.
/// - **Mac audio without BlackHole:** a process tap captures every app's stereo mix.
/// - **Files:** songs and movies are decoded by Sfera itself (5.1/7.1 kept).
@MainActor
@Observable
final class ListenModel {
    enum Source: String, CaseIterable, Identifiable, Codable {
        case live = "Mac audio"
        case files = "Files"
        var id: String { rawValue }
    }

    enum Route: Equatable {
        case none
        /// Process tap, stereo.
        case tap
        /// BlackHole, up to 16 channels.
        case loopback
    }

    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "aac", "flac", "wav", "aif", "aiff", "aifc", "caf", "alac", "m4b",
        "ec3", "eac3", "ac3", "rf64", "bwf",
    ]
    static let mediaExtensions = audioExtensions.union(StreamingFile.videoExtensions)
    /// Read whole by Sfera's own parser (ADM BWF Atmos masters live in WAV containers).
    nonisolated static let wholeFileExtensions: Set<String> = ["wav", "bwf", "rf64"]
    static let blackHoleURL = URL(string: "https://existential.audio/blackhole/")!
    /// BlackHole's volume slider when listening starts: the middle.
    static let loopbackStartVolume: Float32 = 0.5

    // MARK: Preferences (persisted)

    var source: Source = .live { didSet { persist() } }
    var settings = LiveSettings() {
        didSet {
            output.update(settings)
            persist()
        }
    }
    /// Start listening as soon as Sfera opens.
    var listenOnLaunch = true { didSet { persist() } }
    /// Use BlackHole (when installed) so surround and Atmos arrive with every channel.
    var useLoopback = true {
        didSet {
            persist()
            if oldValue != useLoopback, source == .live, wantsCapture { restartCapture() }
        }
    }
    private(set) var dismissedTips: Set<String> = []

    // MARK: State

    private(set) var route: Route = .none
    private(set) var isCapturing = false
    private(set) var receivingAudio = false
    private(set) var permissionProblem = false
    private(set) var microphoneDenied = false
    private(set) var loopbackName: String?
    private(set) var outputName: String?
    /// What the loopback is carrying right now: "Atmos", "7.1", "5.1", "Stereo".
    private(set) var incoming = "Stereo"
    private(set) var queue: [URL] = []
    private(set) var currentIndex: Int?
    private(set) var isLoadingFile = false
    private(set) var isPlayingFile = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var nowPlaying = ""
    private(set) var inputLayout: ChannelLayout?
    private(set) var hasVideo = false
    /// Smoothed output level (0…1) for the power button's glow.
    private(set) var level: Float = 0
    var errorMessage: String?
    // View state (SwiftUI's @State macro isn't available with Command Line Tools).
    var dropTargeted = false
    var scrubPreview: Double?

    private let output = LiveOutput()
    private let capture = SystemAudioCapture()
    private let surround = SurroundCapture()
    private var item: PlaybackItem?
    private var video: VideoWindowController?
    private var timer: Timer?
    private var lastAudio: Date?
    private var captureStarted: Date?
    private var wantsCapture = false
    private var awaitingPermission = false
    private var lastCaptureAttempt = Date.distantPast
    private var lastDeviceScan = Date.distantPast
    private var triedOutputClock = false
    private var loadGeneration = 0
    private var launched = false
    /// The real device Sfera plays to while the Mac's output points at the loopback.
    private var realOutput: AudioDeviceID?
    private var loopback: AudioDeviceID?
    private var defaultListener: AudioDevices.Listener?
    private var rateListener: AudioDevices.Listener?
    /// You picked a real output (e.g. FIIO KA13) while Sfera was using BlackHole: respect
    /// it and stay stereo until BlackHole is chosen again (or listening is restarted).
    private(set) var loopbackDeclined = false
    /// Set while a route is rebuilt within a session (rate/device change): keep the
    /// BlackHole volume you chose instead of resetting it.
    private var restarting = false
    /// Snapshot mode: fake state, nothing persisted.
    private var previewing = false

    private enum Key {
        static let settings = "listen.settings", source = "listen.source", autostart = "listen.autostart"
        static let loopback = "listen.useLoopback", tips = "listen.dismissedTips"
        /// Device to hand the Mac's output back to (also used after a crash).
        static let restore = "listen.restoreOutputUID"
        static let lastOutput = "listen.outputUID"
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Key.settings),
           let saved = try? JSONDecoder().decode(LiveSettings.self, from: data) {
            settings = saved
        }
        if defaults.string(forKey: Key.source) == Source.files.rawValue { source = .files }
        if defaults.object(forKey: Key.autostart) != nil { listenOnLaunch = defaults.bool(forKey: Key.autostart) }
        if defaults.object(forKey: Key.loopback) != nil { useLoopback = defaults.bool(forKey: Key.loopback) }
        dismissedTips = Set(defaults.stringArray(forKey: Key.tips) ?? [])
        output.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.outputDeviceChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Probes change settings (e.g. −90 dB) without saving them.
    var persistenceEnabled = true

    private func persist() {
        guard !previewing, persistenceEnabled else { return }
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Key.settings) }
        defaults.set(Source.live.rawValue, forKey: Key.source)
        defaults.set(listenOnLaunch, forKey: Key.autostart)
        defaults.set(useLoopback, forKey: Key.loopback)
        defaults.set(Array(dismissedTips), forKey: Key.tips)
    }

    /// Called once when the window first appears.
    func launch() {
        guard !launched else { return }
        launched = true
        SferaLog.write("launch · BlackHole \(AudioDevices.loopbackDevice().map(AudioDevices.name) ?? "not installed") · Mac output \(AudioDevices.defaultOutput().map(AudioDevices.name) ?? "none")")
        defaultListener = AudioDevices.onDefaultOutputChange { [weak self] in
            Task { @MainActor in self?.defaultOutputChanged() }
        }
        scanDevices()
        if source == .live, listenOnLaunch {
            startCapture()
        } else {
            restoreMacOutput()   // e.g. after a crash while routed through BlackHole
        }
    }

    /// App is quitting: hand the Mac's output back.
    func shutdown() {
        stopCapture()
        stopFile()
    }

    // MARK: - What the window shows

    var isActive: Bool { isCapturing || item != nil || (previewing && level > 0) }
    /// What Sfera's engine is really doing (for probes and the log).
    var engineDevice: AudioDeviceID { output.deviceID }
    var engineRunning: Bool { output.isRunning }
    var engineInputPeak: Float { output.spatializer?.inputPeak ?? 0 }
    var loopbackInstalled: Bool { loopbackName != nil }

    /// Big line under the power button.
    var headline: String {
        switch source {
        case .files: nowPlaying.isEmpty ? "Nothing playing" : nowPlaying
        case .live: "Mac audio"
        }
    }

    /// One short line saying what is happening.
    var detail: String {
        if source == .files {
            if isLoadingFile { return "Opening…" }
            guard let layout = inputLayout else { return queue.isEmpty ? "Stereo becomes spatial; 5.1 and 7.1 keep their surround" : "Ready" }
            return conversion(layout) + (isPlayingFile ? "" : " · paused")
        }
        if !isCapturing { return wantsCapture ? "Starting…" : "Off. Press the button to listen" }
        if permissionProblem {
            return route == .loopback
                ? "Allow Sfera in System Settings › Privacy & Security › Microphone (macOS counts BlackHole as one)"
                : "Allow Sfera in System Settings › Privacy & Security › Screen & System Audio Recording"
        }
        if !receivingAudio { return "Waiting for audio…" }
        let input = route == .loopback ? incoming : "Stereo"
        return settings.spatial ? "\(input) → Spatial" : "\(input) · Original"
    }

    /// Small print under the detail line (where the sound goes).
    var routeNote: String? {
        guard source == .live, isCapturing else { return nil }
        switch route {
        case .loopback: return "via \(loopbackName ?? "BlackHole") → \(outputName ?? "output")"
        case .tap:
            if !loopbackInstalled { return "Stereo only. Install BlackHole for surround and Atmos" }
            if loopbackDeclined { return "Stereo to \(outputName ?? "your output"). Pick \(loopbackName ?? "BlackHole") as the Mac's output for surround" }
            return microphoneDenied ? "Stereo only. Allow Sfera under Privacy & Security › Microphone for surround" : nil
        case .none: return nil
        }
    }

    /// One tip worth showing for the current situation, if not dismissed.
    var tip: (id: String, text: String)? {
        guard source == .live else { return nil }
        let tip: (String, String)
        if route == .loopback {
            tip = ("atmos-on", "To hear Apple Music's Dolby Atmos mixes in surround, set **Music › Settings › Playback › Dolby Atmos** to Automatic or Always On.")
        } else {
            tip = ("atmos-off", "For the best result, set **Music › Settings › Playback › Dolby Atmos** to Off. With AirPods, also turn their **Spatial Audio** off.")
        }
        return dismissedTips.contains(tip.0) ? nil : tip
    }

    func dismissTip(_ id: String) {
        dismissedTips.insert(id)
        persist()
    }

    private func conversion(_ layout: ChannelLayout) -> String {
        let input: String
        if layout.isBinaural { input = "Atmos master" }
        else if layout.channelCount == 1 { input = "Mono" }
        else if layout.channelCount == 2 { input = "Stereo" }
        else { input = layout.name }
        return settings.spatial ? "\(input) → Spatial" : "\(input) · Original"
    }

    // MARK: - Spatial on/off

    func toggleSpatial() {
        settings.spatial.toggle()
        // From an idle live source, the button also starts listening.
        if settings.spatial, source == .live, !isCapturing, !wantsCapture { startCapture() }
    }

    func setRoom(_ mode: DistanceModel) {
        settings.renderMode = mode
    }

    // MARK: - Live capture

    func startCapture() {
        stopFile()
        wantsCapture = true
        lastCaptureAttempt = Date()
        permissionProblem = false
        scanDevices()
        if useLoopback, !loopbackDeclined, let loop = AudioDevices.loopbackDevice() {
            startLoopback(loop)
        } else {
            startTap()
        }
    }

    private func restartCapture() {
        restarting = true
        defer { restarting = false }
        stopCapture(restoreOutput: false)
        startCapture()
    }

    /// Stereo fallback: tap every app except Sfera.
    private func startTap() {
        // The tap mutes every other app and Sfera plays to the Mac's output, so that output
        // must be your real device, never BlackHole (that would be silence).
        surround.stop()
        rateListener = nil
        loopback = nil
        restoreMacOutput()
        let target = AudioDevices.defaultOutput().flatMap { AudioDevices.isLoopback($0) ? nil : $0 }
            ?? chooseRealOutput(excluding: AudioDevices.loopbackDevice() ?? AudioDeviceID(kAudioObjectUnknown))
        if let target, AudioDevices.defaultOutput() != target { AudioDevices.setDefaultOutput(target) }
        do {
            triedOutputClock = false
            try capture.start()
            output.frameClock = nil
            let ring = capture.ring
            ring.targetFrames = 2048
            ring.maxFrames = 8192
            try output.start(sampleRate: capture.sampleRate, layout: .stereo, settings: settings, device: target) { inputs, frames in
                ring.read(into: inputs, frames: frames)
            }
            route = .tap
            inputLayout = .stereo
            isCapturing = true
            captureStarted = Date()
            lastAudio = nil
            realOutput = target
            outputName = target.map(AudioDevices.name)
            SferaLog.write("tap route → \(outputName ?? "default output")")
        } catch {
            capture.stop()
            output.stop()
            route = .none
            isCapturing = false
            wantsCapture = false
            errorMessage = error.localizedDescription
            SferaLog.write("tap route failed: \(error.localizedDescription)")
        }
    }

    /// Surround: the Mac plays into BlackHole, Sfera reads every channel and plays the
    /// binaural result to the real output device.
    private func startLoopback(_ loop: AudioDeviceID) {
        // macOS treats BlackHole's input as a microphone.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            awaitingPermission = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.awaitingPermission = false
                    if self.wantsCapture, !self.isCapturing { self.startCapture() }
                }
            }
            return
        case .denied, .restricted:
            microphoneDenied = true
            SferaLog.write("microphone permission denied; BlackHole can't be read, using stereo")
            startTap()
            return
        default:
            microphoneDenied = false
        }
        guard let out = chooseRealOutput(excluding: loop) else {
            errorMessage = "Sfera couldn't find headphones or speakers to play to."
            startTap()
            return
        }
        let defaults = UserDefaults.standard
        if let uid = AudioDevices.uid(out) {
            defaults.set(uid, forKey: Key.lastOutput)
            defaults.set(uid, forKey: Key.restore)
        }
        // Point the Mac at the loopback *before* Sfera's engine starts: AVAudioEngine jumps
        // to the new default output when the default changes under it, which would make
        // Sfera play into BlackHole (and stop) instead of to your headphones.
        if AudioDevices.defaultOutput() != loop { AudioDevices.setDefaultOutput(loop) }
        do {
            try surround.start(loopback: loop, output: out)
            output.frameClock = nil
            let ring = surround.ring
            try output.start(sampleRate: surround.sampleRate, layout: surround.layout, settings: settings,
                             adaptive: true, device: out) { inputs, frames in
                ring.read(into: inputs, frames: frames)
            }
            guard output.deviceID == out, output.isRunning else {
                throw MediaError.unsupported("Sfera's output landed on \(output.deviceName) instead of \(AudioDevices.name(out))")
            }
        } catch {
            surround.stop()
            output.stop()
            SferaLog.write("BlackHole route failed (\(AudioDevices.name(out))): \(error.localizedDescription); falling back to stereo")
            errorMessage = error.localizedDescription
            startTap()
            return
        }
        loopback = loop
        realOutput = out
        // While the Mac plays to BlackHole, its volume keys set BlackHole's volume, which
        // scales everything Sfera receives. Each session starts with the slider in the
        // middle (your choice), leaving room both ways for the volume keys.
        let before = AudioDevices.volumeDB(loop).map { String(format: "%.1f dB", $0) } ?? "n/a"
        let muted = AudioDevices.isMuted(loop)
        if !restarting {
            AudioDevices.setVolume(Self.loopbackStartVolume, unmute: loop)
            let after = AudioDevices.volumeDB(loop).map { String(format: "%.1f dB", $0) } ?? "n/a"
            SferaLog.write("BlackHole volume \(before)\(muted ? " (muted)" : "") → \(after)")
        } else {
            SferaLog.write("BlackHole volume kept at \(before)\(muted ? " (muted)" : "")")
        }
        rateListener = AudioDevices.onRateChange(loop) { [weak self] in
            Task { @MainActor in self?.loopbackRateChanged() }
        }
        route = .loopback
        inputLayout = surround.layout
        isCapturing = true
        captureStarted = Date()
        lastAudio = nil
        incoming = "Stereo"
        outputName = AudioDevices.name(out)
        SferaLog.write(String(format: "BlackHole route: %@ → %@ at %.0f Hz, %d channels",
                              AudioDevices.name(loop), AudioDevices.name(out), surround.sampleRate, surround.channelCount))
    }

    /// The real device to play to: the current default unless it's the loopback, else the
    /// one used last time, else the best physical output.
    private func chooseRealOutput(excluding loop: AudioDeviceID) -> AudioDeviceID? {
        if let current = AudioDevices.defaultOutput(), current != loop, AudioDevices.isPhysicalOutput(current) {
            return current
        }
        for key in [Key.lastOutput, Key.restore] {
            if let uid = UserDefaults.standard.string(forKey: key), let device = AudioDevices.device(uid: uid),
               AudioDevices.isPhysicalOutput(device) { return device }
        }
        let outputs = AudioDevices.physicalOutputs()
        let preference: [UInt32] = [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
                                    kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeBuiltIn]
        for transport in preference {
            if let device = outputs.first(where: { AudioDevices.transport($0) == transport }) { return device }
        }
        return outputs.first
    }

    func stopCapture(restoreOutput: Bool = true) {
        if restoreOutput { loopbackDeclined = false }
        wantsCapture = false
        output.stop()
        capture.stop()
        surround.stop()
        rateListener = nil
        if restoreOutput { restoreMacOutput() }
        route = .none
        isCapturing = false
        receivingAudio = false
        permissionProblem = false
        inputLayout = nil
    }

    /// Hands the Mac's output back to the real device if Sfera left it on the loopback.
    private func restoreMacOutput() {
        let defaults = UserDefaults.standard
        guard let uid = defaults.string(forKey: Key.restore) else { return }
        if let current = AudioDevices.defaultOutput(), AudioDevices.isLoopback(current),
           let device = AudioDevices.device(uid: uid) {
            AudioDevices.setDefaultOutput(device)
        }
        defaults.removeObject(forKey: Key.restore)
    }

    private func scanDevices() {
        lastDeviceScan = Date()
        loopbackName = AudioDevices.loopbackDevice().map(AudioDevices.name)
    }

    /// The Mac's output menu is the switch:
    /// - a real device (FIIO KA13, AirPods…) chosen while on BlackHole → Sfera plays stereo
    ///   to it and leaves the Mac's output alone;
    /// - BlackHole chosen while on stereo → surround again;
    /// - on stereo, another real device → follow it.
    private func defaultOutputChanged() {
        guard isCapturing, let now = AudioDevices.defaultOutput() else { return }
        let nowIsLoopback = AudioDevices.isLoopback(now)
        switch route {
        case .loopback:
            guard now != loopback, !nowIsLoopback, AudioDevices.isPhysicalOutput(now) else { return }
            SferaLog.write("you chose \(AudioDevices.name(now)) as the Mac's output; leaving BlackHole, stereo only")
            if let uid = AudioDevices.uid(now) { UserDefaults.standard.set(uid, forKey: Key.lastOutput) }
            UserDefaults.standard.removeObject(forKey: Key.restore)
            loopbackDeclined = true
            restartCapture()
        case .tap:
            if nowIsLoopback {
                guard useLoopback else { return }
                SferaLog.write("you chose \(AudioDevices.name(now)); surround on")
                loopbackDeclined = false
                restartCapture()
            } else if now != realOutput, AudioDevices.isPhysicalOutput(now) {
                restartCapture()
            }
        case .none:
            return
        }
    }

    /// A player switched BlackHole's rate (e.g. a 44.1 kHz or 96 kHz lossless track).
    private func loopbackRateChanged() {
        guard route == .loopback, let loop = loopback else { return }
        guard abs(AudioDevices.nominalRate(loop) - surround.sampleRate) > 0.5 else { return }
        restartCapture()
    }

    // MARK: - Files

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent, .folder]
        panel.message = "Choose songs, albums or movies"
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    /// Adds files (folders are scanned recursively) and starts playing the first one.
    func addFiles(_ urls: [URL], playNow: Bool = true) {
        var found: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                var inFolder: [URL] = []
                while let entry = walker?.nextObject() as? URL {
                    if Self.mediaExtensions.contains(entry.pathExtension.lowercased()) { inFolder.append(entry) }
                }
                inFolder.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                found += inFolder
            } else if Self.mediaExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        guard !found.isEmpty else {
            errorMessage = "Sfera can't play that. It plays AAC, ALAC, MP3, FLAC, WAV, AIFF, Dolby Digital and MP4/MOV movies."
            return
        }
        if source != .files { selectSource(.files) }
        let first = queue.count
        queue.append(contentsOf: found)
        if playNow || item == nil { play(index: first) }
    }

    func clearQueue() {
        stopFile()
        queue.removeAll()
        currentIndex = nil
        nowPlaying = ""
    }

    var upNext: [(index: Int, title: String)] {
        guard let currentIndex else { return queue.enumerated().map { ($0.offset, $0.element.deletingPathExtension().lastPathComponent) } }
        return queue.indices.filter { $0 > currentIndex }.map { ($0, queue[$0].deletingPathExtension().lastPathComponent) }
    }

    func play(index: Int) {
        guard queue.indices.contains(index) else { return }
        if isCapturing || wantsCapture { stopCapture() }
        stopFile()
        loadGeneration += 1
        let generation = loadGeneration
        let url = queue[index]
        currentIndex = index
        isLoadingFile = true
        nowPlaying = url.deletingPathExtension().lastPathComponent
        let renderMode = settings.renderMode
        Task {
            do {
                let item = try await Self.open(url: url, renderMode: renderMode)
                guard generation == self.loadGeneration else { item.close(); return }
                self.startItem(item)
            } catch {
                guard generation == self.loadGeneration else { return }
                self.isLoadingFile = false
                self.errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Opens a file for playback: streamed from disk when macOS can decode it (songs and
    /// movies), else read whole by Sfera's importer (ADM BWF, or ffmpeg formats).
    nonisolated static func open(url: URL, renderMode: DistanceModel) async throws -> PlaybackItem {
        let ext = url.pathExtension.lowercased()
        if !wholeFileExtensions.contains(ext) {
            do { return try await StreamingFile.open(url: url) } catch {
                // fall through to the whole-file importer
            }
        }
        return try await Task.detached(priority: .userInitiated) {
            try ListenModel.decode(url: url, renderMode: renderMode)
        }.value
    }

    /// Whole-file decode. Channel-based audio stays live; ADM masters with moving objects
    /// are rendered to binaural up front.
    nonisolated static func decode(url: URL, renderMode: DistanceModel) throws -> FilePlayback {
        let media = try MediaImporter.load(url: url)
        let hasObjects = media.sources.contains { if case .object = $0.kind { return true }; return false }
        if hasObjects {
            let sources = media.sources.map { source -> RenderSource in
                var s = source; s.distance = renderMode; return s
            }
            let settings = RenderSettings(sampleRate: media.sampleRate)
            let (audio, _) = SpatialEngine.render(sources: sources, frames: media.frames, settings: settings)
            return FilePlayback(channels: audio.channels, sampleRate: media.sampleRate,
                                layout: ChannelLayout(name: "BIN", speakers: [.l, .r]),
                                title: media.title, detail: "Atmos master")
        }
        let speakers = media.sources.compactMap { s -> Speaker? in if case .bed(let sp) = s.kind { return sp }; return nil }
        let layout = StreamingFile.layout(for: speakers)
        return FilePlayback(channels: media.sources.map(\.audio), sampleRate: media.sampleRate, layout: layout,
                            title: media.title, detail: layout.name)
    }

    private func startItem(_ item: PlaybackItem, resume: Bool = true) {
        output.frameClock = { item.currentFrame }
        do {
            try output.start(sampleRate: item.sampleRate, layout: item.layout, settings: settings) { inputs, frames in
                item.read(into: inputs, frames: frames)
            }
        } catch {
            isLoadingFile = false
            item.close()
            errorMessage = error.localizedDescription
            return
        }
        self.item = item
        if resume { item.setPlaying(true) }
        isPlayingFile = item.isPlaying
        isLoadingFile = false
        inputLayout = item.layout
        duration = item.duration
        position = Double(item.currentFrame) / item.sampleRate
        nowPlaying = item.title
        if let asset = item.videoAsset {
            if video == nil {
                let controller = VideoWindowController(asset: asset, title: item.title)
                controller.onClose = { [weak self] in self?.videoClosed() }
                video = controller
                controller.show()
            }
            hasVideo = true
        } else {
            closeVideo()
        }
    }

    func stopFile() {
        loadGeneration += 1
        item?.close()
        if item != nil { output.stop() }
        item = nil
        closeVideo()
        isPlayingFile = false
        isLoadingFile = false
        if !isCapturing { inputLayout = nil }
    }

    private func closeVideo() {
        video?.close()
        video = nil
        hasVideo = false
    }

    /// The movie window was closed by the user: stop the movie.
    private func videoClosed() {
        video = nil
        hasVideo = false
        stopFile()
    }

    /// Space bar / main button for the current source.
    func togglePlay() {
        guard source == .files else {
            toggleSpatial()
            return
        }
        if let item {
            let play = !item.isPlaying
            if play, item.didFinish { item.seek(to: 0) }
            item.setPlaying(play)
            isPlayingFile = play
        } else if let currentIndex {
            play(index: currentIndex)
        } else if !queue.isEmpty {
            play(index: 0)
        } else {
            presentOpenPanel()
        }
    }

    func next() {
        guard let currentIndex else { return }
        if currentIndex + 1 < queue.count { play(index: currentIndex + 1) } else { stopFile() }
    }

    func previous() {
        guard let currentIndex else { return }
        if let item, item.currentFrame > Int(item.sampleRate * 3) { item.seek(to: 0); return }
        play(index: max(0, currentIndex - 1))
    }

    func seek(fraction: Double) {
        guard let item else { return }
        let frame = Int(min(max(fraction, 0), 1) * item.duration * item.sampleRate)
        item.seek(to: frame)
        output.resetClock()
        position = Double(frame) / item.sampleRate
    }

    func skip(seconds: Double) {
        guard let item, item.duration > 0 else { return }
        seek(fraction: (position + seconds) / item.duration)
    }

    func selectSource(_ new: Source) {
        guard new != source else {
            if new == .live, !isCapturing, !wantsCapture { startCapture() }
            return
        }
        if isCapturing || wantsCapture { stopCapture() }
        if new == .live { stopFile() }
        source = new
        if new == .live { startCapture() }
    }

    /// `--movie-probe`: real playback, but inaudible and nothing persisted.
    func beginProbe() {
        previewing = true
        launched = true
        source = .files
        settings.outputGainDB = -90
    }

    /// Where the sound and the picture are right now (seconds), for `--movie-probe`.
    var syncProbe: (audio: Double, audible: Double, video: Double, latency: Double)? {
        guard let item, let video, let heard = output.audibleTime(atHostTime: HostClock.now) else { return nil }
        let audio = Double(item.currentFrame) / item.sampleRate
        return (audio, heard, video.player.currentTime().seconds, output.totalLatency)
    }

    /// Headless snapshots: show a representative state without touching audio devices.
    func preview(page: String) {
        previewing = true
        launched = true
        dismissedTips = page == "listen-tip" ? [] : ["atmos-on", "atmos-off"]
        switch page {
        case "listen-files":
            source = .files
        case "listen-movie":
            source = .files
            queue = [URL(fileURLWithPath: "/Movies/Dune Part Two.mp4"), URL(fileURLWithPath: "/Movies/Arrival.mov")]
            currentIndex = 0
            nowPlaying = "Dune Part Two"
            inputLayout = ChannelLayout.named("5.1")
            isPlayingFile = true
            position = 2712
            duration = 9960
            level = 0.45
        case "listen-off":
            source = .live
            settings.spatial = false
        case "listen-tip":
            source = .live
            route = .tap
            isCapturing = true
            receivingAudio = true
            level = 0.5
        default:
            source = .live
            route = .loopback
            loopbackName = "BlackHole 16ch"
            outputName = "FIIO KA13"
            incoming = "Atmos"
            isCapturing = true
            receivingAudio = true
            inputLayout = SpatialDiagnostics.loopbackLayout
            level = 0.5
        }
        if page != "listen-off" { settings.spatial = true }
    }

    // MARK: - Housekeeping

    private func outputDeviceChanged() {
        // The output device changed (e.g. headphones connected): rebuild on the new device.
        if isCapturing {
            // Our own device/rate/output switches right after starting are expected.
            if let started = captureStarted, Date().timeIntervalSince(started) < 1.5,
               output.isRunning, realOutput.map({ output.deviceID == $0 }) ?? true { return }
            // On BlackHole, Sfera's engine is pinned to the real device; only rebuild if that
            // device went away or changed rate (the Mac's default changing is handled above).
            if route == .loopback, let out = realOutput, AudioDevices.all().contains(out),
               abs(AudioDevices.nominalRate(out) - surround.sampleRate) < 0.5,
               output.isRunning, output.deviceID == out { return }
            SferaLog.write("output device changed; restarting")
            restartCapture()
        } else if let item {
            startItem(item, resume: false)
        }
    }

    @ObservationIgnored private var lastStatusLog = Date.distantPast
    @ObservationIgnored private var lastWatchdogRestart = Date.distantPast
    @ObservationIgnored private var statusPeakIn: Float = 0
    @ObservationIgnored private var statusPeakOut: Float = 0

    /// Every 5 s while listening: one line saying where the sound is (or isn't).
    private func logStatus(callbacks: Int) {
        if let sp = output.spatializer {
            statusPeakIn = max(statusPeakIn, sp.inputPeak)
            statusPeakOut = max(statusPeakOut, max(sp.outputPeakL, sp.outputPeakR))
        }
        guard Date().timeIntervalSince(lastStatusLog) > 5 else { return }
        lastStatusLog = Date()
        func db(_ x: Float) -> String { x > 0 ? String(format: "%.0f dBFS", 20 * log10(x)) : "silent" }
        let ring = route == .loopback ? surround.ring : capture.ring
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "allowed"
        case .denied: mic = "denied"
        case .restricted: mic = "restricted"
        default: mic = "not asked"
        }
        SferaLog.write("status · \(route) · \(incoming) · in \(db(statusPeakIn)) · out \(db(statusPeakOut)) · \(callbacks) capture callbacks · ring \(ring.available) frames, \(ring.underrunCount) underruns, \(ring.droppedFrames) dropped · engine \(output.isRunning ? "running" : "STOPPED") on \(output.deviceName) · spatial \(settings.spatial) · gain \(settings.outputGainDB) dB · microphone \(mic)")
        statusPeakIn = 0
        statusPeakOut = 0
    }

    private func tick() {
        let peak = output.spatializer.map { max($0.outputPeakL, $0.outputPeakR) } ?? 0
        level = max(peak, level * 0.85)
        guard !previewing || item != nil else { return }

        if Date().timeIntervalSince(lastDeviceScan) > 3 { scanDevices() }
        if wantsCapture, !isCapturing, !awaitingPermission, Date().timeIntervalSince(lastCaptureAttempt) > 2 {
            startCapture()
        }
        if isCapturing {
            let started = captureStarted.map { Date().timeIntervalSince($0) } ?? 0
            let callbacks = route == .loopback ? surround.callbacks : capture.callbacks
            if route == .tap, callbacks == 0, !triedOutputClock, started > 1.2 {
                // A tap-only device may not get a clock on some systems: rebuild it clocked
                // from the output device (mic kept off).
                triedOutputClock = true
                try? capture.start(clockFromOutput: true)
            }
            if (output.spatializer?.inputPeak ?? 0) > 1e-5 { lastAudio = Date() }
            receivingAudio = lastAudio.map { Date().timeIntervalSince($0) < 1.5 } ?? false
            permissionProblem = callbacks == 0 && started > 3
            if route == .loopback, let adaptive = output.spatializer as? AdaptiveSpatializer {
                incoming = AdaptiveSpatializer.describe(activeChannels: adaptive.activeChannels, layout: surround.layout)
            }
            logStatus(callbacks: callbacks)
            if let out = realOutput, started > 1.5, Date().timeIntervalSince(lastWatchdogRestart) > 3,
               !output.isRunning || output.deviceID != out {
                lastWatchdogRestart = Date()
                SferaLog.write("Sfera's output is \(output.isRunning ? "on \(output.deviceName)" : "stopped") instead of \(AudioDevices.name(out)); restarting")
                restartCapture()
            }
        }

        if let item {
            position = Double(item.currentFrame) / item.sampleRate
            isPlayingFile = item.isPlaying
            if let video {
                let output = self.output
                let fallback = max(0, Double(item.currentFrame) / item.sampleRate - output.totalLatency)
                video.follow(playing: item.isPlaying, audibleAt: { output.audibleTime(atHostTime: $0) }, fallbackTime: fallback)
            }
            if item.didFinish {
                if hasVideo { item.seek(to: 0); item.setPlaying(false); isPlayingFile = false }
                else { next() }
            }
        }
    }
}
