import Foundation
import os

/// Listener-facing settings for real-time spatialisation.
public struct LiveSettings: Codable, Sendable, Hashable {
    /// true = spatial (upmix + binaural); false = the original signal (A/B).
    public var spatial = true
    public var upmix = UpmixSettings()
    /// Binaural render mode for every channel: Off = plain stereo, Near/Mid/Far = more room.
    public var renderMode: DistanceModel = .mid
    public var outputGainDB: Double = 0
    public init() {}
}

/// Real-time spatialiser: stereo (upmixed to 7.0.4), channel-based multichannel
/// (5.1, 7.1, 7.1.4, …) or pre-rendered binaural in; binaural stereo out.
///
/// Uses the same DSP as the offline renderer: `StreamingUpmixer`, `BinauralRenderer.cue`,
/// `BinauralRoomProcessor`. Allocation-free after init. `process` runs on the audio
/// thread; `update` may be called from any thread.
public final class LiveSpatializer {
    public let sampleRate: Double
    public let inputLayout: ChannelLayout
    public let maxFrames: Int
    /// Planar input buffers (one per input channel, `maxFrames` capacity). Fill these, then call `process`.
    public let inputs: [UnsafeMutablePointer<Float>]
    /// Total latency in samples: the upmixer's FFT frame (stereo input only) plus the
    /// limiter look-ahead.
    public let latency: Int
    /// Latency of the spatial path before the shared limiter (what the A/B original is delayed by).
    private let pathLatency: Int

    // Meters (written on the audio thread, read by the UI; single-word stores).
    public private(set) var inputPeak: Float = 0
    public private(set) var outputPeakL: Float = 0
    public private(set) var outputPeakR: Float = 0
    public private(set) var limiterReductionDB: Float = 0

    private struct Voice {
        var speaker: Speaker
        var cue: BinauralRenderer.Cue
        /// Same distance gain the offline renderer derives from the bed position.
        var distance: Float = 1
        var notchL = Biquad(), notchR = Biquad()
        var shadowL = OnePole(), shadowR = OnePole()
        var delayL = FractionalDelay(maxDelaySamples: 128)
        var delayR = FractionalDelay(maxDelaySamples: 128)
    }

    private enum Mode { case upmix, beds, binaural }

    private let pending = OSAllocatedUnfairLock<LiveSettings?>(initialState: nil)
    private var settings: LiveSettings
    private let mode: Mode
    private let upmixer: StreamingUpmixer?
    private var bed: [UnsafeMutablePointer<Float>]
    private var voices: [Voice]
    private let room: BinauralRoomProcessor
    private var lfeL: Biquad, lfeR: Biquad
    private let scratch: [UnsafeMutablePointer<Float>]   // spatL, spatR, sendL, sendR, origL, origR
    private let originalDelay: [UnsafeMutablePointer<Float>]
    private let originalMask: Int
    private var originalWrite = 0
    private var crossfade: Float
    private let crossfadeCoef: Float
    private let limiter: StreamingLimiter
    private var ownedBed: [UnsafeMutablePointer<Float>] = []

    /// Level of the spatial path relative to the original, so A/B is loudness-matched.
    /// Measured with `SpatialDiagnostics` (BS.1770 integrated loudness, partly correlated
    /// pink-noise programme through the default upmix); re-measure if the DSP changes.
    static func makeupDB(_ mode: DistanceModel) -> Double {
        switch mode {
        case .off: 0.4
        case .near: 0.9
        case .mid: 2.3
        case .far: 4.9
        }
    }

    public init(sampleRate: Double, inputLayout: ChannelLayout, settings: LiveSettings = LiveSettings(), maxFrames: Int = 4096) {
        self.sampleRate = sampleRate
        self.inputLayout = inputLayout
        self.maxFrames = maxFrames
        self.settings = settings

        func buffer() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            p.initialize(repeating: 0, count: maxFrames)
            return p
        }
        let channels = max(1, inputLayout.channelCount)
        inputs = (0..<channels).map { _ in buffer() }
        scratch = (0..<6).map { _ in buffer() }

