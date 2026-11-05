import Accelerate
import Foundation

/// Synthetic-HRTF cues for one direction: Woodworth ITD, contralateral head shadow with
/// a rear term, and an elevation notch at 8.2 kHz. Built from published psychoacoustics,
/// not a measured HRIR set and not Dolby's renderer.
struct Cue {
    var shadowCutoffL: Double
    var shadowCutoffR: Double
    var notchGainDB: Double
    var delayL: Float
    var delayR: Float
    var ildL: Float
    var ildR: Float
    /// Constant-power lateral pan (room sends and the Dry mode).
    var panL: Float
    var panR: Float

    static let headRadius = 0.0875
    static let speedOfSound = 343.0
    static let maxITD = headRadius / speedOfSound * (.pi + 1)
    /// Largest ITD of the refined model (a source at ±90°): (a/c)(π/2 + 1) ≈ 0.656 ms.
    static let maxLateralITD = headRadius / speedOfSound * (.pi / 2 + 1)

    init(azimuth: Double, elevation: Double, sampleRate: Double, renderer: Renderer) {
        switch renderer {
        case .classic: self.init(classicAzimuth: azimuth, elevation: elevation, sampleRate: sampleRate)
        case .refined: self.init(refinedAzimuth: azimuth, elevation: elevation, sampleRate: sampleRate)
        }
    }

    /// Spherical-head cues from the true interaural (lateral) angle: θ = asin(|sin az · cos el|).
    /// Woodworth ITD (a/c)(θ + sin θ) rises to ±90° and falls back to zero behind the head;
    /// a height speaker sits closer to the median plane than the speaker below it, so it gets
    /// less ITD and shadow. Ear-plane speakers from −90° to 90° get exactly the classic values.
    private init(refinedAzimuth azimuth: Double, elevation: Double, sampleRate: Double) {
        let az = azimuth * .pi / 180, el = elevation * .pi / 180
        let raw = sin(az) * cos(el)                          // signed: + = right
        let sinLat = abs(raw) < 1e-12 ? 0 : raw              // exactly 0 at 0° and 180°
        let theta = asin(min(abs(sinLat), 1))
        let rear = max(0, (abs(azimuth) / 180 - 0.5) * 2) * cos(el)
        let shadowLeft = min(max(max(sinLat, 0) * 0.95 + rear * 0.35, 0), 1)
        let shadowRight = min(max(max(-sinLat, 0) * 0.95 + rear * 0.35, 0), 1)
        let elevationNorm = min(max(elevation / 60.0, 0), 1)
        let itdSeconds = Cue.headRadius / Cue.speedOfSound * (theta + abs(sinLat))
        let panAngle = (sinLat + 1) * .pi / 4
        shadowCutoffL = 18000 * pow(1100.0 / 18000.0, shadowLeft)
        shadowCutoffR = 18000 * pow(1100.0 / 18000.0, shadowRight)
        notchGainDB = -5.0 * elevationNorm
        delayL = sinLat > 0 ? Float(itdSeconds * sampleRate) : 0
        delayR = sinLat < 0 ? Float(itdSeconds * sampleRate) : 0
        ildL = Float(1 - 0.28 * shadowLeft)
        ildR = Float(1 - 0.28 * shadowRight)
        panL = Float(cos(panAngle))
        panR = Float(sin(panAngle))
    }

