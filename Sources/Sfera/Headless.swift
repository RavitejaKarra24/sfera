import AppKit
import AVFoundation
import CoreAudio
import SpatialCore
import SwiftUI

/// Headless verification: renders the app's own views to a PNG and runs end-to-end
/// engine and device checks without a display server or screen capture.
///
///     Sfera --snapshot out.png [--page listen|listen-tip|listen-files|listen-movie|listen-off]
///     Sfera --self-check report.json
///     Sfera --movie-probe       real window + AVPlayer + audio device, measures A/V sync
///     Sfera --surround-probe    real BlackHole round trip, checks all 16 channels
///     Sfera --tap-probe         process-tap capture for 1.5 s
///     Sfera --route-probe       the app's BlackHole routing: start, pick the real output,
///                               pick BlackHole again, stop (output at −90 dB)
@MainActor
enum Headless {
    static func handleLaunchArguments() -> Bool {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        if let path = value("--snapshot") {
            let size = CGSize(width: value("--width").flatMap(Double.init) ?? 400, height: value("--height").flatMap(Double.init) ?? 580)
            snapshot(path: path, page: value("--page") ?? "listen", size: size)
            return true
        }
        if let path = value("--self-check") { selfCheck(path: path); return true }
        if arguments.contains("--movie-probe") { movieProbe(); return true }
        if arguments.contains("--surround-probe") { surroundProbe(); return true }
        if arguments.contains("--tap-probe") { tapProbe(); return true }
        if arguments.contains("--route-probe") { routeProbe(); return true }
        return false
    }

