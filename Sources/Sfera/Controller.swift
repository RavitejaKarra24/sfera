import AppKit
import AVFoundation
import CoreAudio
import Observation
import SferaCore
import ServiceManagement

/// Listens to everything the Mac plays and spatialises it for headphones.
///
/// - **With BlackHole:** the Mac's output is pointed at BlackHole and Sfera reads all of its
///   channels, so Apple Music's Atmos (a 9.1.6 bed), a film's 5.1 and plain stereo arrive as
///   they are. Your previous output comes back when Sfera stops or quits.
/// - **Without:** a process tap captures every app's stereo mix.
///
/// Event-driven: Core Audio listeners for the default output, the device list and rates.
/// The only timer is a 1 Hz watchdog while listening (and the meters while the panel is open).
///
/// Sessions are built and torn down on a background queue: Core Audio can block for minutes
/// while macOS shows a permission prompt, and the menu bar (and Quit) must keep working.
@MainActor
@Observable
final class Controller {
    enum Route: Equatable { case none, loopback, tap }

    static let blackHoleURL = URL(string: "https://existential.audio/blackhole/")!
    /// BlackHole's slider when a session starts: the middle (−32 dB), so the volume keys
    /// have room both ways.
    static let loopbackStartVolume: Float32 = 0.5

    // MARK: Preferences

    var settings = LiveSettings() {
        didSet {
            session?.update(settings)
            persist()
        }
    }
    var listenOnLaunch = true { didSet { persist() } }
    /// Use BlackHole (when installed) so surround and Atmos keep every channel.
    var useLoopback = true {
        didSet {
            persist()
            if oldValue != useLoopback, wantsOn { restart() }
        }
    }

    // MARK: State

    private(set) var wantsOn = false
    private(set) var route: Route = .none
    private(set) var outputName: String?
    private(set) var loopbackName: String?
    /// What is arriving: "Atmos", "7.1", "5.1", "3.1" or "Stereo".
    private(set) var incoming = "Stereo"
    private(set) var activeChannels: UInt32 = 0
    private(set) var receiving = false
    private(set) var everReceived = false
    private(set) var microphoneDenied = false
    /// You picked a real output while on BlackHole: stay stereo until BlackHole is picked again.
    private(set) var loopbackDeclined = false
    private(set) var awaitingPermission = false
    /// Output level 0…1, only updated while the panel is open.
    private(set) var level: Float = 0
    var errorMessage: String?

    /// The panel is on screen: meters run at 20 Hz; otherwise nothing ticks but the watchdog.
    /// Which page of the panel is showing (UI only, not persisted).
    var panelPage: PanelPage = .main
    enum PanelPage { case main, settings }

    var panelVisible = false { didSet { if oldValue != panelVisible { scheduleTimer() } } }

    @ObservationIgnored private var session: Session?
    /// IO cycles of the running session (probes).
    var ioCycles: Int { session?.callbacks ?? 0 }
    /// The device Sfera is playing to (probes).
    var sessionOutput: AudioDeviceID? { session?.output }
    @ObservationIgnored private var listeners: [Devices.Listener] = []
    @ObservationIgnored private var routeListeners: [Devices.Listener] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCallbacks = 0
    @ObservationIgnored private var stalledTicks = 0
    @ObservationIgnored private var lastAudio = Date.distantPast
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private var restarting = false
    /// Builds and tears down sessions, in order, off the main thread.
    @ObservationIgnored private let routing = DispatchQueue(label: "dev.sfera.routing", qos: .userInitiated)
    /// Bumped by every teardown; a session that finishes opening for an older one is discarded.
    @ObservationIgnored private var generation = 0
    /// A session is being built on `routing`.
    @ObservationIgnored private var opening = false
    @ObservationIgnored private var openingSince = Date.distantPast
    /// The Mac's output changed while a session was opening; re-check once it's open.
    @ObservationIgnored private var outputChangedWhileOpening = false
    /// Opening has taken more than a few seconds (usually a permission prompt).
    private(set) var openingSlow = false
    /// The watchdog stopped a dead session and is waiting to try again.
    private(set) var waitingToRetry = false
    @ObservationIgnored private var nextAttempt = Date.distantPast
    /// Consecutive watchdog restarts without a healthy session in between.
    @ObservationIgnored private var watchdogRestarts = 0
    /// Waits before each watchdog retry; after the last one Sfera stops and says why.
    static let retryDelays: [TimeInterval] = [3, 10, 30]
    @ObservationIgnored private var lastStatusLog = Date.distantPast
    @ObservationIgnored private var persisting = true