    /// Sfera 1.0's cues (kept exactly): ITD from the raw azimuth, so it keeps growing behind
    /// the head, and heights take the ear-plane cues of their azimuth.
    private init(classicAzimuth azimuth: Double, elevation: Double, sampleRate: Double) {
        let lateral = sin(azimuth * .pi / 180)
        let rear = max(0, (abs(azimuth) / 180 - 0.5) * 2)
        let shadowLeft = min(max(max(lateral, 0) * 0.95 + rear * 0.35, 0), 1)
        let shadowRight = min(max(max(-lateral, 0) * 0.95 + rear * 0.35, 0), 1)
        let elevationNorm = min(max(elevation / 60.0, 0), 1)
        let itdSeconds = abs(Cue.maxITD * (abs(azimuth) * .pi / 180 + sin(abs(azimuth) * .pi / 180)) / (.pi + 1))
        let panAngle = (lateral + 1) * .pi / 4
        shadowCutoffL = 18000 * pow(1100.0 / 18000.0, shadowLeft)
        shadowCutoffR = 18000 * pow(1100.0 / 18000.0, shadowRight)
        notchGainDB = -5.0 * elevationNorm
        delayL = azimuth > 0 ? Float(itdSeconds * sampleRate) : 0
        delayR = azimuth < 0 ? Float(itdSeconds * sampleRate) : 0
        ildL = Float(1 - 0.28 * shadowLeft)
        ildR = Float(1 - 0.28 * shadowRight)
        panL = Float(cos(panAngle))
        panR = Float(sin(panAngle))
    }

    /// Refined elevation cue, relative to the ear plane: the pinna's first notch moves up with
    /// elevation (≈ 6.5–7 kHz in front, ≈ 10–11 kHz at 60°; Iida et al. 2007), so a raised
    /// source gains energy around 7 kHz (Blauert's "above" band) and loses it higher up.
    /// Below the ear plane the notch moves down instead. Identity at 0°.
    static func elevationFilters(elevation: Double, sampleRate: Double) -> (Biquad, Biquad) {
        let e = min(max(elevation / 60, -1), 1)
        if e >= 0 {
            return (.peaking(7000, gainDB: 5 * e, q: 1.8, sampleRate: sampleRate),
                    .peaking(8000 * (1 + 0.35 * e), gainDB: -8 * e, q: 3, sampleRate: sampleRate))
        }
        return (.peaking(7000, gainDB: 3 * e, q: 1.8, sampleRate: sampleRate),
                .peaking(8000 * (1 + 0.3 * e), gainDB: 6 * e, q: 3, sampleRate: sampleRate))
    }

    /// Refined: every bed speaker is equidistant, as the mix assumes (the ear-plane value of
    /// `distanceGain`). Classic's elevated speakers came out up to 2.5 dB louder.
    static let equalDistanceGain = Float(1 / 1.7)

    /// 1 / (1 + 0.7·r), r = horizontal radius of the speaker on the unit sphere
    /// (elevated speakers sit closer to the head axis, so they're a little louder).
    static func distanceGain(azimuth: Double, elevation: Double) -> Float {
        let az = azimuth * .pi / 180.0
        let el = elevation * .pi / 180.0 * (90.0 / 60.0)
        let horizontal = cos(el)
        let x = min(max(sin(az) * horizontal, -1), 1)
        let y = min(max(-cos(az) * horizontal, -1), 1)
        let radius = min(1.0, (x * x + y * y).squareRoot())
        return Float(1.0 / (1.0 + 0.7 * radius))
    }
}

/// Linear-interpolating fractional delay with a constant delay. The read positions and
/// weights for each write slot are precomputed, so the per-sample path is two loads and
/// a multiply-add.
struct FractionalDelay {
    /// Sfera 1.0's fixed size: delays are clamped to 127 samples (the classic renderer keeps it).
    static let classicLength = 129
    let length: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let index0: UnsafeMutablePointer<Int>, index1: UnsafeMutablePointer<Int>
    private let weight0: UnsafeMutablePointer<Float>, weight1: UnsafeMutablePointer<Float>
    var write = 0

    /// `length` slots hold delays up to `length − 2` samples.
    init(delay: Float, length: Int = FractionalDelay.classicLength) {
        self.length = length
        let n = length
        buffer = makeBuffer(n)
        index0 = .allocate(capacity: n); index1 = .allocate(capacity: n)
        weight0 = .allocate(capacity: n); weight1 = .allocate(capacity: n)
        let d = min(max(delay, 0), Float(n - 2))
        for w in 0..<n {
            let readPos = Float(w) - d
            var wrapped = readPos < 0 ? readPos + Float(n) : readPos
            if wrapped >= Float(n) { wrapped -= Float(n) }
            if wrapped < 0 { wrapped += Float(n) }
            let i0 = min(max(Int(wrapped), 0), n - 1)
            let frac = wrapped - Float(i0)
            index0[w] = i0
            index1[w] = (i0 + 1) % n
            weight0[w] = 1 - frac
            weight1[w] = frac
        }
    }