    static func snapshot(path: String, page: String, size: CGSize) {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Representative state; never starts real capture.
        AppEnv.listen.preview(page: page)
        let hosting = NSHostingView(rootView: ListenView()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("snapshot: could not allocate bitmap\n".utf8))
            exit(2)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG encoding failed\n".utf8))
            exit(2)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("snapshot: wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
        exit(0)
    }

    static func selfCheck(path: String) {
        var failures: [String] = []
        // Engine: upmix, transparency, binaural room, live vs offline, A/B loudness, adaptive switching.
        let spatial = SpatialDiagnostics.run(sampleRate: 48000)
        failures.append(contentsOf: spatial.failures)
        // App path: file → AVAudioEngine graph, capture ring buffer.
        let live = liveCheck()
        failures.append(contentsOf: live.failures)
        // Movies: real 5.1 AAC + H.264 file streamed from disk.
        let movie = MovieCheck.run()
        failures.append(contentsOf: movie.failures)

        let report: [String: Any] = [
            "failures": failures,
            "spatial": spatial.metrics,
            "live": live.metrics,
            "movie": movie.metrics,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
            print("self-check: \(failures.isEmpty ? "PASS" : "FAIL") · \(path)")
            failures.forEach { print("  ✗ \($0)") }
            exit(failures.isEmpty ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("self-check: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    /// Listener path end to end: file decode → FilePlayback → AVAudioEngine source node →
    /// LiveSpatializer (offline manual rendering), plus the capture ring buffer under
    /// irregular producer/consumer block sizes.
    static func liveCheck() -> (metrics: [String: Double], failures: [String]) {
        var metrics: [String: Double] = [:]
        var failures: [String] = []
        let rate = 44100.0
        let (left, right) = SpatialDiagnostics.testStereo(seconds: 4, sampleRate: rate)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sfera-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try WaveWriter.write(PlanarAudio(sampleRate: rate, channels: [left, right]), to: url, bitDepth: .pcm24, layout: .stereo)
            let playback = try ListenModel.decode(url: url, renderMode: .mid)
            if playback.layout.speakers != [.l, .r] { failures.append("live: stereo file decoded as \(playback.layout.name)") }
            playback.setPlaying(true)
            let output = LiveOutput()
            let frames = Int(rate * 3)
            let audio = try output.renderOffline(sampleRate: rate, layout: playback.layout, settings: LiveSettings(), frames: frames) { inputs, count in
                playback.read(into: inputs, frames: count)
            }
            let peak = audio.peak()
            metrics["fileGraphPeak"] = Double(peak)
            metrics["fileGraphFramesConsumed"] = Double(playback.currentFrame)
            if !(peak > 0.01 && peak <= 1) { failures.append("live: engine graph output peak \(peak)") }
            if audio.channels.contains(where: { $0.contains { !$0.isFinite } }) { failures.append("live: non-finite output") }
            if abs(playback.currentFrame - frames) > 4096 { failures.append("live: playback consumed \(playback.currentFrame) of \(frames) frames") }
            // The upmix must actually be live: output differs from a plain copy of the input.
            var diff = 0.0
            for i in Int(rate)..<frames { diff = max(diff, Double(abs(audio.channels[0][i] - left[i]))) }
            if diff < 0.01 { failures.append("live: output identical to input (no processing)") }
        } catch {
            failures.append("live: \(error.localizedDescription)")
        }

        // Ring buffer: irregular writes (capture IOProc) and reads (render callback).
        let ring = AudioRingBuffer(channels: 2, capacity: 1 << 14, targetFrames: 1024)
        var source = [Float](repeating: 0, count: 200_000)
        for i in source.indices { source[i] = Float(i % 9973) / 9973 }
        let outL = UnsafeMutablePointer<Float>.allocate(capacity: 4096); defer { outL.deallocate() }
        let outR = UnsafeMutablePointer<Float>.allocate(capacity: 4096); defer { outR.deallocate() }
        var writePos = 0, discontinuities = 0, last: Float = -1, produced = 0
        let writes = [480, 512, 441, 1024, 256]
        let reads = [512, 470, 1024, 300]
        var step = 0
        source.withUnsafeBufferPointer { src in
            while writePos + 1024 < source.count {
                let n = writes[step % writes.count]
                ring.write(left: src.baseAddress!.advanced(by: writePos), right: src.baseAddress!.advanced(by: writePos), frames: n)
                writePos += n
                let m = reads[step % reads.count]
                let got = ring.read(into: [outL, outR], frames: m)
                for i in 0..<got {
                    let v = outL[i]
                    let expected = last < 0 ? v : (Float((Int((last * 9973).rounded()) + 1) % 9973) / 9973)
                    if abs(v - expected) > 1e-4 { discontinuities += 1 }
                    last = v
                }
                produced += got
                step += 1
            }
        }
        metrics["ringFramesDelivered"] = Double(produced)
        metrics["ringDiscontinuities"] = Double(discontinuities)
        metrics["ringUnderruns"] = Double(ring.underrunCount)
        if produced < writePos / 2 { failures.append("ring: delivered only \(produced) of \(writePos) frames") }
        if discontinuities > 2 { failures.append("ring: \(discontinuities) discontinuities") }
        return (metrics, failures)
    }


    /// `Sfera --movie-probe`: plays a generated 5.1 movie through the real listener path
    /// (window, AVPlayer, audio device; output at −90 dB) and measures picture/sound drift.
    static func movieProbe() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sfera-probe-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        do { try MovieCheck.writeMovie(to: url, sampleRate: 48000, seconds: 10) } catch {
            print("movie-probe: couldn't write test movie: \(error.localizedDescription)"); exit(2)
        }
        if let device = AudioDevices.defaultOutput() {
            print(String(format: "movie-probe: output device %u (%@), device+stream latency %.1f ms",
                         device, AudioDevices.uid(device) ?? "?", LiveOutput.outputLatency(of: device) * 1000))
        }
        let listen = AppEnv.listen
        listen.beginProbe()
        listen.addFiles([url])
        func run(_ seconds: Double, label: String) -> [Double] {
            var drifts: [Double] = []
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                guard let p = listen.syncProbe else { continue }
                let drift = (p.video - max(0, p.audible)) * 1000
                print(String(format: "  %@ audio %.3f s · heard %.3f s · picture %.3f s · drift %+.0f ms · latency %.0f ms",
                             label, p.audio, p.audible, p.video, drift, p.latency * 1000))
                drifts.append(drift)
            }
            return drifts
        }
        let playing = run(4, label: "play")
        listen.seek(fraction: 0.6)
        let afterSeek = run(2.5, label: "seek")
        if let error = listen.errorMessage { print("movie-probe: error: \(error)") }
        listen.stopFile()
        func settled(_ d: [Double]) -> Double { d.dropFirst(min(d.count / 2, 4)).map(abs).max() ?? .infinity }
        let a = settled(playing), b = settled(afterSeek)
        print(String(format: "movie-probe: settled drift %.0f ms while playing, %.0f ms after seek", a, b))
        exit(a < 45 && b < 45 ? 0 : 1)
    }


    /// `Sfera --surround-probe`: plays 16 tagged tones into BlackHole's output (directly,
    /// without touching the Mac's sound settings), reads them back through
    /// `SurroundCapture` clocked by the real output device, and checks every channel lands
    /// where it was sent. Then runs the adaptive renderer on it (output at −90 dB).
    /// Runs the real `ListenModel` routing the way you'd use it, with tones in BlackHole
    /// and Sfera's output at −90 dB. Checks that the Mac's output is never left on BlackHole
    /// without Sfera reading it, and that choosing your real output is respected.
    static func routeProbe() {
        guard let loop = AudioDevices.loopbackDevice() else { print("route-probe: no BlackHole installed"); exit(2) }
        guard let original = AudioDevices.defaultOutput() else { print("route-probe: no output device"); exit(2) }
        let model = AppEnv.listen
        model.persistenceEnabled = false
        model.settings.outputGainDB = -90
        model.settings.spatial = true
        var failures: [String] = []
        func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func state() -> String {
            "route \(model.route) · Mac output \(AudioDevices.defaultOutput().map(AudioDevices.name) ?? "none") · Sfera's engine \(model.engineRunning ? "running" : "STOPPED") on \(AudioDevices.name(model.engineDevice)) · \(model.detail)"
        }
        func expect(_ ok: Bool, _ what: String) {
            print("route-probe: \(ok ? "ok  " : "FAIL") \(what) · \(state())")
            if !ok { failures.append(what) }
        }
        let real = AudioDevices.isLoopback(original) ? (AudioDevices.physicalOutputs().first ?? original) : original
        if AudioDevices.isLoopback(original) { AudioDevices.setDefaultOutput(real) }

        // Tones on L, R, C and a height channel, as an Atmos track would send.
        let rate = AudioDevices.nominalRate(loop)
        let phase = UnsafeMutablePointer<Double>.allocate(capacity: 1); phase.initialize(to: 0)
        defer { phase.deallocate() }
        var writer: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&writer, loop, DispatchQueue(label: "probe.tones")) { _, _, _, output, _ in
            guard let b = UnsafeMutableAudioBufferListPointer(output).first, let d = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let stride = Int(b.mNumberChannels), frames = Int(b.mDataByteSize) / (4 * max(1, stride))
            for f in 0..<frames {
                let v = Float(0.2 * sin(phase.pointee)); phase.pointee += 2 * .pi * 330 / max(rate, 1)
                for c in 0..<stride { d[f * stride + c] = [0, 1, 2, 10].contains(c) ? v : 0 }
            }
        }
        if let writer { AudioDeviceStart(loop, writer) }

        model.launch()
        if model.source != .live { model.selectSource(.live) } else if !model.isCapturing { model.startCapture() }
        pump(3)
        expect(model.route == .loopback && AudioDevices.defaultOutput() == loop, "starts on BlackHole")
        expect(abs(AudioDevices.volumeScalar(loop) - ListenModel.loopbackStartVolume) < 0.01 && !AudioDevices.isMuted(loop),
               String(format: "BlackHole slider in the middle (%.0f %%, %.1f dB)", AudioDevices.volumeScalar(loop) * 100, AudioDevices.volumeDB(loop) ?? 0))
        expect(model.receivingAudio && model.incoming == "Atmos", "hears what apps play into BlackHole")
        expect(model.engineRunning && model.engineDevice == real, "Sfera's engine really plays to \(AudioDevices.name(real))")

        AudioDevices.setDefaultOutput(real)          // you pick FIIO KA13 in the menu bar
        pump(3)
        expect(model.route == .tap && AudioDevices.defaultOutput() == real && model.engineRunning && model.engineDevice == real,
               "choosing \(AudioDevices.name(real)) is respected (stereo to it)")

        AudioDevices.setDefaultOutput(loop)          // you pick BlackHole again
        pump(3)
        expect(model.route == .loopback && AudioDevices.defaultOutput() == loop && model.engineRunning && model.engineDevice == real,
               "choosing BlackHole turns surround back on, still playing to \(AudioDevices.name(real))")

        model.stopCapture()
        pump(0.5)
        expect(AudioDevices.defaultOutput() == real, "stopping hands the Mac's output back")
        if let writer { AudioDeviceStop(loop, writer); AudioDeviceDestroyIOProcID(loop, writer) }
        if AudioDevices.defaultOutput() != original, !AudioDevices.isLoopback(original) { AudioDevices.setDefaultOutput(original) }
        print("route-probe: \(failures.isEmpty ? "PASS" : "FAILED · \(failures.joined(separator: "; "))") · log: \(SferaLog.url.path)")
        pump(0.2)
        exit(failures.isEmpty ? 0 : 1)
    }

    static func surroundProbe() {
        guard let loop = AudioDevices.loopbackDevice() else { print("surround-probe: no BlackHole installed"); exit(2) }
        guard let out = AudioDevices.defaultOutput().flatMap({ AudioDevices.isPhysicalOutput($0) ? $0 : nil })
                ?? AudioDevices.physicalOutputs().first else { print("surround-probe: no output device"); exit(2) }
        let permission: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = "allowed"
        case .denied: permission = "denied"
        case .restricted: permission = "restricted"
        default: permission = "not asked yet"
        }
        print("surround-probe: \(AudioDevices.name(loop)) → \(AudioDevices.name(out)) · microphone permission: \(permission)")
        let capture = SurroundCapture()
        do { try capture.start(loopback: loop, output: out) } catch {
            print("surround-probe: FAILED to start · \(error.localizedDescription)"); exit(1)
        }
        let channels = capture.channelCount, rate = capture.sampleRate
        let frequencies = (0..<channels).map { 220.0 + 110.0 * Double($0) }

        // Writer: an IOProc on the loopback's output side.
        let phase = UnsafeMutablePointer<Double>.allocate(capacity: channels)
        phase.initialize(repeating: 0, count: channels)
        defer { phase.deallocate() }
        var writer: AudioDeviceIOProcID?
        let outChannels = AudioDevices.channels(loop, scope: kAudioObjectPropertyScopeOutput)
        let writeQueue = DispatchQueue(label: "probe.write", qos: .userInteractive)
        let direct = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        direct.initialize(repeating: 0, count: 2)
        defer { direct.deallocate() }
        let status = AudioDeviceCreateIOProcIDWithBlock(&writer, loop, writeQueue) { _, input, _, output, _ in
            // Diagnostics: what BlackHole's own input carries (no aggregate involved).
            for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(b.mDataByteSize) / 4 { direct[0] = max(direct[0], abs(d[i])) }
                direct[1] += 1
            }
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard let buffer = buffers.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let stride = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (stride * 4)
            for f in 0..<frames {
                for c in 0..<min(stride, channels) {
                    data[f * stride + c] = Float(0.1 * sin(phase[c]))
                    phase[c] += 2 * .pi * frequencies[c] / rate
                }
                if stride > channels { for c in channels..<stride { data[f * stride + c] = 0 } }
            }
        }
        guard status == noErr, let writer, AudioDeviceStart(loop, writer) == noErr else {
            print("surround-probe: couldn't play into \(AudioDevices.name(loop)) (\(status)), \(outChannels) output channels"); exit(1)
        }
        Thread.sleep(forTimeInterval: 1.5)