    private enum Key {
        static let settings = "listen.settings", autostart = "listen.autostart", loopback = "listen.useLoopback"
        /// Device to hand the Mac's output back to (also after a crash).
        static let restore = "listen.restoreOutputUID"
        static let lastOutput = "listen.outputUID"
    }

    init(persisting: Bool = true) {
        self.persisting = persisting
        guard persisting else { return }
        let d = UserDefaults.standard
        if let data = d.data(forKey: Key.settings), let saved = try? JSONDecoder().decode(LiveSettings.self, from: data) {
            settings = saved
        }
        if d.object(forKey: Key.autostart) != nil { listenOnLaunch = d.bool(forKey: Key.autostart) }
        if d.object(forKey: Key.loopback) != nil { useLoopback = d.bool(forKey: Key.loopback) }
    }

    private func persist() {
        guard persisting else { return }
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(settings) { d.set(data, forKey: Key.settings) }
        d.set(listenOnLaunch, forKey: Key.autostart)
        d.set(useLoopback, forKey: Key.loopback)
    }

    /// App launched.
    func launch() {
        loopbackName = Devices.loopback().map(Devices.name)
        Log.write("launch · BlackHole \(loopbackName ?? "not installed") · Mac output \(Devices.defaultOutput().map(Devices.name) ?? "none")")
        listeners = [
            Devices.onDefaultOutputChange { [weak self] in Task { @MainActor in self?.defaultOutputChanged() } },
            Devices.onDeviceListChange { [weak self] in Task { @MainActor in self?.deviceListChanged() } },
        ].compactMap { $0 }
        if listenOnLaunch { start() } else { restoreMacOutput() }   // e.g. after a crash on BlackHole
    }

    /// App is quitting: hand the Mac's output back, and give the session up to 2 s to close.
    func shutdown() {
        stop()
        let closed = DispatchSemaphore(value: 0)
        routing.async { closed.signal() }
        _ = closed.wait(timeout: .now() + 2)
    }

    // MARK: - Commands

    func setOn(_ on: Bool) {
        watchdogRestarts = 0
        on ? start() : stop()
    }

    func toggleSpatial() { settings.spatial.toggle() }

    func resetTuning() {
        let spatial = settings.spatial, room = settings.renderMode
        settings = LiveSettings()
        settings.spatial = spatial
        settings.renderMode = room
    }

    // MARK: - What the panel shows

    /// Big line: what is arriving.
    var headline: String {
        guard wantsOn else { return "Off" }
        guard route != .none else { return awaitingPermission ? "Allow access" : "Starting…" }
        guard receiving else { return "Ready" }
        return incoming
    }

    /// One short line under it.
    var detail: String {
        guard wantsOn else { return "Turn on to spatialise everything you play" }
        guard route != .none else {
            if awaitingPermission { return "macOS counts BlackHole as a microphone. Nothing is recorded." }
            if waitingToRetry { return "Audio stopped on \(outputName ?? "your output") · trying again" }
            if openingSlow { return "Waiting for macOS · if a permission prompt is open, answer it" }
            return "Connecting to your output…"
        }
        if !receiving {
            if route == .tap, !everReceived, Date().timeIntervalSince(startedAt) > 8 {
                return "No sound yet? Allow Sfera under Privacy & Security › Screen & System Audio Recording"
            }
            return "Play something in any app"
        }
        let what = incoming == "Stereo" ? (settings.upmix.generateLFE ? "Upmixed to 7.1.4" : "Upmixed to 7.0.4") : (incoming == "Atmos" ? "9.1.6 bed" : "\(incoming) bed")
        return settings.spatial ? "\(what) · rendered for headphones" : "Original · loudness-matched"
    }

    /// Where the sound goes, or why it's stereo only.
    var routeNote: String? {
        guard route != .none else { return nil }
        switch route {
        case .loopback: return "\(loopbackName ?? "BlackHole") → \(outputName ?? "output")"
        case .tap:
            if loopbackName == nil { return "Stereo only · install BlackHole 16ch for Atmos and surround" }
            if !useLoopback { return "Stereo only · BlackHole is off in Settings" }
            if loopbackDeclined { return "Stereo to \(outputName ?? "your output") · pick \(loopbackName ?? "BlackHole") in Sound for surround" }
            if microphoneDenied { return "Stereo only · allow Sfera under Privacy & Security › Microphone for surround" }
            return "Stereo → \(outputName ?? "output")"
        case .none: return nil
        }
    }