        let speakers = inputLayout.speakers
        if inputLayout.isBinaural {
            mode = .binaural
            upmixer = nil
            bed = []
        } else if speakers == [.l, .r] || speakers == [.c] || speakers.count <= 2 {
            mode = .upmix
            let up = StreamingUpmixer(sampleRate: sampleRate, settings: settings.upmix)
            upmixer = up
            ownedBed = (0..<StreamingUpmixer.speakers.count).map { _ in buffer() }
            bed = ownedBed
        } else {
            mode = .beds
            upmixer = nil
            bed = inputs
        }
        pathLatency = upmixer?.latency ?? 0

        let bedSpeakers: [Speaker] = mode == .upmix ? StreamingUpmixer.speakers : (mode == .beds ? speakers : [])
        voices = bedSpeakers.map { speaker in
            let cue = BinauralRenderer.cue(azimuth: speaker.isLFE ? 0 : speaker.azimuth,
                                           elevation: speaker.elevation, sampleRate: sampleRate)
            var voice = Voice(speaker: speaker, cue: cue)
            if !speaker.isLFE {
                let radius = SpatialPoint.fromSpherical(azimuth: speaker.azimuth, elevation: speaker.elevation, radius: 1).spherical.radius
                voice.distance = BinauralRenderer.distanceGain(radius: radius)
            }
            voice.shadowL.setCutoff(cue.shadowCutoffL, sampleRate: sampleRate)
            voice.shadowR.setCutoff(cue.shadowCutoffR, sampleRate: sampleRate)
            let notch = Biquad.peaking(frequency: 8200, gainDB: cue.notchGainDB, q: 1.3, sampleRate: sampleRate)
            voice.notchL.setCoefficients(notch)
            voice.notchR.setCoefficients(notch)
            return voice
        }
        room = BinauralRoomProcessor(sampleRate: sampleRate)
        let bass = BassManagement()
        lfeL = Biquad.lowPass(frequency: bass.crossoverHz, sampleRate: sampleRate)
        lfeR = Biquad.lowPass(frequency: bass.crossoverHz, sampleRate: sampleRate)

