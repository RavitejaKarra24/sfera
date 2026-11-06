import AppKit
import AVFoundation
import CoreAudio
import SferaCore
import SwiftUI

/// Headless checks (`Sfera --<probe>`), run from Terminal or Scripts/check.sh.
enum Probe {
    static func handleArguments() -> Bool {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let path = value("--snapshot") {
            MainActor.assumeIsolated { snapshot(path: path, page: value("--page") ?? "atmos") }
            return true
        }
        if args.contains("--surround-probe") { surroundProbe(); return true }
        if args.contains("--tap-probe") { tapProbe(); return true }
        if args.contains("--route-probe") { MainActor.assumeIsolated { routeProbe() }; return true }
        if let seconds = value("--watch-probe") { MainActor.assumeIsolated { watchProbe(seconds: Double(seconds) ?? 20) }; return true }
        if let seconds = value("--cpu-probe") { cpuProbe(seconds: Double(seconds) ?? 10); return true }
        return false
    }

    // MARK: Snapshot

    @MainActor
    static func snapshot(path: String, page: String) {
        let model = Controller(persisting: false)
        model.preview(page)
        model.panelPage = page.hasPrefix("settings") ? .settings : .main
        if CommandLine.arguments.contains("--window") { windowSnapshot(model: model, path: path); return }
        Panel.snapshotting = true
        let view = Panel(model: model)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("snapshot: render failed"); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("snapshot: \(error)"); exit(1) }
        print("snapshot: \(path) (\(Int(image.size.width))×\(Int(image.size.height)) pt)")
    }

    /// Renders the panel exactly as the popover hosts it (real AppKit views, scroll views
    /// included) in an off-screen window.
    @MainActor
    static func windowSnapshot(model: Controller, path: String) {
        let host = NSHostingController(rootView: Panel(model: model))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let view = host.view
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("snapshot: failed"); exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("snapshot (window): \(path) (\(Int(view.bounds.width))×\(Int(view.bounds.height)) pt)")
    }

    // MARK: BlackHole round trip

    /// Plays 16 tagged tones into BlackHole, runs a real session (inaudible: −90 dB) and checks
    /// that every channel arrives in order and the content is recognised as Atmos.
    static func surroundProbe() {
        guard let loop = Devices.loopback() else { print("surround-probe: no BlackHole installed"); exit(2) }
        guard let out = Devices.defaultOutput().flatMap({ Devices.isPhysicalOutput($0) ? $0 : nil })
                ?? Devices.physicalOutputs().first else { print("surround-probe: no output device"); exit(2) }
        let permission: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = "allowed"
        case .denied: permission = "denied"
        case .restricted: permission = "restricted"
        default: permission = "not asked yet"
        }
        print("surround-probe: \(Devices.name(loop)) → \(Devices.name(out)) · microphone permission: \(permission)")

        // Sfera parks BlackHole's slider at −32 dB; the tones must arrive at full level.
        let loopVolume = Devices.volumeScalar(loop)
        Devices.setVolume(1, unmute: loop)
        var settings = LiveSettings()
        settings.outputGainDB = -90
        let channels = min(16, Devices.channels(loop, scope: kAudioObjectPropertyScopeInput))
        let recorder = ProbeRecorder(channels: channels, frames: 48000 * 4)
        let session: Session
        do { session = try Session(source: .loopback(loop), output: out, settings: settings, probe: recorder) } catch {
            if let loopVolume { Devices.setVolume(loopVolume, unmute: loop) }
            print("surround-probe: FAILED to start · \(error.localizedDescription)"); exit(1)
        }
        let rate = session.sampleRate
        let frequencies = (0..<channels).map { 220.0 + 110.0 * Double($0) }

        // Writer: an IOProc on BlackHole's output side (what a player would do).
        let phase = UnsafeMutablePointer<Double>.allocate(capacity: channels)
        phase.initialize(repeating: 0, count: channels)
        var writer: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&writer, loop, DispatchQueue(label: "probe.write")) { _, _, _, output, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard let buffer = buffers.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let stride = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (stride * 4)
            for f in 0..<frames {
                for c in 0..<stride {
                    guard c < channels else { data[f * stride + c] = 0; continue }
                    data[f * stride + c] = Float(0.1 * sin(phase[c]))
                    phase[c] += 2 * .pi * frequencies[c] / rate
                }
            }
        }
        guard status == noErr, let writer, AudioDeviceStart(loop, writer) == noErr else {
            if let loopVolume { Devices.setVolume(loopVolume, unmute: loop) }
            print("surround-probe: couldn't play into \(Devices.name(loop)) (\(status))"); exit(1)
        }
        let started = Date()
        while recorder.frames < recorder.capacity, Date().timeIntervalSince(started) < 6 { Thread.sleep(forTimeInterval: 0.05) }
        let kind = session.spatializer.incoming
        let outPeak = session.spatializer.outputPeak
        let callbacks = session.callbacks
        AudioDeviceStop(loop, writer)
        AudioDeviceDestroyIOProcID(loop, writer)
        session.stop()
        if let loopVolume { Devices.setVolume(loopVolume, unmute: loop) }

        // Last second of the recording: which tone dominates each channel (Goertzel)?
        let n = recorder.frames
        let range = max(0, n - Int(rate))..<n
        func power(_ x: UnsafeMutablePointer<Float>, _ f: Double) -> Double {
            let k = 2 * cos(2 * .pi * f / rate)
            var s1 = 0.0, s2 = 0.0
            for i in range { let s0 = Double(x[i]) + k * s1 - s2; s2 = s1; s1 = s0 }
            return s1 * s1 + s2 * s2 - k * s1 * s2
        }
        var wrong: [String] = []
        var peak: Float = 0
        for c in 0..<channels {
            for i in range { peak = max(peak, abs(recorder.data[c][i])) }
            let powers = frequencies.map { power(recorder.data[c], $0) }
            let best = powers.indices.max { powers[$0] < powers[$1] } ?? -1
            if best != c { wrong.append("ch\(c + 1)→\(best + 1)") }
        }
        print(String(format: "surround-probe: %d channels at %.0f Hz · %d IO cycles · %d frames recorded · input peak %.3f · output peak %.1f dBFS (−90 dB trim)",
                     channels, rate, callbacks, n, peak, outPeak > 0 ? 20 * log10(outPeak) : -999))
        if peak < 0.01 {
            print(permission == "allowed"
                  ? "surround-probe: FAILED · silence. Run from Terminal; restricted shells read BlackHole as silent."
                  : "surround-probe: FAILED · silence. Allow Terminal (or Sfera) under Privacy & Security › Microphone.")
            exit(1)
        }
        if !wrong.isEmpty { print("surround-probe: FAILED · channel order: \(wrong.joined(separator: ", "))"); exit(1) }
        print("surround-probe: every channel arrived in order · detected \(kind) · rendered in the IO cycle")
        exit(kind == "Atmos" && outPeak > 0 ? 0 : 1)
    }

    // MARK: Routing

    /// Turns Sfera on as the app would (audible, your saved settings untouched) and prints
    /// what the route is doing twice a second: which device the Mac plays to, what Sfera
    /// reads and plays to, whether the IOProc runs and whether sound arrives.
    @MainActor
    static func watchProbe(seconds: Double) {
        let model = Controller(persisting: false)
        func rate(_ d: AudioDeviceID?) -> String { d.map { "\(Int(Devices.nominalRate($0)))" } ?? "-" }
        let loop = Devices.loopback()
        model.launch()
        let start = Date()
        var cycles = 0
        while Date().timeIntervalSince(start) < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let mac = Devices.defaultOutput()
            let io = model.ioCycles
            print(String(format: "%5.1fs  Mac→%@ (%@ Hz) · BH %@ Hz · Sfera %@→%@ · IO %@ · in %.4f · %@ — %@",
                         Date().timeIntervalSince(start), mac.map(Devices.name) ?? "none", rate(mac), rate(loop),
                         "\(model.route)", model.sessionOutput.map(Devices.name) ?? "nothing",
                         io > cycles ? "+\(io - cycles)" : "STOPPED", model.sessionInputPeak, model.headline, model.detail))
            fflush(stdout)
            cycles = io
        }
        model.shutdown()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        print("watch-probe: done · Mac → \(Devices.defaultOutput().map(Devices.name) ?? "none")")
    }

    /// Drives the real Controller (output at −90 dB) through the Sound-menu cases:
    /// start → pick your headphones → pick BlackHole → stop. Restores the Mac's output and
    /// BlackHole's volume afterwards.
    @MainActor
    static func routeProbe() {
        guard let loop = Devices.loopback() else { print("route-probe: no BlackHole installed"); exit(2) }
        guard let original = Devices.defaultOutput() else { print("route-probe: no default output"); exit(2) }
        let real = Devices.isPhysicalOutput(original) ? original : Devices.physicalOutputs().first
        guard let real else { print("route-probe: no output device"); exit(2) }
        let loopVolume = Devices.volumeScalar(loop)
        func restore() {
            Devices.setDefaultOutput(original)
            if let loopVolume { Devices.setVolume(loopVolume, unmute: loop) }
        }

        func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        var failures = 0
        func check(_ step: String, _ ok: Bool, _ detail: String) {
            print("  \(ok ? "✓" : "✗") \(step.padding(toLength: 34, withPad: " ", startingAt: 0)) \(detail)")
            if !ok { failures += 1 }
        }
        let model = Controller(persisting: false)
        model.settings.outputGainDB = -90
        print("route-probe: \(Devices.name(loop)) · your output \(Devices.name(real)) · Sfera at −90 dB")

        func state() -> String {
            let mac = Devices.defaultOutput().map(Devices.name) ?? "none"
            let to = model.sessionOutput.map(Devices.name) ?? "nothing"
            let cycles = model.ioCycles
            pump(0.5)
            return "Mac → \(mac) · Sfera \(model.route) → \(to) · \(model.ioCycles > cycles ? "IO running" : "IO STOPPED")"
        }
        func running() -> Bool { let c = model.ioCycles; pump(0.3); return model.ioCycles > c }

        // Start from a real output, as a listener would (the Mac may have been left on BlackHole).
        if Devices.defaultOutput() != real { Devices.setDefaultOutput(real); pump(0.3) }
        model.launch()
        pump(1.5)
        var s = state()
        check("start", Devices.defaultOutput() == loop && model.route == .loopback && model.sessionOutput == real && running(), s)
        check("BlackHole volume set to the middle", abs((Devices.volumeScalar(loop) ?? 0) - Controller.loopbackStartVolume) < 0.01,
              String(format: "%.2f", Devices.volumeScalar(loop) ?? -1))

        Devices.setDefaultOutput(real)
        pump(1.5)
        s = state()
        let tapRunning = running()
        check("pick \(Devices.name(real)) in Sound", Devices.defaultOutput() == real && model.route == .tap && model.sessionOutput == real && tapRunning,
              s + (tapRunning ? "" : " (tap IO needs Screen & System Audio Recording; restricted shells get none)"))

        Devices.setDefaultOutput(loop)
        pump(1.5)
        s = state()
        check("pick \(Devices.name(loop)) again", Devices.defaultOutput() == loop && model.route == .loopback && model.sessionOutput == real && running(), s)

        model.stop()
        pump(0.5)
        check("stop", Devices.defaultOutput() == real && model.route == .none,
              "Mac → \(Devices.defaultOutput().map(Devices.name) ?? "none")")

        restore()
        print(failures == 0 ? "route-probe: all steps passed" : "route-probe: \(failures) step(s) FAILED (see ~/Library/Logs/Sfera.log)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: System tap

    /// Starts the no-BlackHole route (process tap → headphones) at −90 dB for two seconds.
    /// Play something while it runs to see a non-zero input peak.
    static func tapProbe() {
        guard let out = Devices.defaultOutput().flatMap({ Devices.isPhysicalOutput($0) ? $0 : nil })
                ?? Devices.physicalOutputs().first else { print("tap-probe: no output device"); exit(2) }
        var settings = LiveSettings()
        settings.outputGainDB = -90
        let recorder = ProbeRecorder(channels: 2, frames: 48000 * 3)
        let session: Session
        do { session = try Session(source: .tap, output: out, settings: settings, probe: recorder) } catch {
            print("tap-probe: FAILED to start · \(error.localizedDescription)"); exit(1)
        }
        Thread.sleep(forTimeInterval: 2)
        let callbacks = session.callbacks, rate = session.sampleRate
        session.stop()
        var peak: Float = 0
        for c in 0..<2 { for i in 0..<recorder.frames { peak = max(peak, abs(recorder.data[c][i])) } }
        print(String(format: "tap-probe: %@ · %.0f Hz · %d IO cycles in 2 s · input peak %.3f%@", Devices.name(out), rate, callbacks, peak,
                     peak == 0 ? " (silent: nothing playing, or audio-capture permission not granted)" : ""))
        exit(callbacks > 0 ? 0 : 1)
    }

    // MARK: CPU

    /// Runs a real BlackHole session (inaudible) for `seconds` while a stereo signal plays into
    /// BlackHole, and reports this process's CPU use.
    static func cpuProbe(seconds: Double) {
        guard let loop = Devices.loopback(), let out = Devices.defaultOutput().flatMap({ Devices.isPhysicalOutput($0) ? $0 : nil })
                ?? Devices.physicalOutputs().first else { print("cpu-probe: needs BlackHole and an output"); exit(2) }
        var settings = LiveSettings()
        settings.outputGainDB = -90
        guard let session = try? Session(source: .loopback(loop), output: out, settings: settings) else {
            print("cpu-probe: couldn't start"); exit(1)
        }
        var phase = 0.0
        let rate = session.sampleRate
        var writer: AudioDeviceIOProcID?
        let silent = CommandLine.arguments.contains("--silent")
        AudioDeviceCreateIOProcIDWithBlock(&writer, loop, DispatchQueue(label: "probe.write")) { _, _, _, output, _ in
            let b = UnsafeMutableAudioBufferListPointer(output)
            guard !silent, let buffer = b.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let stride = Int(buffer.mNumberChannels)
            for f in 0..<Int(buffer.mDataByteSize) / (stride * 4) {
                let x = Float(0.1 * sin(phase)) + Float.random(in: -0.02...0.02)
                data[f * stride] = x
                data[f * stride + 1] = x * 0.7
                phase += 2 * .pi * 440 / rate
            }
        }
        if let writer { AudioDeviceStart(loop, writer) }
        Thread.sleep(forTimeInterval: 1)
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let c0 = cpu(), t0 = Date()
        Thread.sleep(forTimeInterval: seconds)
        let used = cpu() - c0, wall = Date().timeIntervalSince(t0)
        if let writer { AudioDeviceStop(loop, writer); AudioDeviceDestroyIOProcID(loop, writer) }
        print(String(format: "cpu-probe: %@ · %@ · %.2f%% of one core over %.0f s (includes the probe's own tone writer)",
                     silent ? "silence" : "stereo into BlackHole", session.spatializer.incoming, 100 * used / wall, wall))
        session.stop()
    }
}
