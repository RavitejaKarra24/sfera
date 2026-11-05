import Foundation

/// Measured checks for the stereo → spatial upmix and the binaural room.
/// Shared by the unit tests and the app's headless `--self-check`.
public enum SpatialDiagnostics {
    public struct Report: Sendable {
        public var metrics: [String: Double] = [:]
        public var failures: [String] = []
    }

    public static func run(sampleRate: Double = 48000) -> Report {
        var report = Report()
        checkUpmix(&report, sampleRate: sampleRate)
        checkTransparency(&report, sampleRate: sampleRate)
        checkBinauralRoom(&report, sampleRate: sampleRate)
        checkLiveEngine(&report, sampleRate: sampleRate)
        checkAdaptive(&report, sampleRate: sampleRate)
        return report
    }

    // MARK: Upmix

    /// Synthetic mix: a centre-panned 440 Hz "vocal", a hard-left 1.5 kHz "guitar",
    /// and uncorrelated L/R noise standing in for reverb/ambience.
    public static func testStereo(seconds: Double = 6, sampleRate: Double = 48000) -> (left: [Float], right: [Float]) {
        let frames = Int(seconds * sampleRate)
        var rng = SplitMix64(seed: 0xA11CE)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let vocal = Float(0.25 * sin(2 * .pi * 440 * t))
            let guitar = Float(0.2 * sin(2 * .pi * 1500 * t))
            let nL = Float(rng.nextUniform() * 2 - 1) * 0.06
            let nR = Float(rng.nextUniform() * 2 - 1) * 0.06
            left[i] = vocal + guitar + nL
            right[i] = vocal + nR
        }
        return (left, right)
    }

    static func checkUpmix(_ report: inout Report, sampleRate: Double) {
        let (left, right) = testStereo(sampleRate: sampleRate)
        let started = Date()
        let out = Upmixer.upmix(left: left, right: right, sampleRate: sampleRate)
        report.metrics["upmixSecondsPer6s"] = Date().timeIntervalSince(started)
        var full = UpmixSettings()
        full.centerExtraction = 1
        let focused = Upmixer.upmix(left: left, right: right, sampleRate: sampleRate, settings: full)

        let expected: [Speaker] = [.l, .r, .c, .lss, .rss, .lrs, .rrs, .ltf, .rtf, .ltr, .rtr]
        for speaker in expected where out[speaker] == nil {
            report.failures.append("upmix missing \(speaker.label)")
        }
        guard expected.allSatisfy({ out[$0] != nil }) else { return }
        for (speaker, audio) in out where audio.contains(where: { !$0.isFinite }) {
            report.failures.append("upmix produced non-finite samples on \(speaker.label)")
        }

        let range = Int(sampleRate)..<(left.count - Int(sampleRate))
        func tone(_ s: Speaker, _ f: Double) -> Double { toneDB(out[s]!, frequency: f, sampleRate: sampleRate, range: range) }

        let vocalC = tone(.c, 440), vocalL = tone(.l, 440), vocalR = tone(.r, 440)
        let vocalSurround = max(tone(.lss, 440), tone(.lrs, 440), tone(.ltf, 440))
        let guitarL = tone(.l, 1500), guitarC = tone(.c, 1500), guitarR = tone(.r, 1500)
        report.metrics["centreVocalOverLR_default_dB"] = vocalC - max(vocalL, vocalR)
        let fullC = toneDB(focused[.c]!, frequency: 440, sampleRate: sampleRate, range: range)
        let fullLR = max(toneDB(focused[.l]!, frequency: 440, sampleRate: sampleRate, range: range),
                         toneDB(focused[.r]!, frequency: 440, sampleRate: sampleRate, range: range))
        report.metrics["centreVocalOverLR_full_dB"] = fullC - fullLR
        report.metrics["vocalLeakToSurround_dB"] = vocalSurround - vocalC
        report.metrics["guitarLOverC_dB"] = guitarL - guitarC
        report.metrics["guitarLOverR_dB"] = guitarL - guitarR
        // Default keeps ~25 % phantom centre (≈ 7.8 dB); full extraction must empty L/R.
        if vocalC - max(vocalL, vocalR) < 6 { report.failures.append("centre-panned source not steered to C (\(vocalC - max(vocalL, vocalR)) dB)") }
        if fullC - fullLR < 20 { report.failures.append("full centre extraction leaves phantom centre (\(fullC - fullLR) dB)") }
        if vocalSurround - vocalC > -20 { report.failures.append("direct sound leaking to surrounds (\(vocalSurround - vocalC) dB)") }
        if guitarL - max(guitarC, guitarR) < 15 { report.failures.append("hard-left source not kept left") }

        // Ambience must reach the surrounds and heights; correlated sound must not.
        let surroundRMS = rmsDB(out[.lss]!, range: range)
        let heightRMS = rmsDB(out[.ltf]!, range: range)
        report.metrics["surroundRMS_dBFS"] = surroundRMS
        report.metrics["heightRMS_dBFS"] = heightRMS
        if surroundRMS < -45 { report.failures.append("surrounds received no ambience (\(surroundRMS) dBFS)") }
        if heightRMS < -50 { report.failures.append("heights received no ambience (\(heightRMS) dBFS)") }

        // Side and rear both carry left ambience; they must be decorrelated at every lag,
        // not merely delayed copies (which would comb-filter when folded to headphones).
        let window = Int(sampleRate)..<Int(sampleRate * 2)
        let xcorr = maxCrossCorrelation(out[.lss]!, out[.lrs]!, range: window, maxLag: Int(0.03 * sampleRate))
        report.metrics["lssVsLrsMaxCrossCorrelation"] = xcorr
        if xcorr > 0.6 { report.failures.append("surround ambience not decorrelated (max ρ=\(xcorr))") }

        // Energy balance: total output vs input (no overall gain jump when switching).
        let inEnergy = energy(left, range: range) + energy(right, range: range)
        let outEnergy = out.values.reduce(0) { $0 + energy($1, range: range) }
        let balance = 10 * log10(outEnergy / max(inEnergy, 1e-12))
        report.metrics["energyBalance_dB"] = balance
        if abs(balance) > 1.5 { report.failures.append("upmix energy balance off by \(balance) dB") }
    }

    /// With extraction, surround and height at zero, the upmix must reconstruct L/R exactly.
    static func checkTransparency(_ report: inout Report, sampleRate: Double) {
        let (left, right) = testStereo(seconds: 3, sampleRate: sampleRate)
        let settings = UpmixSettings(centerExtraction: 0, width: 0, surround: 0, height: 0)
        let out = Upmixer.upmix(left: left, right: right, sampleRate: sampleRate, settings: settings)
        guard let l = out[.l], let r = out[.r] else {
            report.failures.append("transparency: missing L/R"); return
        }
        var err = 0.0, ref = 0.0
        for i in 0..<left.count {
            err += Double(l[i] - left[i]) * Double(l[i] - left[i]) + Double(r[i] - right[i]) * Double(r[i] - right[i])
            ref += Double(left[i]) * Double(left[i]) + Double(right[i]) * Double(right[i])
        }
        let residual = 10 * log10(max(err, 1e-30) / max(ref, 1e-30))
        report.metrics["bypassReconstructionError_dB"] = residual
        if residual > -60 { report.failures.append("STFT round trip not transparent (\(residual) dB)") }
    }

    // MARK: Binaural room

    static func checkBinauralRoom(_ report: inout Report, sampleRate: Double) {
        let frames = Int(sampleRate * 0.8)
        var impulse = [Float](repeating: 0, count: frames)
        for i in 0..<64 { impulse[i] = Float(sin(Double(i) / 64 * .pi)) * 0.8 }
        func render(_ mode: DistanceModel, room: Bool) -> PlanarAudio {
            let source = RenderSource(id: 1, name: "probe", kind: .object, audio: impulse,
                                      keyframes: [ObjectKeyframe(time: 0, position: SpatialPoint(x: 0, y: -1, z: 0), size: 0)],
                                      distance: mode)
            var settings = RenderSettings(sampleRate: sampleRate)
            settings.binauralRoom = room
            settings.limiter.enabled = false
            return SpatialEngine.render(sources: [source], frames: frames, settings: settings).0
        }
        let tail = Int(0.05 * sampleRate)..<Int(0.4 * sampleRate)
        let head = 0..<Int(0.005 * sampleRate)
        func tailDB(_ a: PlanarAudio) -> Double {
            10 * log10(max(energy(a.channels[0], range: tail) + energy(a.channels[1], range: tail), 1e-30)
                / max(energy(a.channels[0], range: head) + energy(a.channels[1], range: head), 1e-30))
        }
        let dry = tailDB(render(.mid, room: false))
        let near = tailDB(render(.near, room: true))
        let mid = tailDB(render(.mid, room: true))
        let far = tailDB(render(.far, room: true))
        report.metrics["roomTail_dry_dB"] = dry
        report.metrics["roomTail_near_dB"] = near
        report.metrics["roomTail_mid_dB"] = mid
        report.metrics["roomTail_far_dB"] = far
        if dry > -80 { report.failures.append("dry binaural render has a tail (\(dry) dB)") }
        if !(near < mid && mid < far) { report.failures.append("room level not ordered Near < Mid < Far") }
        if mid < -40 || mid > -5 { report.failures.append("Mid room level out of range (\(mid) dB)") }

        // Off = stereo bypass: a front source must be identical in both ears.
        let off = render(.off, room: true)
        var diff = 0.0
        for i in 0..<frames { diff = max(diff, Double(abs(off.channels[0][i] - off.channels[1][i]))) }
        report.metrics["offModeInterauralMaxDiff"] = diff
        if diff > 1e-4 { report.failures.append("Off mode is not a plain stereo pan") }
    }

    // MARK: ADM master round trip

    static func checkLiveEngine(_ report: inout Report, sampleRate: Double) {
        let (left, right) = testStereo(seconds: 6, sampleRate: sampleRate)
        let frames = left.count
        var settings = LiveSettings()
        settings.outputGainDB = -12   // stay below the limiter so both paths are linear

        func stream(_ settings: LiveSettings, input: [[Float]], layout: ChannelLayout) -> (PlanarAudio, Double, LiveSpatializer) {
            let live = LiveSpatializer(sampleRate: sampleRate, inputLayout: layout, settings: settings, maxFrames: 1024)
            var outL = [Float](repeating: 0, count: frames), outR = [Float](repeating: 0, count: frames)
            let blocks = [512, 117, 1024, 333, 480, 64, 1000]
            var position = 0, b = 0
            let started = Date()
            outL.withUnsafeMutableBufferPointer { ol in
                outR.withUnsafeMutableBufferPointer { or in
                    while position < frames {
                        let count = min(blocks[b % blocks.count], frames - position)
                        for (ch, buffer) in live.inputs.enumerated() {
                            for i in 0..<count { buffer[i] = input[ch][position + i] }
                        }
                        live.process(frames: count, outL: ol.baseAddress!.advanced(by: position), outR: or.baseAddress!.advanced(by: position))
                        position += count
                        b += 1
                    }
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            return (PlanarAudio(sampleRate: sampleRate, channels: [outL, outR]), elapsed, live)
        }

        let (live, seconds, engine) = stream(settings, input: [left, right], layout: .stereo)
        report.metrics["liveRealtimeFactor"] = (Double(frames) / sampleRate) / max(seconds, 1e-9)
        report.metrics["liveLatencyMS"] = Double(engine.latency) / sampleRate * 1000
        if (Double(frames) / sampleRate) / max(seconds, 1e-9) < 20 { report.failures.append("live engine too slow for real time") }

        // Offline reference: upmix → binaural (same render mode, no limiter), shifted by latency.
        let beds = Upmixer.upmix(left: left, right: right, sampleRate: sampleRate, settings: settings.upmix)
        let sources = StreamingUpmixer.speakers.enumerated().compactMap { index, speaker -> RenderSource? in
            guard let audio = beds[speaker] else { return nil }
            return RenderSource(id: index + 1, name: speaker.label, kind: .bed(speaker), audio: audio, distance: settings.renderMode)
        }
        var offline = RenderSettings(sampleRate: sampleRate)
        offline.limiter.enabled = false
        offline.outputGainDB = settings.outputGainDB + LiveSpatializer.makeupDB(settings.renderMode)
        let (reference, _) = SpatialEngine.render(sources: sources, frames: frames, settings: offline)
        var err = 0.0, ref = 0.0
        let latency = engine.latency
        for ch in 0..<2 {
            for i in Int(sampleRate)..<(frames - latency) {
                let d = Double(live.channels[ch][i + latency] - reference.channels[ch][i])
                err += d * d
                ref += Double(reference.channels[ch][i]) * Double(reference.channels[ch][i])
            }
        }
        let mismatch = 10 * log10(max(err, 1e-30) / max(ref, 1e-30))
        report.metrics["liveVsOfflineError_dB"] = mismatch
        if mismatch > -60 { report.failures.append("live engine differs from offline render (\(mismatch) dB)") }

        // A/B loudness match per render mode: spatial vs original, broadband programme.
        var rng = SplitMix64(seed: 77)
        var pinkL = [Float](repeating: 0, count: frames), pinkR = [Float](repeating: 0, count: frames)
        var bL = (0.0, 0.0, 0.0), bR = (0.0, 0.0, 0.0)
        for i in 0..<frames {
            // Paul Kellet's economy pink filter on white noise; partly correlated L/R like a mix.
            let common = rng.nextUniform() * 2 - 1
            let wl = 0.6 * common + 0.4 * (rng.nextUniform() * 2 - 1)
            let wr = 0.6 * common + 0.4 * (rng.nextUniform() * 2 - 1)
            bL = (0.99765 * bL.0 + wl * 0.0990460, 0.96300 * bL.1 + wl * 0.2965164, 0.57000 * bL.2 + wl * 1.0526913)
            bR = (0.99765 * bR.0 + wr * 0.0990460, 0.96300 * bR.1 + wr * 0.2965164, 0.57000 * bR.2 + wr * 1.0526913)
            pinkL[i] = Float((bL.0 + bL.1 + bL.2 + wl * 0.1848) * 0.05)
            pinkR[i] = Float((bR.0 + bR.1 + bR.2 + wr * 0.1848) * 0.05)
        }
        for mode in DistanceModel.allCases {
            var s = LiveSettings()
            s.renderMode = mode
            s.outputGainDB = -12
            let spatial = stream(s, input: [pinkL, pinkR], layout: .stereo).0
            s.spatial = false
            let original = stream(s, input: [pinkL, pinkR], layout: .stereo).0
            let range = Int(sampleRate)..<frames
            let a = LoudnessAnalyzer.analyze(spatial.slice(range), layout: .stereo).integrated
            let o = LoudnessAnalyzer.analyze(original.slice(range), layout: .stereo).integrated
            report.metrics["abLoudnessDelta_\(mode.rawValue)_LU"] = a - o
            if abs(a - o) > 1.0 { report.failures.append("A/B not loudness-matched in \(mode.rawValue) (\(a - o) LU)") }
        }

        // Multichannel bed input (7.1.4) renders without an upmix and with zero latency.
        let bed = ChannelLayout.named("7.1.4")!
        let multi = bed.speakers.map { speaker -> [Float] in speaker == .c ? left : [Float](repeating: 0, count: frames) }
        let (bedOut, _, bedEngine) = stream(LiveSettings(), input: multi, layout: bed)
        report.metrics["liveBedLatency"] = Double(bedEngine.latency)
        if bedOut.peak() < 0.01 { report.failures.append("live 7.1.4 bed input is silent") }
        let lr = 10 * log10(max(energy(bedOut.channels[0], range: Int(sampleRate)..<frames), 1e-30)
            / max(energy(bedOut.channels[1], range: Int(sampleRate)..<frames), 1e-30))
        report.metrics["liveCentreChannelBalance_dB"] = lr
        if abs(lr) > 1.0 { report.failures.append("centre channel not centred in live render (\(lr) dB)") }
    }

    // MARK: Measurement helpers

    /// The 9.1.6 loopback bed (same channel labels Downmix installs on BlackHole).
    public static let loopbackLayout = ChannelLayout(name: "9.1.6", speakers: [
        .l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs, .lw, .rw, .ltf, .rtf, .cts, .cfh, .ltr, .rtr,
    ])

    /// Loopback input that switches between stereo songs and surround tracks.
    static func checkAdaptive(_ report: inout Report, sampleRate: Double) {
        let layout = loopbackLayout
        let block = 512
        let adaptive = AdaptiveSpatializer(sampleRate: sampleRate, inputLayout: layout, maxFrames: block)
        let reference = LiveSpatializer(sampleRate: sampleRate, inputLayout: .stereo, maxFrames: block)
        let (left, right) = testStereo(seconds: 2, sampleRate: sampleRate)
        let outL = UnsafeMutablePointer<Float>.allocate(capacity: block), outR = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let refL = UnsafeMutablePointer<Float>.allocate(capacity: block), refR = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { outL.deallocate(); outR.deallocate(); refL.deallocate(); refR.deallocate() }
        let latencyDiff = adaptive.latency - reference.latency

        // 1. Stereo song on channels 1–2: identical to the stereo path (after alignment).
        var adaptiveOut: [Float] = [], referenceOut: [Float] = []
        var position = 0
        while position + block <= left.count {
            for ch in 0..<layout.channelCount { adaptive.inputs[ch].update(repeating: 0, count: block) }
            adaptive.inputs[0].update(from: left.withUnsafeBufferPointer { $0.baseAddress! + position }, count: block)
            adaptive.inputs[1].update(from: right.withUnsafeBufferPointer { $0.baseAddress! + position }, count: block)
            reference.inputs[0].update(from: adaptive.inputs[0], count: block)
            reference.inputs[1].update(from: adaptive.inputs[1], count: block)
            adaptive.process(frames: block, outL: outL, outR: outR)
            reference.process(frames: block, outL: refL, outR: refR)
            adaptiveOut += UnsafeBufferPointer(start: outL, count: block)
            referenceOut += UnsafeBufferPointer(start: refL, count: block)
            position += block
        }
        if adaptive.surroundActive { report.failures.append("adaptive: stereo input detected as surround") }
        var err = 0.0, ref = 0.0
        for i in Int(sampleRate * 0.5)..<(adaptiveOut.count - latencyDiff) {
            let d = Double(adaptiveOut[i + latencyDiff] - referenceOut[i]); err += d * d
            ref += Double(referenceOut[i] * referenceOut[i])
        }
        let stereoError = 10 * log10(max(err, 1e-30) / max(ref, 1e-30))
        report.metrics["adaptiveStereoVsStereoPath_dB"] = stereoError
        if stereoError > -90 { report.failures.append(String(format: "adaptive: stereo path differs by %.1f dB", stereoError)) }

        // 2. Surround track: noise in C only → bed path, imaged dead centre.
        var rng = SplitMix64(seed: 99)
        var eL = 0.0, eR = 0.0
        let centre = layout.index(of: .c)!
        for n in 0..<Int(sampleRate * 1.5) / block {
            for ch in 0..<layout.channelCount { adaptive.inputs[ch].update(repeating: 0, count: block) }
            for i in 0..<block { adaptive.inputs[centre][i] = Float(rng.nextUniform() * 2 - 1) * 0.2 }
            adaptive.process(frames: block, outL: outL, outR: outR)
            if n > Int(sampleRate * 0.5) / block {
                for i in 0..<block { eL += Double(outL[i] * outL[i]); eR += Double(outR[i] * outR[i]) }
            }
        }
        if !adaptive.surroundActive { report.failures.append("adaptive: centre-only input not detected as surround") }
        let balance = 10 * log10(max(eL, 1e-12) / max(eR, 1e-12))
        report.metrics["adaptiveCentreBalance_dB"] = balance
        if abs(balance) > 1 { report.failures.append(String(format: "adaptive: centre images %.2f dB off-centre", balance)) }
        let kind = AdaptiveSpatializer.describe(activeChannels: adaptive.activeChannels, layout: layout)
        if kind != "3.1" { report.failures.append("adaptive: centre-only described as \(kind)") }

        // 3. Back to a stereo song: returns to the upmix after the hold time.
        for _ in 0..<Int(sampleRate * (AdaptiveSpatializer.holdSeconds + 0.5)) / block {
            for ch in 0..<layout.channelCount { adaptive.inputs[ch].update(repeating: 0, count: block) }
            for i in 0..<block { adaptive.inputs[0][i] = 0.1; adaptive.inputs[1][i] = -0.1 }
            adaptive.process(frames: block, outL: outL, outR: outR)
        }
        if adaptive.surroundActive { report.failures.append("adaptive: stayed on surround after the hold") }
        var heights = UInt32(0)
        heights |= 1 << UInt32(layout.index(of: .ltf)!)
        if AdaptiveSpatializer.describe(activeChannels: heights | 0b11, layout: layout) != "Atmos" {
            report.failures.append("adaptive: height channels not described as Atmos")
        }
    }

    static func toneDB(_ x: [Float], frequency: Double, sampleRate: Double, range: Range<Int>) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * frequency / sampleRate
        for i in range {
            re += Double(x[i]) * cos(w * Double(i))
            im += Double(x[i]) * sin(w * Double(i))
        }
        let amplitude = 2 * (re * re + im * im).squareRoot() / Double(range.count)
        return 20 * log10(max(amplitude, 1e-12))
    }

    static func energy(_ x: [Float], range: Range<Int>) -> Double {
        var e = 0.0
        for i in range where i < x.count { e += Double(x[i]) * Double(x[i]) }
        return e
    }

    static func rmsDB(_ x: [Float], range: Range<Int>) -> Double {
        10 * log10(max(energy(x, range: range) / Double(range.count), 1e-30))
    }

    static func maxCrossCorrelation(_ a: [Float], _ b: [Float], range: Range<Int>, maxLag: Int) -> Double {
        var best = 0.0
        let aa = energy(a, range: range)
        for lag in -maxLag...maxLag {
            var ab = 0.0, bb = 0.0
            for i in range {
                let j = i + lag
                guard j >= 0, j < b.count else { continue }
                ab += Double(a[i]) * Double(b[j]); bb += Double(b[j]) * Double(b[j])
            }
            best = max(best, abs(ab) / max((aa * bb).squareRoot(), 1e-30))
        }
        return best
    }

    static func correlation(_ a: [Float], _ b: [Float], range: Range<Int>) -> Double {
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in range {
            ab += Double(a[i]) * Double(b[i]); aa += Double(a[i]) * Double(a[i]); bb += Double(b[i]) * Double(b[i])
        }
        return ab / max((aa * bb).squareRoot(), 1e-30)
    }
}