    var routeNeedsAttention: Bool {
        route == .tap && (loopbackName == nil || microphoneDenied || loopbackDeclined)
    }

    // MARK: - Routing

    func start() {
        wantsOn = true
        errorMessage = nil
        waitingToRetry = false
        loopbackName = Devices.loopback().map(Devices.name)
        if useLoopback, !loopbackDeclined, let loop = Devices.loopback() {
            startLoopback(loop)
        } else {
            startTap()
        }
        scheduleTimer()
    }

    func stop() {
        wantsOn = false
        loopbackDeclined = false
        waitingToRetry = false
        watchdogRestarts = 0
        teardown()
        restoreMacOutput()
        scheduleTimer()
    }

    private func restart() {
        restarting = true
        defer { restarting = false }
        teardown()
        start()
    }

    private func teardown() {
        generation += 1
        opening = false
        openingSlow = false
        if let old = session {
            session = nil
            routing.async { old.stop() }
        }
        routeListeners = []
        route = .none
        receiving = false
        everReceived = false
        activeChannels = 0
        level = 0
    }

    /// Surround: the Mac plays into BlackHole; Sfera reads every channel and plays the
    /// binaural result to your headphones.
    private func startLoopback(_ loop: AudioDeviceID) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            awaitingPermission = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.awaitingPermission = false
                    if self.wantsOn, self.session == nil { self.start() }
                }
            }
            return
        case .denied, .restricted:
            microphoneDenied = true
            Log.write("microphone permission denied; BlackHole can't be read, using stereo")
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
        if let uid = Devices.uid(out) {
            UserDefaults.standard.set(uid, forKey: Key.lastOutput)
            UserDefaults.standard.set(uid, forKey: Key.restore)
        }
        if Devices.defaultOutput() != loop { Devices.setDefaultOutput(loop) }
        open(.loopback(loop, output: out, setVolume: !restarting))
    }

    /// Stereo: tap every app except Sfera and play to the real output.
    private func startTap() {
        restoreMacOutput()
        let loop = Devices.loopback()
        let target = Devices.defaultOutput().flatMap { Devices.isLoopback($0) ? nil : $0 }
            ?? chooseRealOutput(excluding: loop ?? AudioDeviceID(kAudioObjectUnknown))
        guard let target else {
            errorMessage = "Sfera couldn't find headphones or speakers to play to."
            wantsOn = false
            return
        }
        if Devices.defaultOutput() != target { Devices.setDefaultOutput(target) }
        open(.tap(output: target))
    }

    private enum Opening: Sendable {
        case loopback(AudioDeviceID, output: AudioDeviceID, setVolume: Bool)
        case tap(output: AudioDeviceID)
    }

    /// Builds the session on `routing`, then finishes on the main actor.
    private func open(_ what: Opening) {
        generation += 1
        let generation = self.generation
        opening = true
        openingSince = Date()
        outputChangedWhileOpening = false
        let settings = self.settings
        routing.async { [weak self] in
            let result = Result<Session, any Error> {
                switch what {
                case .loopback(let loop, let out, _): try Session(source: .loopback(loop), output: out, settings: settings)
                case .tap(let out): try Session(source: .tap, output: out, settings: settings)
                }
            }
            Task { @MainActor in self?.opened(what, result, generation: generation) }
        }
    }

    private func opened(_ what: Opening, _ result: Result<Session, any Error>, generation: Int) {
        guard generation == self.generation, wantsOn else {
            // Stopped or rerouted while this one was opening.
            if case .success(let stale) = result { routing.async { stale.stop() } }
            return
        }
        opening = false
        openingSlow = false
        switch (what, result) {
        case (.loopback(_, let out, _), .failure(let error)):
            Log.write("BlackHole route failed (\(Devices.name(out))): \(error.localizedDescription); falling back to stereo")
            startTap()
        case (.tap, .failure(let error)):
            Log.write("tap route failed: \(error.localizedDescription)")
            errorMessage = "Sfera couldn't start: \(error.localizedDescription) Allow Sfera under Privacy & Security › Screen & System Audio Recording."
            wantsOn = false
            scheduleTimer()
        case (.loopback(let loop, let out, let setVolume), .success(let session)):
            self.session = session
            session.update(settings)
            if setVolume { Devices.setVolume(Self.loopbackStartVolume, unmute: loop) }
            route = .loopback
            began(output: out)
            routeListeners += [
                Devices.onRateChange(loop) { [weak self] in Task { @MainActor in self?.rateChanged() } },
            ].compactMap { $0 }
            Log.write(String(format: "BlackHole route: %@ → %@ at %.0f Hz, %d channels",
                             Devices.name(loop), Devices.name(out), session.sampleRate, session.channels))
            if outputChangedWhileOpening { defaultOutputChanged() }
        case (.tap(let target), .success(let session)):
            self.session = session
            session.update(settings)
            route = .tap
            began(output: target)
            Log.write("tap route → \(Devices.name(target)) at \(Int(session.sampleRate)) Hz")
            if outputChangedWhileOpening { defaultOutputChanged() }
        }
    }

    private func began(output: AudioDeviceID) {
        outputName = Devices.name(output)
        startedAt = Date()
        lastCallbacks = 0
        stalledTicks = 0
        routeListeners += [
            Devices.onRateChange(output) { [weak self] in Task { @MainActor in self?.rateChanged() } },
            Devices.onAliveChange(output) { [weak self] in Task { @MainActor in self?.deviceListChanged() } },
        ].compactMap { $0 }
    }

    /// The real device to play to: the current default unless it's the loopback, else the
    /// one used last time, else the best physical output.
    private func chooseRealOutput(excluding loop: AudioDeviceID) -> AudioDeviceID? {
        if let current = Devices.defaultOutput(), current != loop, Devices.isPhysicalOutput(current) { return current }
        for key in [Key.lastOutput, Key.restore] {
            if let uid = UserDefaults.standard.string(forKey: key), let d = Devices.device(uid: uid),
               Devices.isPhysicalOutput(d) { return d }
        }
        let outputs = Devices.physicalOutputs()
        for transport in [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
                          kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeBuiltIn] {
            if let d = outputs.first(where: { Devices.transport($0) == transport }) { return d }
        }
        return outputs.first
    }

    /// Hands the Mac's output back to the real device if Sfera left it on the loopback.
    private func restoreMacOutput() {
        let d = UserDefaults.standard
        guard let uid = d.string(forKey: Key.restore) else { return }
        if let current = Devices.defaultOutput(), Devices.isLoopback(current), let device = Devices.device(uid: uid) {
            Devices.setDefaultOutput(device)
        }
        d.removeObject(forKey: Key.restore)
    }

    // MARK: - Events

    /// The Mac's Sound menu is the switch while Sfera runs:
    /// - a real device chosen while on BlackHole → stereo to it, the output stays where you put it;
    /// - BlackHole chosen while on stereo → surround again;
    /// - on stereo, another real device → follow it.
    private func defaultOutputChanged() {
        if opening { outputChangedWhileOpening = true; return }
        guard wantsOn, let session, let now = Devices.defaultOutput() else { return }
        let nowIsLoopback = Devices.isLoopback(now)
        switch route {
        case .loopback:
            guard case .loopback(let loop) = session.source, now != loop, !nowIsLoopback, Devices.isPhysicalOutput(now) else { return }
            Log.write("you chose \(Devices.name(now)) as the Mac's output; leaving BlackHole, stereo only")
            if let uid = Devices.uid(now) { UserDefaults.standard.set(uid, forKey: Key.lastOutput) }
            UserDefaults.standard.removeObject(forKey: Key.restore)
            loopbackDeclined = true
            restart()
        case .tap:
            if nowIsLoopback {
                guard useLoopback else { return }
                Log.write("you chose \(Devices.name(now)); surround on")
                loopbackDeclined = false
                restart()
            } else if now != session.output, Devices.isPhysicalOutput(now) {
                restart()
            }
        case .none:
            return
        }
    }

    /// Headphones plugged/unplugged, BlackHole installed/removed.
    private func deviceListChanged() {
        loopbackName = Devices.loopback().map(Devices.name)
        guard wantsOn else { return }
        guard let session else {
            if !opening, !waitingToRetry { start() }
            return
        }
        if !Devices.all().contains(session.output) || !Devices.isAlive(session.output) {
            Log.write("output device went away; restarting")
            restart()
        } else if route == .tap, useLoopback, !loopbackDeclined, !microphoneDenied, Devices.loopback() != nil {
            Log.write("BlackHole appeared; switching to surround")
            restart()
        }
    }

    /// A player switched BlackHole's rate (a 44.1 or 96 kHz track), or the DAC's rate changed.
    private func rateChanged() {
        guard let session else { return }
        var rates = [Devices.nominalRate(session.output)]
        if case .loopback(let loop) = session.source { rates.append(Devices.nominalRate(loop)) }
        if rates.contains(where: { abs($0 - session.sampleRate) > 0.5 }) {
            Log.write("sample rate changed (\(rates.map { Int($0) })); restarting")
            restart()
        }
    }

    // MARK: - Timer

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard wantsOn else { level = 0; return }
        let interval = panelVisible ? 1.0 / 20 : 1.0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = panelVisible ? 0.01 : 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        guard wantsOn else { return }
        guard let session else {
            if opening {
                let slow = Date().timeIntervalSince(openingSince) > 5
                if slow != openingSlow { openingSlow = slow }
                return
            }
            // Retry a failed start every few seconds (e.g. right after a device change), or
            // after the watchdog's back-off.
            if !awaitingPermission, Date() >= nextAttempt {
                nextAttempt = Date().addingTimeInterval(3)
                start()
            }
            return
        }
        let sp = session.spatializer
        let peak = sp.inputPeak
        if peak > 1e-5 { lastAudio = Date(); everReceived = true }
        let nowReceiving = Date().timeIntervalSince(lastAudio) < 1.5
        if nowReceiving != receiving { receiving = nowReceiving }
        let mask = sp.activeChannels
        if mask != activeChannels { activeChannels = mask }
        let kind = sp.incoming
        if kind != incoming { incoming = kind }
        if panelVisible {
            let out = sp.outputPeak
            level = max(out, level * 0.82)
        }

        // Watchdog: the IOProc stopped (device died or was reconfigured under us).
        let now = Date()
        if now.timeIntervalSince(lastStatusLog) >= 1 {
            lastStatusLog = now
            let callbacks = session.callbacks
            stalledTicks = callbacks == lastCallbacks ? stalledTicks + 1 : 0
            lastCallbacks = callbacks
            if stalledTicks == 0, now.timeIntervalSince(startedAt) > 10 { watchdogRestarts = 0 }
            if stalledTicks >= 3, now.timeIntervalSince(startedAt) > 3 { audioStopped(neverStarted: callbacks == 0) }
        }
    }

    /// The IOProc stopped (or never ran). Back off between retries instead of rebuilding the
    /// route every few seconds forever, and after the last retry stop and say why.
    private func audioStopped(neverStarted: Bool) {
        let name = outputName ?? "output"
        let wasTap = route == .tap
        watchdogRestarts += 1
        teardown()
        // Let the Mac play directly meanwhile (it's silent while left on BlackHole).
        restoreMacOutput()
        guard watchdogRestarts <= Self.retryDelays.count else {
            Log.write("audio stopped on \(name) again\(neverStarted ? " (no audio ever arrived)" : ""); giving up after \(Self.retryDelays.count) retries")
            stop()
            errorMessage = wasTap && neverStarted
                ? "macOS isn't sending system audio to Sfera. If you just allowed it under Privacy & Security, quit and reopen Sfera."
                : "Audio stopped on \(name) and didn't come back. Turn Sfera on to try again."
            return
        }
        let delay = Self.retryDelays[watchdogRestarts - 1]
        Log.write("audio stopped on \(name)\(neverStarted ? " (no audio ever arrived)" : ""); retry \(watchdogRestarts) of \(Self.retryDelays.count) in \(Int(delay)) s")
        nextAttempt = Date().addingTimeInterval(delay)
        waitingToRetry = true
    }

    // MARK: - Login item

    /// Only meaningful for the bundled app.
    var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard oldValue != openAtLogin, persisting else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "Couldn't change Open at Login: \(error.localizedDescription)"
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    // MARK: - Previews (snapshots)

    func preview(_ page: String) {
        wantsOn = page != "off"
        loopbackName = "BlackHole 16ch"
        outputName = "FIIO KA13"
        route = page == "stereo-tap" ? .tap : .loopback
        receiving = page != "off"
        everReceived = receiving
        switch page {
        case "film": incoming = "5.1"; activeChannels = 0b111111
        case "stereo", "stereo-tap": incoming = "Stereo"; activeChannels = 0b11
        default: incoming = "Atmos"; activeChannels = 0xFFFF
        }
        if page == "off" { route = .none }
        if page == "stereo-tap" { loopbackName = nil }
        if page == "original" { settings.spatial = false }
        level = page == "off" ? 0 : 0.42
    }
}