        // Read 0.5 s back and find which tone dominates each channel (Goertzel).
        let block = 2048, total = Int(rate * 0.5)
        var captured = [[Float]](repeating: [], count: channels)
        let buffers = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        var spins = 0
        while captured[0].count < total, spins < 400 {
            let got = capture.ring.read(into: buffers, frames: block)
            for c in 0..<channels { captured[c] += UnsafeBufferPointer(start: buffers[c], count: got) }
            if got < block { Thread.sleep(forTimeInterval: 0.01) }
            spins += 1
        }
        AudioDeviceStop(loop, writer)
        AudioDeviceDestroyIOProcID(loop, writer)
        buffers.forEach { $0.deallocate() }
        let callbacks = capture.callbacks
        capture.stop()

        func power(_ x: [Float], _ f: Double) -> Double {
            let k = 2 * cos(2 * .pi * f / rate)
            var s1 = 0.0, s2 = 0.0
            for v in x { let s0 = Double(v) + k * s1 - s2; s2 = s1; s1 = s0 }
            return s1 * s1 + s2 * s2 - k * s1 * s2
        }
        var wrong: [String] = []
        var peak: Float = 0
        for c in 0..<channels {
            peak = max(peak, captured[c].map(abs).max() ?? 0)
            let powers = frequencies.map { power(captured[c], $0) }
            let best = powers.indices.max { powers[$0] < powers[$1] } ?? -1
            if best != c { wrong.append("ch\(c + 1)→\(best + 1)") }
        }
        print(String(format: "surround-probe: %d channels at %.0f Hz · %d callbacks · %d frames read · peak %.3f (BlackHole input read directly: peak %.3f over %.0f buffers)",
                     channels, rate, callbacks, captured[0].count, peak, direct[0], direct[1]))
        if peak < 0.01 {
            if permission == "allowed" {
                print("surround-probe: FAILED · silence. Nothing written into \(AudioDevices.name(loop)) comes back out of it, even read directly. Restricted shells and sandboxes see BlackHole as silent; run this from Terminal. If it is still silent there, reinstall BlackHole.")
            } else {
                print("surround-probe: FAILED · silence. Allow this app (or Terminal) under System Settings › Privacy & Security › Microphone; macOS zeroes BlackHole's input until then (permission here: \(permission)).")
            }
            exit(1)
        }
        if !wrong.isEmpty { print("surround-probe: FAILED · channel order: \(wrong.joined(separator: ", "))"); exit(1) }

