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
/// Room mode and renderer changes dip the spatial output and the room's input for about
/// 10 ms, switch at silence and fade in again; the room's tail keeps decaying through the
/// switch (into Dry too), so it never comes back stale. Head filters restart from silence
/// when Dry is entered or left.
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

    /// One head renderer per `Renderer` (indexed by `headIndex`); only the active one runs.
    private let heads: [HeadRenderer]
    private let room: Room
    /// The Refined renderer's room: early reflections per speaker direction.
    private let refinedRoom: RefinedRoom
    private let groupSends: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let groupActive: UnsafeMutablePointer<Bool>
    private let groupCount: Int
    private var appliedSize: RoomSize
    private var roomSilent = 0
    private var lfe: Biquad
    private var lfeSilent = Int.max
    private let lfeGain = dbToGain(5.5) * 0.5
    private let limiter: Limiter

    private let feeds: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let mix: [UnsafeMutablePointer<Float>]
    private let ramp: UnsafeMutablePointer<Float>
    private let dipRamp: UnsafeMutablePointer<Float>
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

    // What is being rendered now; a different mode or renderer in `settings` dips to it.
    private var appliedMode: RoomMode
    private var appliedRenderer: Renderer
    private var dip: Float = 1
    private var dipping = false
    private let dipStep: Float
    /// A renderer change also dips the room's output (its reflection taps change).
    private var dipRoom = false
    /// The room-mode makeup now; it glides to a new mode's over the fade-in, because the
    /// room's tail rings on through a mode change.
    private var makeup: Float
    private var makeupStep: Float = 0
    /// Refined: the stereo ↔ bed crossfade is linear and finishes within the input delay.
    private let refinedFadeStep: Float

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
        let sortedSpeakers = speakers.sorted { $0.rawValue < $1.rawValue }
        heads = Renderer.allCases.map {
            HeadRenderer(speakers: sortedSpeakers, sampleRate: sampleRate, maxFrames: maxFrames, renderer: $0)
        }
        room = Room(sampleRate: sampleRate)
        let directions = heads[Self.headIndex(.refined)].groupDirections
        groupCount = directions.count
        refinedRoom = RefinedRoom(sampleRate: sampleRate, maxFrames: maxFrames, groups: directions)
        groupSends = .allocate(capacity: max(groupCount, 1))
        for g in 0..<groupCount { groupSends[g] = makeBuffer(maxFrames) }
        groupActive = .allocate(capacity: max(groupCount, 1))
        groupActive.initialize(repeating: false, count: max(groupCount, 1))
        appliedSize = settings.room.size
        refinedRoom.configure(size: appliedSize)
        refinedRoom.tune(settings.room)
        lfe = .lowPass(80, sampleRate: sampleRate)
        limiter = Limiter(sampleRate: sampleRate)
        latency = delay + limiter.latency

        let speakerCount = Layout.loopback.count
        feeds = .allocate(capacity: speakerCount)
        feeds.initialize(repeating: nil, count: speakerCount)
        mix = (0..<speakerCount).map { _ in makeBuffer(maxFrames) }
        ramp = makeBuffer(maxFrames)
        dipRamp = makeBuffer(maxFrames)
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
        appliedMode = settings.renderMode
        appliedRenderer = settings.renderer
        makeup = dbToGain(settings.renderMode.makeupDB)
        dipStep = Float(1 / (0.01 * sampleRate))
        // 30 ms, but always done 64 samples before a newly detected bed sample comes out of
        // the delay line (the detector sees it `delay` samples early).
        refinedFadeStep = 1 / Float(max(1, min(Int(0.03 * sampleRate), delay - 64)))
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
        for g in 0..<groupCount { groupSends[g].deallocate() }
        groupSends.deallocate(); groupActive.deallocate()
        feeds.deallocate()
        for p in [ramp, dipRamp, spatL, spatR, sendL, sendR, origL, origR, lfeBuf] { p.deallocate() }
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

        // Room mode / renderer change: once the dip has reached silence, switch.
        if changePending {
            // A new renderer or room size changes the room's taps: dip its output too.
            if settings.renderer != appliedRenderer || settings.room.size != appliedSize { dipRoom = true }
            if dip == 0 { applyRender() } else { dipping = true }
        }
        let renderer = appliedRenderer
        let refined = renderer == .refined
        upmixer.coherentSteering = refined
        limiter.exactRelease = refined

        // 4. Content crossfade weight (0 = upmix, 1 = bed).
        var ramping = false
        if adaptive, weight != target, refined {
            // Linear, done before the first delayed sample of a new bed arrives.
            ramping = true
            var w = weight
            let step = refinedFadeStep
            for i in 0..<frames {
                w = target > w ? min(target, w + step) : max(target, w - step)
                ramp[i] = w
            }
            weight = w
        } else if adaptive, weight != target {
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
        let mode = appliedMode
        let dry = mode == .off
        let direct = dbToGain(mode.directDB)
        let send = dry ? 0 : dbToGain(mode.sendDB)
        vDSP_vclr(spatL, 1, n); vDSP_vclr(spatR, 1, n)
        vDSP_vclr(sendL, 1, n); vDSP_vclr(sendR, 1, n)
        heads[Self.headIndex(renderer)].process(feeds: feeds, frames: frames, direct: direct, send: send, dry: dry,
                                               outL: spatL, outR: spatR, sendL: sendL, sendR: sendR,
                                               groupSends: refined ? UnsafePointer(groupSends) : nil,
                                               groupActive: refined ? groupActive : nil)

        if let x = lfeFeed {
            // Classic: the LFE skips the direct-path level, so it moves against the mains as the
            // room changes (+1.5 dB Near … +6 dB Far). Refined holds Far's balance in every
            // mode; in Dry the centre is panned at −3 dB per ear, so the LFE follows it.
            var g = refined ? lfeGain * dbToGain(mode.directDB - RoomMode.far.directDB) * (dry ? 0.70710678 : 1) : lfeGain
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
            if refined, send > 0 {
                // Refined: the LFE excites the room like a front speaker would, so the bass
                // balance holds with "bass in room" (the tail's input decides how much gets in).
                var k = send * 0.70710678
                vDSP_vsma(lfeBuf, 1, &k, sendL, 1, sendL, 1, n)
                vDSP_vsma(lfeBuf, 1, &k, sendR, 1, sendR, 1, n)
            }
        }

        // Dip: the direct path, LFE and the room's input fade towards a pending change (and
        // back in after it), so no gain or filter step reaches the room's echoes.
        let dipNow = dipping, dipAfterRoom = dipRoom
        if dipNow {
            fillDip(frames: frames)
            if !dipAfterRoom { vDSP_vmul(spatL, 1, dipRamp, 1, spatL, 1, n); vDSP_vmul(spatR, 1, dipRamp, 1, spatR, 1, n) }
            vDSP_vmul(sendL, 1, dipRamp, 1, sendL, 1, n); vDSP_vmul(sendR, 1, dipRamp, 1, sendR, 1, n)
            if refined {
                for g in 0..<groupCount where groupActive[g] { vDSP_vmul(groupSends[g], 1, dipRamp, 1, groupSends[g], 1, n) }
            }
        }

        // The room runs until its tail has died away, in Dry too (Dry sends nothing).
        do {
            var sendPeak: Float = 0, p: Float = 0
            vDSP_maxmgv(sendL, 1, &sendPeak, n)
            vDSP_maxmgv(sendR, 1, &p, n)
            sendPeak = max(sendPeak, p)
            roomSilent = sendPeak == 0 ? roomSilent + frames : 0
            if roomSilent < dormantAfter {
                if refined {
                    if dry { for g in 0..<groupCount { groupActive[g] = false } }
                    refinedRoom.tune(settings.room)
                    refinedRoom.process(groupSends: groupSends, groupActive: groupActive, sendL: sendL, sendR: sendR,
                                        addingTo: spatL, spatR, frames: frames)
                } else {
                    room.process(sendL: sendL, sendR: sendR, addingTo: spatL, spatR, frames: frames, renderer: renderer)
                }
            } else if roomSilent - frames < dormantAfter {
                room.reset()
                refinedRoom.reset()
            }
        }
        if dipNow, dipAfterRoom {
            vDSP_vmul(spatL, 1, dipRamp, 1, spatL, 1, n); vDSP_vmul(spatR, 1, dipRamp, 1, spatR, 1, n)
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
        let makeupTarget = dbToGain(mode.makeupDB)
        let gliding = makeup != makeupTarget
        if gliding {
            // dipRamp is free again: reuse it for the makeup glide.
            var m = makeup
            let step = makeupStep
            for i in 0..<frames {
                m = makeupTarget > m ? min(makeupTarget, m + step) : max(makeupTarget, m - step)
                dipRamp[i] = m
            }
            makeup = m
        }
        var gain = dbToGain(settings.outputGainDB)
        if !needOriginal {
            var m = makeup
            if gliding {
                vDSP_vmul(spatL, 1, dipRamp, 1, outL, 1, n); vDSP_vmul(spatR, 1, dipRamp, 1, outR, 1, n)
            } else {
                vDSP_vsmul(spatL, 1, &m, outL, 1, n); vDSP_vsmul(spatR, 1, &m, outR, 1, n)
            }
            vDSP_vsmul(outL, 1, &gain, outL, 1, n); vDSP_vsmul(outR, 1, &gain, outR, 1, n)
        } else {
            var d = spatialTarget - crossfade
            let r = 1 - crossfadeCoef
            for i in 0..<frames {
                d *= r
                let xf = spatialTarget - d
                let s = xf * (gliding ? dipRamp[i] : makeup)
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

    private static func headIndex(_ renderer: Renderer) -> Int { renderer == .classic ? 0 : 1 }

    /// The dip gain for this block: down to 0 while a change is pending, then up to 1 once it
    /// has been applied. When nothing is changing it isn't computed or applied at all.
    private func fillDip(frames: Int) {
        let pending = changePending
        let step = pending ? -dipStep : dipStep
        var g = dip
        for i in 0..<frames {
            g = min(max(g + step, 0), 1)
            dipRamp[i] = g
        }
        dip = g
        if !pending, g == 1 { dipping = false; dipRoom = false }
    }

    /// A room mode, renderer or (Refined) room size the output hasn't switched to yet.
    private var changePending: Bool {
        settings.renderMode != appliedMode || settings.renderer != appliedRenderer
            || (settings.renderer == .refined && settings.room.size != appliedSize)
    }

    /// Switches mode/renderer/size while the spatial path is silent.
    private func applyRender() {
        let mode = settings.renderMode, renderer = settings.renderer
        let dryChange = (mode == .off) != (appliedMode == .off)
        if renderer != appliedRenderer || dryChange {
            // A renderer that wasn't running, or Dry (which skips the head filters), holds
            // stale filter state: start it from silence.
            heads[Self.headIndex(renderer)].reset()
        }
        if renderer != appliedRenderer {
            // The incoming renderer's room hasn't been running: start it empty.
            if renderer == .refined { refinedRoom.reset() } else { room.reset() }
        }
        if renderer == .refined, settings.room.size != appliedSize {
            appliedSize = settings.room.size
            refinedRoom.configure(size: appliedSize)       // starts empty
        }
        appliedMode = mode
        appliedRenderer = renderer
        makeupStep = abs(dbToGain(mode.makeupDB) - makeup) * dipStep
        dipping = true                       // fade back in
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
        for h in heads { h.reset() }
        room.reset()
        if settings.room.size != appliedSize { appliedSize = settings.room.size; refinedRoom.configure(size: appliedSize) }
        refinedRoom.reset()
        roomSilent = 0
        lfe.reset()
        lfeSilent = Int.max
        limiter.reset()
        for r in ring { vDSP_vclr(r, 1, vDSP_Length(ringMask + 1)) }
        weight = adaptive ? target : 0
        crossfade = spatialTarget
        appliedMode = settings.renderMode
        appliedRenderer = settings.renderer
        makeup = dbToGain(settings.renderMode.makeupDB)
        dip = 1
        dipping = false
        dipRoom = false
    }
}