        var size = 1
        while size < pathLatency + maxFrames + 1 { size <<= 1 }
        originalMask = size - 1
        originalDelay = (0..<2).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: size)
            p.initialize(repeating: 0, count: size)
            return p
        }
        crossfade = settings.spatial ? 1 : 0
        crossfadeCoef = Float(1 - exp(-1 / (0.03 * sampleRate)))
        limiter = StreamingLimiter(sampleRate: sampleRate)
        latency = pathLatency + limiter.latency
    }

    deinit {
        for p in inputs + scratch + originalDelay + ownedBed { p.deallocate() }
    }

    /// Thread-safe; picked up at the start of the next `process` call.
    public func update(_ settings: LiveSettings) {
        pending.withLock { $0 = settings }
    }

    public var currentSettings: LiveSettings { settings }

    /// Processes `frames` (≤ `maxFrames`) samples from `inputs` into `outL`/`outR`.
    public func process(frames: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        let frames = min(frames, maxFrames)
        if let next = pending.withLockIfAvailable({ value -> LiveSettings? in
            defer { value = nil }
            return value
        }) ?? nil {
            settings = next
            upmixer?.update(settings: next.upmix)
        }

        var peakIn: Float = 0
        for input in inputs {
            for i in 0..<frames { peakIn = max(peakIn, abs(input[i])) }
        }
        inputPeak = peakIn

        let spatL = scratch[0], spatR = scratch[1], sendL = scratch[2], sendR = scratch[3]
        let origL = scratch[4], origR = scratch[5]
        let left = inputs[0]
        let right = inputs.count > 1 ? inputs[1] : inputs[0]

        // 1. Spatial path.
        switch mode {
        case .binaural:
            spatL.update(from: left, count: frames)
            spatR.update(from: right, count: frames)
        case .upmix, .beds:
            if let upmixer { upmixer.process(left: left, right: right, frames: frames, outputs: &bed) }
            renderBeds(frames: frames, spatL: spatL, spatR: spatR, sendL: sendL, sendR: sendR)
        }

        // 2. Original path, time-aligned with the spatial path.
        switch mode {
        case .upmix:
            let mask = originalMask
            var w = originalWrite
            let a = originalDelay[0], b = originalDelay[1]
            for i in 0..<frames {
                a[w] = left[i]; b[w] = right[i]
                origL[i] = a[(w - pathLatency) & mask]
                origR[i] = b[(w - pathLatency) & mask]
                w = (w + 1) & mask
            }
            originalWrite = w
        case .binaural:
            origL.update(from: left, count: frames)
            origR.update(from: right, count: frames)
        case .beds:
            foldDown(frames: frames, outL: origL, outR: origR)
        }

        // 3. Loudness-matched crossfade, output gain, limiter.
        let target: Float = settings.spatial ? 1 : 0
        let makeup = mode == .binaural ? 1 : AudioMath.dbToGain(Self.makeupDB(settings.renderMode))
        let gain = AudioMath.dbToGain(settings.outputGainDB)
        for i in 0..<frames {
            crossfade += (target - crossfade) * crossfadeCoef
            let s = crossfade * makeup
            let o = 1 - crossfade
            outL[i] = (spatL[i] * s + origL[i] * o) * gain
            outR[i] = (spatR[i] * s + origR[i] * o) * gain
        }
        // Fully on Original at unity volume: pass the source untouched (only overs are caught).
        limiter.transparent = target == 0 && crossfade < 1e-4 && gain <= 1
        limiterReductionDB = limiter.process(outL, outR, frames: frames)

        var pl: Float = 0, pr: Float = 0
        for i in 0..<frames { pl = max(pl, abs(outL[i])); pr = max(pr, abs(outR[i])) }
        outputPeakL = pl
        outputPeakR = pr
    }

    private func renderBeds(frames: Int, spatL: UnsafeMutablePointer<Float>, spatR: UnsafeMutablePointer<Float>,
                            sendL: UnsafeMutablePointer<Float>, sendR: UnsafeMutablePointer<Float>) {
        for i in 0..<frames { spatL[i] = 0; spatR[i] = 0; sendL[i] = 0; sendR[i] = 0 }
        let renderMode = settings.renderMode
        let bypass = renderMode == .off
        let modeGain = AudioMath.dbToGain(renderMode.attenuationDB)
        let roomSend = bypass ? 0 : AudioMath.dbToGain(renderMode.roomSendDB)
        let lfeGain = AudioMath.dbToGain(BassManagement().lfeToStereoDB) * 0.5

        for v in 0..<voices.count {
            let x = bed[v]
            if voices[v].speaker.isLFE {
                if mode == .upmix, !settings.upmix.generateLFE { continue }
                for i in 0..<frames {
                    let s = x[i] * lfeGain
                    spatL[i] += lfeL.process(s)
                    spatR[i] += lfeR.process(s)
                }
                continue
            }
            let cue = voices[v].cue
            let direct = modeGain * voices[v].distance
            if bypass {
                // Off: plain constant-power stereo pan, no HRTF, no room.
                let gl = cue.panL * direct, gr = cue.panR * direct
                for i in 0..<frames { spatL[i] += x[i] * gl; spatR[i] += x[i] * gr }
                continue
            }
            let sl = cue.panL * roomSend * direct, sr = cue.panR * roomSend * direct
            let gl = cue.ildL * direct, gr = cue.ildR * direct
            for i in 0..<frames {
                let s = x[i]
                sendL[i] += s * sl
                sendR[i] += s * sr
                let l = voices[v].delayL.process(voices[v].shadowL.process(voices[v].notchL.process(s)), delay: cue.delayL)
                let r = voices[v].delayR.process(voices[v].shadowR.process(voices[v].notchR.process(s)), delay: cue.delayR)
                spatL[i] += l * gl
                spatR[i] += r * gr
            }
        }
        if !bypass {
            room.process(sendL: sendL, sendR: sendR, addingTo: spatL, spatR, frames: frames)
        }
    }

    /// Conventional Lo/Ro-style fold for the A/B "original" of multichannel input.
    private func foldDown(frames: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        for i in 0..<frames { outL[i] = 0; outR[i] = 0 }
        var norm: Float = 0
        for (index, speaker) in inputLayout.speakers.enumerated() where index < inputs.count {
            guard !speaker.isLFE else { continue }
            let az = speaker.azimuth
            let gl: Float, gr: Float
            if az == 0 { gl = 0.707; gr = 0.707 }
            else if az < 0 { gl = abs(az) <= 30 ? 1 : 0.707; gr = 0 }
            else { gl = 0; gr = az <= 30 ? 1 : 0.707 }
            norm += gl * gl
            let x = inputs[index]
            for i in 0..<frames { outL[i] += x[i] * gl; outR[i] += x[i] * gr }
        }
        // Keep many-channel folds from piling up far above the source level.
        let scale = norm > 2 ? 1 / (norm / 2).squareRoot() : 1
        if scale != 1 { for i in 0..<frames { outL[i] *= scale; outR[i] *= scale } }
    }
}

