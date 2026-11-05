import Accelerate
import Foundation
import os
import Synchronization

/// Real-time spatialiser: 2…16 input channels in, binaural stereo out.
///
/// - **2 channels** (process tap, BlackHole 2ch): stereo → 7.1.4 upmix → binaural + room.
/// - **More channels** (BlackHole 16ch in the loopback order of `Layout.loopback`): the
///   content decides. A stereo song arrives on channels 1–2 only and is upmixed; an Atmos
///   track or a film's 5.1 fills the bed and is rendered from its own channels. Surround
///   is held for 3 s after the last non-L/R signal, and the switch crossfades over 50 ms.
///
/// The two sources feed **one** binaural renderer, room and limiter: during a switch the
/// speaker feeds are crossfaded, otherwise only one source is computed. The upmixer
/// sleeps while a surround bed plays and wakes 0.5 s before it could be needed. After 3 s
/// of digital silence the whole chain goes dormant.
///
/// `process` runs on the audio thread and never allocates or blocks; `update` may be
/// called from any thread.
public final class Spatializer: @unchecked Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let maxFrames: Int
    /// Input → output delay in samples (upmix frame + limiter look-ahead).
    public let latency: Int
    /// Planar input buffers (`maxFrames` each). Fill them, then call `process`.
    public let inputs: [UnsafeMutablePointer<Float>]
    /// True for more than two inputs: stereo/surround chosen by content.
    public let adaptive: Bool

    public static let activityThreshold: Float = 1e-4      // −80 dBFS
    public static let holdSeconds = 3.0

    // Meters (audio thread writes, UI reads).
    private let inPeakBits = Atomic<UInt32>(0)
    private let outPeakBits = Atomic<UInt32>(0)
    private let maskBits = Atomic<UInt32>(0)
    private let dormantFlag = Atomic<Bool>(false)
    public var inputPeak: Float { Float(bitPattern: inPeakBits.load(ordering: .relaxed)) }
    public var outputPeak: Float { Float(bitPattern: outPeakBits.load(ordering: .relaxed)) }
    /// Bit i set while input channel i carried signal within the hold window.
    public var activeChannels: UInt32 { maskBits.load(ordering: .relaxed) }
    /// No signal for a while; the chain is asleep.
    public var isDormant: Bool { dormantFlag.load(ordering: .relaxed) }

    private let pending = OSAllocatedUnfairLock<LiveSettings?>(initialState: nil)
    private var settings: LiveSettings

    private let upmixer: Upmixer
    private let upOut: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private var upmixRunning = true

    // Every input delayed by the upmix latency (the bed path and the A/B original).
    private let delay: Int
    private let ring: [UnsafeMutablePointer<Float>]
    private let ringMask: Int
    private var ringWrite = 0
    private let delayed: [UnsafeMutablePointer<Float>]

    private let head: HeadRenderer
    private let room: Room
    private var roomSilent = 0
    private var lfe: Biquad
    private var lfeSilent = Int.max
    private let lfeGain = dbToGain(5.5) * 0.5
    private let limiter: Limiter

    private let feeds: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let mix: [UnsafeMutablePointer<Float>]
    private let ramp: UnsafeMutablePointer<Float>
    private let spatL, spatR, sendL, sendR, origL, origR, lfeBuf: UnsafeMutablePointer<Float>

    // Content switching.
    private var weight: Float = 0
    private let fadeCoef: Float
    private let lastActive: UnsafeMutablePointer<Int>
    private var clock = 0
    private let holdFrames: Int
    private let warmupFrames: Int
    private var surround = false

    // Spatial ↔ Original.
    private var crossfade: Float
    private let crossfadeCoef: Float

    // Fold-down for the Original of a surround bed.
    private let foldL: [Float], foldR: [Float]
    private let foldScale: Float

    // Silence.
    private var silentFrames = 0
    private let dormantAfter: Int
    private var dormant = false

    public init(sampleRate: Double, channels: Int, settings: LiveSettings = LiveSettings(), maxFrames: Int = 4096) {
        let channels = min(max(channels, 2), Layout.loopback.count)
        self.sampleRate = sampleRate
        self.channelCount = channels
        self.maxFrames = maxFrames
        self.settings = settings
        adaptive = channels > 2

        inputs = (0..<channels).map { _ in makeBuffer(maxFrames) }
        upmixer = Upmixer(sampleRate: sampleRate, settings: settings.upmix)
        upOut = .allocate(capacity: Upmixer.outputCount)
        for j in 0..<Upmixer.outputCount { upOut[j] = makeBuffer(maxFrames) }

        delay = upmixer.latency
        let size = nextPowerOfTwo(atLeast: delay + maxFrames + 1)
        ringMask = size - 1
        ring = (0..<channels).map { _ in makeBuffer(size) }
        delayed = (0..<channels).map { _ in makeBuffer(maxFrames) }

        var speakers = Set(Layout.upmix)
        if adaptive { speakers.formUnion(Layout.loopback.prefix(channels)) }
        head = HeadRenderer(speakers: speakers.sorted { $0.rawValue < $1.rawValue }, sampleRate: sampleRate, maxFrames: maxFrames)
        room = Room(sampleRate: sampleRate)
        lfe = .lowPass(80, sampleRate: sampleRate)
        limiter = Limiter(sampleRate: sampleRate)
        latency = delay + limiter.latency

        let speakerCount = Layout.loopback.count
        feeds = .allocate(capacity: speakerCount)
        feeds.initialize(repeating: nil, count: speakerCount)
        mix = (0..<speakerCount).map { _ in makeBuffer(maxFrames) }
        ramp = makeBuffer(maxFrames)
        spatL = makeBuffer(maxFrames); spatR = makeBuffer(maxFrames)
        sendL = makeBuffer(maxFrames); sendR = makeBuffer(maxFrames)
        origL = makeBuffer(maxFrames); origR = makeBuffer(maxFrames)
        lfeBuf = makeBuffer(maxFrames)

        fadeCoef = Float(1 - exp(-1 / (0.05 * sampleRate)))
        holdFrames = Int(Self.holdSeconds * sampleRate)
        warmupFrames = Int(0.5 * sampleRate)
        lastActive = .allocate(capacity: channels)
        lastActive.initialize(repeating: -Int(Self.holdSeconds * sampleRate) - 1, count: channels)
        crossfade = settings.spatial ? 1 : 0
        crossfadeCoef = Float(1 - exp(-1 / (0.03 * sampleRate)))
        dormantAfter = Int(3 * sampleRate)

        var fl: [Float] = [], fr: [Float] = []
        var norm: Float = 0
        for speaker in Layout.loopback.prefix(channels) {
            var gl: Float = 0, gr: Float = 0
            if !speaker.isLFE {
                let az = speaker.azimuth
                if az == 0 { gl = 0.707; gr = 0.707 }
                else if az < 0 { gl = abs(az) <= 30 ? 1 : 0.707; gr = 0 }
                else { gl = 0; gr = az <= 30 ? 1 : 0.707 }
                norm += gl * gl
            }
            fl.append(gl); fr.append(gr)
        }
        foldL = fl; foldR = fr
        foldScale = norm > 2 ? 1 / (norm / 2).squareRoot() : 1
    }

    deinit {
        for p in inputs + ring + delayed + mix { p.deallocate() }
        for j in 0..<Upmixer.outputCount { upOut[j].deallocate() }
        upOut.deallocate()
        feeds.deallocate()
        for p in [ramp, spatL, spatR, sendL, sendR, origL, origR, lfeBuf] { p.deallocate() }
        lastActive.deallocate()
    }

    /// Thread-safe; picked up at the start of the next `process` call.
    public func update(_ settings: LiveSettings) {
        pending.withLock { $0 = settings }
    }

    /// Short name of what is arriving: "Atmos", "7.1", "5.1", "3.1" or "Stereo".
    public var incoming: String { adaptive ? Layout.describe(activeChannels: activeChannels) : "Stereo" }

    /// Processes `frames` samples from `inputs` into `outL`/`outR`.
    public func process(frames: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        if let next = pending.withLockIfAvailable({ value -> LiveSettings? in
            defer { value = nil }
            return value
        }) ?? nil {
            settings = next
            upmixer.update(settings: next.upmix)
        }
        let frames = min(frames, maxFrames)
        let n = vDSP_Length(frames)

        // 1. What is arriving.
        var peak: Float = 0
        var mask: UInt32 = 0
        for ch in 0..<channelCount {
            var p: Float = 0
            vDSP_maxmgv(inputs[ch], 1, &p, n)
            peak = max(peak, p)
            if adaptive {
                if p > Self.activityThreshold { lastActive[ch] = clock }
                if clock - lastActive[ch] <= holdFrames { mask |= 1 << UInt32(ch) }
            }
        }
        inPeakBits.store(peak.bitPattern, ordering: .relaxed)
        maskBits.store(mask, ordering: .relaxed)
        surround = mask & ~UInt32(0b11) != 0
        clock += frames
        let target: Float = surround ? 1 : 0
        let spatialTarget: Float = settings.spatial ? 1 : 0

        // 2. Silence: after 3 s every state has decayed to nothing; sleep until signal returns.
        silentFrames = peak == 0 ? silentFrames + frames : 0
        if dormant, peak > 0 { wake(target: target, spatialTarget: spatialTarget) }
        if !dormant, silentFrames >= dormantAfter { dormant = true; dormantFlag.store(true, ordering: .relaxed) }
        if dormant {
            vDSP_vclr(outL, 1, n); vDSP_vclr(outR, 1, n)
            outPeakBits.store(0, ordering: .relaxed)
            return
        }

        // 3. Delay every input by the upmix latency (bed path and A/B original).
        var w = ringWrite
        for ch in 0..<channelCount {
            let src = inputs[ch], dst = delayed[ch], r = ring[ch]
            var wi = w
            for i in 0..<frames {
                r[wi] = src[i]
                dst[i] = r[(wi - delay) & ringMask]
                wi = (wi + 1) & ringMask
            }
        }
        w = (w + frames) & ringMask
        ringWrite = w

        // 4. Content crossfade weight (0 = upmix, 1 = bed).
        var ramping = false
        if adaptive, weight != target {
            // One-pole glide written as a decaying distance to the target, so it really
            // arrives (w += (t − w)·c stalls 7·10⁻⁵ short of 1 in single precision).
            ramping = true
            var d = target - weight
            let r = 1 - fadeCoef
            for i in 0..<frames {
                d *= r
                ramp[i] = target - d
            }
            weight = abs(d) < 1e-6 ? target : target - d
        }

        // 5. Upmix, unless a surround bed is settled and the hold can't expire within 0.5 s.
        var needUpmix = true
        if adaptive, !ramping, weight == 1 {
            var latest = Int.min
            for ch in 2..<channelCount { latest = max(latest, lastActive[ch]) }
            needUpmix = latest + holdFrames + 1 - clock <= warmupFrames
        }
        if needUpmix {
            if !upmixRunning { upmixer.reset(); upmixRunning = true }
            upmixer.process(left: inputs[0], right: inputs[1], frames: frames, outputs: upOut)
        } else {
            upmixRunning = false
        }

        // 6. Speaker feeds.
        let useUpmix = !adaptive || ramping || weight == 0
        let useBed = adaptive && (ramping || weight == 1)
        let generateLFE = settings.upmix.generateLFE
        for s in 0..<Layout.loopback.count { feeds[s] = nil }
        var lfeFeed: UnsafeMutablePointer<Float>?
        if useUpmix {
            for (j, speaker) in Layout.upmix.enumerated() {
                if speaker.isLFE { if generateLFE { lfeFeed = upOut[j] }; continue }
                feeds[speaker.rawValue] = upOut[j]
            }
        }
        if useBed {
            for ch in 0..<channelCount {
                let speaker = Layout.loopback[ch]
                let bed = delayed[ch]
                let up = speaker.isLFE ? lfeFeed : feeds[ch]
                var out = bed
                if ramping {
                    // (1 − w)·upmix + w·bed, sample by sample.
                    let m = mix[ch]
                    if let up {
                        for i in 0..<frames { m[i] = up[i] * (1 - ramp[i]) + bed[i] * ramp[i] }
                    } else {
                        vDSP_vmul(bed, 1, ramp, 1, m, 1, n)
                    }
                    out = m
                }
                if speaker.isLFE { lfeFeed = out } else { feeds[ch] = out }
            }
            if ramping {
                // Upmix-only speakers fade out.
                for (j, speaker) in Layout.upmix.enumerated() where speaker.rawValue >= channelCount && !speaker.isLFE {
                    let m = mix[speaker.rawValue]
                    let up = upOut[j]
                    for i in 0..<frames { m[i] = up[i] * (1 - ramp[i]) }
                    feeds[speaker.rawValue] = m
                }
            }
        }
        // Exact silence costs nothing downstream.
        for s in 0..<Layout.loopback.count {
            if let f = feeds[s] {
                var p: Float = 0
                vDSP_maxmgv(f, 1, &p, n)
                if p == 0 { feeds[s] = nil }
            }
        }

        // 7. Binaural render + LFE + room.
        let mode = settings.renderMode
        let dry = mode == .off
        let direct = dbToGain(mode.directDB)
        let send = dry ? 0 : dbToGain(mode.sendDB)
        vDSP_vclr(spatL, 1, n); vDSP_vclr(spatR, 1, n)
        vDSP_vclr(sendL, 1, n); vDSP_vclr(sendR, 1, n)
        head.process(feeds: feeds, frames: frames, direct: direct, send: send, dry: dry,
                     outL: spatL, outR: spatR, sendL: sendL, sendR: sendR)

        if let x = lfeFeed {
            var g = lfeGain
            vDSP_vsmul(x, 1, &g, lfeBuf, 1, n)
            lfeSilent = 0
        } else if lfeSilent < dormantAfter {
            vDSP_vclr(lfeBuf, 1, n)
            lfeSilent += frames
            if lfeSilent >= dormantAfter { lfe.reset() }
        }
        if lfeSilent < dormantAfter {
            lfe.run(lfeBuf, frames)
            vDSP_vadd(spatL, 1, lfeBuf, 1, spatL, 1, n)
            vDSP_vadd(spatR, 1, lfeBuf, 1, spatR, 1, n)
        }

        if !dry {
            var sendPeak: Float = 0, p: Float = 0
            vDSP_maxmgv(sendL, 1, &sendPeak, n)
            vDSP_maxmgv(sendR, 1, &p, n)
            sendPeak = max(sendPeak, p)
            roomSilent = sendPeak == 0 ? roomSilent + frames : 0
            if roomSilent < dormantAfter {
                room.process(sendL: sendL, sendR: sendR, addingTo: spatL, spatR, frames: frames)
            } else if roomSilent - frames < dormantAfter {
                room.reset()
            }
        }

        // 8. Original, time-aligned (only while it's audible).
        let needOriginal = !(crossfade == 1 && spatialTarget == 1)
        if needOriginal {
            if !adaptive || (!ramping && weight == 0) {
                origL.update(from: delayed[0], count: frames)
                origR.update(from: delayed[1], count: frames)
            } else {
                foldDown(frames: frames)
                if ramping {
                    let l = delayed[0], r = delayed[1]
                    for i in 0..<frames {
                        origL[i] = l[i] * (1 - ramp[i]) + origL[i] * ramp[i]
                        origR[i] = r[i] * (1 - ramp[i]) + origR[i] * ramp[i]
                    }
                }
            }
        }

        // 9. Loudness-matched Spatial ↔ Original, output gain, limiter.
        let makeup = dbToGain(mode.makeupDB)
        var gain = dbToGain(settings.outputGainDB)
        if !needOriginal {
            var m = makeup
            vDSP_vsmul(spatL, 1, &m, outL, 1, n); vDSP_vsmul(spatR, 1, &m, outR, 1, n)
            vDSP_vsmul(outL, 1, &gain, outL, 1, n); vDSP_vsmul(outR, 1, &gain, outR, 1, n)
        } else {
            var d = spatialTarget - crossfade
            let r = 1 - crossfadeCoef
            for i in 0..<frames {
                d *= r
                let xf = spatialTarget - d
                let s = xf * makeup
                let o = 1 - xf
                outL[i] = (spatL[i] * s + origL[i] * o) * gain
                outR[i] = (spatR[i] * s + origR[i] * o) * gain
            }
            crossfade = abs(d) < 1e-6 ? spatialTarget : spatialTarget - d
        }
        limiter.transparent = spatialTarget == 0 && crossfade < 1e-4 && gain <= 1
        limiter.process(outL, outR, frames: frames)

        var pl: Float = 0, pr: Float = 0
        vDSP_maxmgv(outL, 1, &pl, n)
        vDSP_maxmgv(outR, 1, &pr, n)
        outPeakBits.store(max(pl, pr).bitPattern, ordering: .relaxed)
    }

    /// Conventional fold of the delayed bed to stereo (the Original of surround content).
    private func foldDown(frames: Int) {
        let n = vDSP_Length(frames)
        vDSP_vclr(origL, 1, n); vDSP_vclr(origR, 1, n)
        for ch in 0..<channelCount {
            var gl = foldL[ch], gr = foldR[ch]
            if gl != 0 { vDSP_vsma(delayed[ch], 1, &gl, origL, 1, origL, 1, n) }
            if gr != 0 { vDSP_vsma(delayed[ch], 1, &gr, origR, 1, origR, 1, n) }
        }
        if foldScale != 1 {
            var s = foldScale
            vDSP_vsmul(origL, 1, &s, origL, 1, n)
            vDSP_vsmul(origR, 1, &s, origR, 1, n)
        }
    }

    /// Signal is back after a dormant stretch: start from the state 3 s of silence leaves.
    private func wake(target: Float, spatialTarget: Float) {
        dormant = false
        dormantFlag.store(false, ordering: .relaxed)
        silentFrames = 0
        upmixer.reset()
        upmixRunning = true
        head.reset()
        room.reset()
        roomSilent = 0
        lfe.reset()
        lfeSilent = Int.max
        limiter.reset()
        for r in ring { vDSP_vclr(r, 1, vDSP_Length(ringMask + 1)) }
        weight = adaptive ? target : 0
        crossfade = spatialTarget
    }
}
