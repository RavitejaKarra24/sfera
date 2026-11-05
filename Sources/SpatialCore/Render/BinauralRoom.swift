import Foundation

/// Virtual listening room for the binaural renderer.
///
/// A dry HRTF render localises inside the head; a small amount of direction-coded
/// room sound is what moves the image out in front of the listener. Sources feed a
/// shared send pair (left/right-panned), scaled by their binaural render mode
/// (Near < Mid < Far). The bus produces:
///
/// 1. Eight early reflections from image-source directions around the listener,
///    each with its own interaural delay and far-ear head shadow.
/// 2. A late tail from an 8-line Hadamard feedback delay network (≈0.42 s RT60,
///    frequency-dependent damping), with orthogonal output taps for a decorrelated
///    left/right pair.
///
/// Independent design from the published early-reflection/FDN literature
/// (Jot & Chaigne 1991; Begault 1994). Not Dolby's virtual room.
public enum BinauralRoom {
    /// Offline convenience: runs whole send buffers through a fresh `BinauralRoomProcessor`.
    public static func process(sendL: [Float], sendR: [Float], sampleRate: Double, rt60: Double = 0.42) -> (left: [Float], right: [Float]) {
        let frames = min(sendL.count, sendR.count)
        var outL = [Float](repeating: 0, count: frames)
        var outR = [Float](repeating: 0, count: frames)
        guard frames > 0 else { return (outL, outR) }
        let room = BinauralRoomProcessor(sampleRate: sampleRate, rt60: rt60)
        sendL.withUnsafeBufferPointer { l in
            sendR.withUnsafeBufferPointer { r in
                outL.withUnsafeMutableBufferPointer { ol in
                    outR.withUnsafeMutableBufferPointer { or in
                        room.process(sendL: l.baseAddress!, sendR: r.baseAddress!,
                                     addingTo: ol.baseAddress!, or.baseAddress!, frames: frames)
                    }
                }
            }
        }
        return (outL, outR)
    }
}

/// Streaming form of the virtual room. Allocation-free after init; safe to call from
/// a real-time audio thread with any block size.
public final class BinauralRoomProcessor {
    private struct Reflection {
        var nearDelay: Int
        var farDelay: Int
        var nearGain: Float
        var farGain: Float
        var side: Int          // −1 left send, +1 right send, 0 both
        var rightIsNear: Bool
        var shadow: OnePole
    }

    private static let layout: [(azimuth: Double, delayMS: Double, gain: Float, side: Int)] = [
        (-55, 8.7, 0.62, -1),
        (60, 10.3, 0.60, 1),
        (0, 12.9, 0.48, 0),     // ceiling
        (-115, 16.4, 0.45, -1),
        (120, 18.1, 0.44, 1),
        (-85, 22.6, 0.36, -1),
        (90, 25.2, 0.35, 1),
        (180, 29.8, 0.30, 0),   // back wall
    ]
    private static let fdnDelays48k = [1031, 1327, 1523, 1801, 2053, 2311, 2579, 2861]

    private var hpL: Biquad, hpR: Biquad
    private var lpL = OnePole(), lpR = OnePole()
    private var reflections: [Reflection] = []

    // Bus history for reflections and FDN predelay.
    private let historyMask: Int
    private let busL: UnsafeMutablePointer<Float>
    private let busR: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private let predelay: Int

    // FDN
    private let delays: [Int]
    private let lines: [UnsafeMutablePointer<Float>]
    private var heads = [Int](repeating: 0, count: 8)
    private let feedback: [Float]
    private var damping: [OnePole]
    private let norm = Float(1 / 8.0.squareRoot())
    private let lateGain: Float = 0.32 * 0.35