    func free() {
        buffer.deallocate(); index0.deallocate(); index1.deallocate(); weight0.deallocate(); weight1.deallocate()
    }

    mutating func reset() {
        vDSP_vclr(buffer, 1, vDSP_Length(length))
        write = 0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let w = write
        buffer[w] = x
        let y = buffer[index0[w]] * weight0[w] + buffer[index1[w]] * weight1[w]
        write = w + 1 == length ? 0 : w + 1
        return y
    }
}

/// Renders speaker feeds to two ears.
///
/// The model is linear and time-invariant per direction. Classic: speakers that share an
/// azimuth (L and Ltf, C/Cts/Cfh, Lrs and Ltr…) are summed before one shared
/// head-shadow + ITD chain; speakers at the same elevation share one notch, which both
/// ears use. Refined: a height speaker has its own lateral angle, so every direction
/// (azimuth and elevation) gets its own chain. A chain whose feeds have been silent for a
/// second goes idle and costs nothing.
final class HeadRenderer {
    private final class Bus {
        let members: [(speaker: Int, distance: Float)]
        var notch: Biquad
        /// Refined: the moving pinna notch (the boost is `notch`).
        var extra: Biquad?
        var silentFrames = Int.max
        init(members: [(Int, Float)], notch: Biquad, extra: Biquad? = nil) {
            self.members = members; self.notch = notch; self.extra = extra
        }
    }

    private final class Group {
        let cue: Cue
        let shadowL: Float, shadowR: Float
        var stateL: Float = 0, stateR: Float = 0
        var farDelay: FractionalDelay?
        let farIsLeft: Bool
        /// Speakers in the ear plane (no notch).
        let plain: [(speaker: Int, distance: Float)]
        /// Elevated speakers, one bus per elevation.
        let buses: [Bus]
        var silentFrames = Int.max

        init(cue: Cue, sampleRate: Double, plain: [(Int, Float)], buses: [Bus], delayLength: Int) {
            self.cue = cue
            shadowL = onePoleCoefficient(cue.shadowCutoffL, sampleRate: sampleRate)
            shadowR = onePoleCoefficient(cue.shadowCutoffR, sampleRate: sampleRate)
            farIsLeft = cue.delayL > 0
            let delay = max(cue.delayL, cue.delayR)
            farDelay = delay > 0 ? FractionalDelay(delay: delay, length: delayLength) : nil
            self.plain = plain
            self.buses = buses
        }

        func reset() {
            stateL = 0; stateR = 0
            farDelay?.reset()
            for bus in buses { bus.notch.reset(); bus.extra?.reset() }
        }
    }

    private let groups: [Group]
    private let maxFrames: Int
    private let groupBuffer: UnsafeMutablePointer<Float>
    private let busBuffer: UnsafeMutablePointer<Float>
    private let idleAfter: Int
    /// Direction of each chain (azimuth, elevation in degrees), in the order of `groupSends`.
    let groupDirections: [(azimuth: Double, elevation: Double)]