/// Streaming look-ahead peak limiter: sliding-window minimum of the required gain
/// (instant attack inside the look-ahead), exponential release, hard ceiling.
public final class StreamingLimiter {
    private let lookahead: Int
    public var latency: Int { lookahead }
    private let mask: Int
    private let delayL: UnsafeMutablePointer<Float>, delayR: UnsafeMutablePointer<Float>
    private let qIndex: UnsafeMutablePointer<Int>, qValue: UnsafeMutablePointer<Float>
    private var qHead = 0, qTail = 0
    private var t = 0
    private var gain: Float = 1
    private let threshold: Float, ceiling: Float, releaseCoef: Float
    /// Only act on overs (> 0 dBFS). Used for the untouched "Original" path so a loud
    /// master's peaks between the threshold and full scale pass bit-for-bit.
    public var transparent = false

    public init(sampleRate: Double, thresholdDB: Double = -1.5, ceilingDB: Double = -0.3, lookaheadMS: Double = 2, releaseMS: Double = 160) {
        lookahead = max(1, Int(lookaheadMS / 1000 * sampleRate))
        var size = 1
        while size < lookahead + 2 { size <<= 1 }
        mask = size - 1
        delayL = .allocate(capacity: size); delayL.initialize(repeating: 0, count: size)
        delayR = .allocate(capacity: size); delayR.initialize(repeating: 0, count: size)
        qIndex = .allocate(capacity: size); qIndex.initialize(repeating: 0, count: size)
        qValue = .allocate(capacity: size); qValue.initialize(repeating: 1, count: size)
        threshold = Float(pow(10, thresholdDB / 20))
        ceiling = Float(pow(10, ceilingDB / 20))
        releaseCoef = Float(1 - exp(-1.0 / (releaseMS / 1000 * sampleRate)))
    }

    deinit {
        delayL.deallocate(); delayR.deallocate(); qIndex.deallocate(); qValue.deallocate()
    }

    /// Limits in place (output delayed by the look-ahead). Returns the deepest reduction in dB.
    @discardableResult
    public func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Float {
        var minGain: Float = 1
        let threshold: Float = transparent ? 1 : self.threshold
        let ceiling: Float = transparent ? 1 : self.ceiling
        for i in 0..<frames {
            let peak = max(abs(l[i]), abs(r[i]))
            let required: Float = peak > threshold ? threshold / peak : 1
            // Monotonic deque: the minimum required gain over the last lookahead+1 samples.
            while qTail != qHead, qValue[(qTail - 1) & mask] >= required { qTail = (qTail - 1) & mask }
            qIndex[qTail] = t; qValue[qTail] = required; qTail = (qTail + 1) & mask
            while qIndex[qHead] <= t - (lookahead + 1) { qHead = (qHead + 1) & mask }
            let windowMin = qValue[qHead]

            if windowMin < gain { gain = windowMin } else { gain += (windowMin - gain) * releaseCoef }
            minGain = min(minGain, gain)

            let w = t & mask
            let dl = delayL[(t - lookahead) & mask], dr = delayR[(t - lookahead) & mask]
            delayL[w] = l[i]; delayR[w] = r[i]
            l[i] = min(max(dl * gain, -ceiling), ceiling)
            r[i] = min(max(dr * gain, -ceiling), ceiling)
            t += 1
        }
        return minGain < 0.999 ? 20 * log10(max(minGain, 0.0001)) : 0
    }
}