    public init(sampleRate: Double, rt60: Double = 0.42) {
        hpL = Biquad.highPass(frequency: 160, sampleRate: sampleRate)
        hpR = Biquad.highPass(frequency: 160, sampleRate: sampleRate)
        lpL.setCutoff(7000, sampleRate: sampleRate)
        lpR.setCutoff(7000, sampleRate: sampleRate)

        let headDelay = 0.0875 / 343.0
        var longest = 0
        for r in Self.layout {
            let theta = abs(r.azimuth) * .pi / 180
            let itd = headDelay * (min(theta, .pi / 2) + sin(theta)) * sampleRate
            let base = Int(r.delayMS / 1000 * sampleRate)
            let lateral = abs(sin(theta))
            var shadow = OnePole()
            shadow.setCutoff(18000 * pow(1800.0 / 18000.0, lateral), sampleRate: sampleRate)
            let far = base + Int(itd.rounded())
            longest = max(longest, far)
            reflections.append(Reflection(
                nearDelay: base, farDelay: far,
                nearGain: r.gain, farGain: r.gain * Float(1 - 0.45 * lateral),
                side: r.side, rightIsNear: r.azimuth > 0, shadow: shadow
            ))
        }
        predelay = Int(0.018 * sampleRate)
        var size = 1
        while size < max(longest, predelay) + 2 { size <<= 1 }
        historyMask = size - 1
        busL = .allocate(capacity: size); busL.initialize(repeating: 0, count: size)
        busR = .allocate(capacity: size); busR.initialize(repeating: 0, count: size)

        let scale = sampleRate / 48000
        delays = Self.fdnDelays48k.map { max(64, Int(Double($0) * scale)) }
        lines = delays.map { d in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: d)
            p.initialize(repeating: 0, count: d)
            return p
        }
        feedback = delays.map { Float(pow(10, -3 * Double($0) / (rt60 * sampleRate))) }
        damping = (0..<8).map { _ in
            var p = OnePole(); p.setCutoff(5200, sampleRate: sampleRate); return p
        }
    }

    deinit {
        busL.deallocate(); busR.deallocate()
        for line in lines { line.deallocate() }
    }

    /// Adds the room response to `outL`/`outR` for `frames` samples of send input.
    public func process(sendL: UnsafePointer<Float>, sendR: UnsafePointer<Float>,
                        addingTo outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, frames: Int) {
        let mask = historyMask
        var state = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
        for i in 0..<frames {
            // Condition the bus: keep low end out of the room, soften the top (wall absorption).
            let bl = lpL.process(hpL.process(sendL[i]))
            let br = lpR.process(hpR.process(sendR[i]))
            let w = writeIndex
            busL[w] = bl
            busR[w] = br

            // 1. Early reflections (read the bus history at each reflection's delay).
            var l: Float = 0, r: Float = 0
            for j in 0..<reflections.count {
                let near = reflections[j].nearDelay, far = reflections[j].farDelay
                let xn: Float, xf: Float
                switch reflections[j].side {
                case -1: xn = busL[(w - near) & mask]; xf = busL[(w - far) & mask]
                case 1: xn = busR[(w - near) & mask]; xf = busR[(w - far) & mask]
                default:
                    xn = 0.5 * (busL[(w - near) & mask] + busR[(w - near) & mask])
                    xf = 0.5 * (busL[(w - far) & mask] + busR[(w - far) & mask])
                }
                let shadowed = reflections[j].shadow.process(xf)
                if reflections[j].rightIsNear {
                    r += xn * reflections[j].nearGain
                    l += shadowed * reflections[j].farGain
                } else {
                    l += xn * reflections[j].nearGain
                    r += shadowed * reflections[j].farGain
                }
            }

            // 2. Late tail: 8-line FDN, order-8 Walsh–Hadamard feedback.
            let inL = busL[(w - predelay) & mask]
            let inR = busR[(w - predelay) & mask]
            let s0 = lines[0][heads[0]], s1 = lines[1][heads[1]], s2 = lines[2][heads[2]], s3 = lines[3][heads[3]]
            let s4 = lines[4][heads[4]], s5 = lines[5][heads[5]], s6 = lines[6][heads[6]], s7 = lines[7][heads[7]]
            l += (s0 + s1 + s2 + s3 - s4 - s5 - s6 - s7) * lateGain
            r += (s0 - s1 + s2 - s3 + s4 - s5 + s6 - s7) * lateGain
            // Fast Walsh–Hadamard transform.
            let a0 = s0 + s1, a1 = s0 - s1, a2 = s2 + s3, a3 = s2 - s3
            let a4 = s4 + s5, a5 = s4 - s5, a6 = s6 + s7, a7 = s6 - s7
            let b0 = a0 + a2, b1 = a1 + a3, b2 = a0 - a2, b3 = a1 - a3
            let b4 = a4 + a6, b5 = a5 + a7, b6 = a4 - a6, b7 = a5 - a7
            state = (b0 + b4, b1 + b5, b2 + b6, b3 + b7, b0 - b4, b1 - b5, b2 - b6, b3 - b7)
            write(0, state.0, input: inL)
            write(1, state.1, input: -inR)
            write(2, state.2, input: inL)
            write(3, state.3, input: -inR)
            write(4, state.4, input: inL)
            write(5, state.5, input: -inR)
            write(6, state.6, input: inL)
            write(7, state.7, input: -inR)

            outL[i] += l
            outR[i] += r
            writeIndex = (w + 1) & mask
        }
    }

    @inline(__always)
    private func write(_ j: Int, _ mixed: Float, input: Float) {
        let fed = damping[j].process(mixed * norm * feedback[j])
        lines[j][heads[j]] = fed + input
        heads[j] += 1
        if heads[j] == delays[j] { heads[j] = 0 }
    }
}