    /// `speakers`: the feeds this renderer can receive (LFE excluded).
    init(speakers: [Speaker], sampleRate: Double, maxFrames: Int, renderer: Renderer = .classic) {
        self.maxFrames = maxFrames
        groupBuffer = makeBuffer(maxFrames)
        busBuffer = makeBuffer(maxFrames)
        idleAfter = Int(sampleRate)
        // Classic clamps delays at 127 samples (it asks for more at 176.4/192 kHz); refined
        // sizes the line for its largest ITD at this rate.
        let delayLength = renderer == .classic ? FractionalDelay.classicLength
            : max(FractionalDelay.classicLength, Int((Cue.maxLateralITD * sampleRate).rounded(.up)) + 3)
        // Classic: one chain per azimuth, cues from the ear plane. Refined: one per direction.
        struct Key: Hashable, Comparable {
            let azimuth: Double, elevation: Double
            static func < (a: Key, b: Key) -> Bool { (a.azimuth, a.elevation) < (b.azimuth, b.elevation) }
        }
        var byKey: [Key: [Speaker]] = [:]
        for s in speakers where !s.isLFE {
            byKey[Key(azimuth: s.azimuth, elevation: renderer == .classic ? 0 : s.elevation), default: []].append(s)
        }
        groups = byKey.keys.sorted().map { key in
            let azimuth = key.azimuth
            let members = byKey[key]!.sorted { $0.rawValue < $1.rawValue }
            let cue = Cue(azimuth: azimuth, elevation: key.elevation, sampleRate: sampleRate, renderer: renderer)
            func distance(_ s: Speaker) -> Float {
                renderer == .classic ? Cue.distanceGain(azimuth: s.azimuth, elevation: s.elevation) : Cue.equalDistanceGain
            }
            let plain = members.filter { !$0.isHeight }.map { ($0.rawValue, distance($0)) }
            var byElevation: [Double: [Speaker]] = [:]
            for s in members where s.isHeight { byElevation[s.elevation, default: []].append(s) }
            let buses = byElevation.keys.sorted().map { elevation in
                let members = byElevation[elevation]!.map { ($0.rawValue, distance($0)) }
                if renderer == .refined {
                    let (boost, notch) = Cue.elevationFilters(elevation: elevation, sampleRate: sampleRate)
                    return Bus(members: members, notch: boost, extra: notch)
                }
                let gainDB = Cue(azimuth: azimuth, elevation: elevation, sampleRate: sampleRate, renderer: renderer).notchGainDB
                return Bus(members: members, notch: .peaking(8200, gainDB: gainDB, q: 1.3, sampleRate: sampleRate))
            }
            return Group(cue: cue, sampleRate: sampleRate, plain: plain, buses: buses, delayLength: delayLength)
        }
        groupDirections = byKey.keys.sorted().map { ($0.azimuth, $0.elevation) }
    }

    deinit {
        groupBuffer.deallocate()
        busBuffer.deallocate()
        for g in groups { g.farDelay?.free() }
    }

    func reset() {
        for g in groups {
            g.reset()
            g.silentFrames = Int.max
            for b in g.buses { b.silentFrames = Int.max }
        }
    }