        // The adaptive renderer sees all 16 channels as surround.
        let adaptive = AdaptiveSpatializer(sampleRate: rate, inputLayout: capture.layout, maxFrames: block)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: block), r = UnsafeMutablePointer<Float>.allocate(capacity: block)
        var offset = 0
        while offset + block <= captured[0].count {
            for c in 0..<channels { captured[c].withUnsafeBufferPointer { adaptive.inputs[c].update(from: $0.baseAddress! + offset, count: block) } }
            adaptive.process(frames: block, outL: l, outR: r)
            offset += block
        }
        l.deallocate(); r.deallocate()
        let kind = AdaptiveSpatializer.describe(activeChannels: adaptive.activeChannels, layout: capture.layout)
        print("surround-probe: every channel arrived in order · detected \(kind) · surround path \(adaptive.surroundActive ? "on" : "off")")
        exit(adaptive.surroundActive && kind == "Atmos" ? 0 : 1)
    }

    /// `Sfera --tap-probe [--clock-output]`: process-tap capture for 1.5 s.
    static func tapProbe() {
        let capture = SystemAudioCapture()
        let clock = CommandLine.arguments.contains("--clock-output")
        do {
            try capture.start(clockFromOutput: clock)
            let out = [UnsafeMutablePointer<Float>.allocate(capacity: 4096), UnsafeMutablePointer<Float>.allocate(capacity: 4096)]
            var peak: Float = 0
            let end = Date().addingTimeInterval(1.5)
            while Date() < end {
                Thread.sleep(forTimeInterval: 0.05)
                let got = capture.ring.read(into: out, frames: 2048)
                for i in 0..<got { peak = max(peak, abs(out[0][i]), abs(out[1][i])) }
            }
            print("tap-probe (\(clock ? "output-clocked" : "tap-only")): OK · \(capture.sampleRate) Hz · \(capture.callbacks) callbacks · ring \(capture.ring.available) frames · peak \(peak)")
            capture.stop()
            out.forEach { $0.deallocate() }
            exit(0)
        } catch {
            print("tap-probe: FAILED · \(error.localizedDescription)")
            exit(1)
        }
    }
}