    /// Adds the binaural render of `feeds` (indexed by `Speaker.rawValue`; nil = silent)
    /// to `outL/outR`, and the room send to `sendL/sendR`.
    /// `direct`: direct-path level; `send`: room send level (0 = no room).
    /// `groupSends` (optional): each chain's own mono send, for a room with source-dependent
    /// reflections; `groupActive[i]` says whether chain i wrote one this block.
    func process(feeds: UnsafePointer<UnsafeMutablePointer<Float>?>, frames: Int,
                 direct: Float, send: Float, dry: Bool,
                 outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>,
                 sendL: UnsafeMutablePointer<Float>, sendR: UnsafeMutablePointer<Float>,
                 groupSends: UnsafePointer<UnsafeMutablePointer<Float>>? = nil,
                 groupActive: UnsafeMutablePointer<Bool>? = nil) {
        let n = vDSP_Length(frames)
        let gbuf = groupBuffer, bbuf = busBuffer

        for (gi, g) in groups.enumerated() {
            groupActive?[gi] = false
            // This chain's own room send (un-notched, like the lateral bus).
            @inline(__always) func addSend(_ x: UnsafeMutablePointer<Float>) {
                guard let groupSends, let groupActive, send > 0 else { return }
                var s = send
                if groupActive[gi] { vDSP_vsma(x, 1, &s, groupSends[gi], 1, groupSends[gi], 1, n) }
                else { vDSP_vsmul(x, 1, &s, groupSends[gi], 1, n) }
                groupActive[gi] = true
            }
            // Plain members → group buffer.
            var any = false
            for m in g.plain {
                guard let x = feeds[m.speaker] else { continue }
                var gain = direct * m.distance
                if any { vDSP_vsma(x, 1, &gain, gbuf, 1, gbuf, 1, n) } else { vDSP_vsmul(x, 1, &gain, gbuf, 1, n) }
                any = true
            }

            if dry {
                // Dry: constant-power stereo pan of every member, no HRTF and no room.
                for b in g.buses {
                    for m in b.members {
                        guard let x = feeds[m.speaker] else { continue }
                        var gain = direct * m.distance
                        if any { vDSP_vsma(x, 1, &gain, gbuf, 1, gbuf, 1, n) } else { vDSP_vsmul(x, 1, &gain, gbuf, 1, n) }
                        any = true
                    }
                }
                guard any else { continue }
                var pl = g.cue.panL, pr = g.cue.panR
                vDSP_vsma(gbuf, 1, &pl, outL, 1, outL, 1, n)
                vDSP_vsma(gbuf, 1, &pr, outR, 1, outR, 1, n)
                continue
            }

            // Room send uses the un-notched feeds.
            var sl = g.cue.panL * send, sr = g.cue.panR * send
            if any, send > 0 {
                vDSP_vsma(gbuf, 1, &sl, sendL, 1, sendL, 1, n)
                vDSP_vsma(gbuf, 1, &sr, sendR, 1, sendR, 1, n)
                addSend(gbuf)
            }

            // Elevated members: sum per elevation, shared notch, into the group buffer.
            for b in g.buses {
                var busAny = false
                for m in b.members {
                    guard let x = feeds[m.speaker] else { continue }
                    var gain = direct * m.distance
                    if busAny { vDSP_vsma(x, 1, &gain, bbuf, 1, bbuf, 1, n) } else { vDSP_vsmul(x, 1, &gain, bbuf, 1, n) }
                    busAny = true
                }
                if busAny {
                    b.silentFrames = 0
                } else {
                    if b.silentFrames >= idleAfter { continue }
                    b.silentFrames += frames
                    if b.silentFrames >= idleAfter { b.notch.reset(); continue }
                    vDSP_vclr(bbuf, 1, n)
                }
                if send > 0 {
                    vDSP_vsma(bbuf, 1, &sl, sendL, 1, sendL, 1, n)
                    vDSP_vsma(bbuf, 1, &sr, sendR, 1, sendR, 1, n)
                    if busAny { addSend(bbuf) }
                }
                b.notch.run(bbuf, frames)
                if b.extra != nil { b.extra!.run(bbuf, frames) }
                if any { vDSP_vadd(gbuf, 1, bbuf, 1, gbuf, 1, n) } else { gbuf.update(from: bbuf, count: frames) }
                any = true
            }

            // Idle tracking: a chain fed silence for a second has decayed to nothing.
            if any {
                g.silentFrames = 0
            } else {
                if g.silentFrames >= idleAfter { continue }
                g.silentFrames += frames
                if g.silentFrames >= idleAfter { g.reset(); continue }
                vDSP_vclr(gbuf, 1, n)
            }

            // Head shadow per ear, ITD on the far ear, interaural level difference.
            let cl = g.shadowL, cr = g.shadowR
            let ildL = g.cue.ildL, ildR = g.cue.ildR
            var yl = g.stateL, yr = g.stateR
            if var delay = g.farDelay {
                if g.farIsLeft {
                    for i in 0..<frames {
                        let x = gbuf[i]
                        yl += cl * (x - yl)
                        yr += cr * (x - yr)
                        outL[i] += delay.process(yl) * ildL
                        outR[i] += yr * ildR
                    }
                } else {
                    for i in 0..<frames {
                        let x = gbuf[i]
                        yl += cl * (x - yl)
                        yr += cr * (x - yr)
                        outL[i] += yl * ildL
                        outR[i] += delay.process(yr) * ildR
                    }
                }
                g.farDelay = delay
            } else {
                for i in 0..<frames {
                    let x = gbuf[i]
                    yl += cl * (x - yl)
                    yr += cr * (x - yr)
                    outL[i] += yl * ildL
                    outR[i] += yr * ildR
                }
            }
            g.stateL = yl
            g.stateR = yr
        }
    }
}
