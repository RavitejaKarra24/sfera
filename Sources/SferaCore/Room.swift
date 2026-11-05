import Accelerate
import Foundation

/// Virtual listening room for the binaural image.
///
/// A dry HRTF render localises inside the head; a little direction-coded room sound moves
/// it out in front. The send bus (HP 160 Hz, LP 7 kHz) feeds eight early reflections
/// (8.7–29.8 ms, each with its own ITD and far-ear shadow) and an 8-line Hadamard FDN
/// (RT60 0.42 s, 5.2 kHz damping, 18 ms predelay) with orthogonal L/R taps.
/// After Jot & Chaigne 1991 and Begault 1994; not Dolby's virtual room.
final class Room {
    private static let reflections: [(azimuth: Double, delayMS: Double, gain: Float, side: Int)] = [
        (-55, 8.7, 0.62, -1),
        (60, 10.3, 0.60, 1),
        (0, 12.9, 0.48, 0),      // ceiling
        (-115, 16.4, 0.45, -1),
        (120, 18.1, 0.44, 1),
        (-85, 22.6, 0.36, -1),
        (90, 25.2, 0.35, 1),
        (180, 29.8, 0.30, 0),    // back wall
    ]
    private static let fdnDelays48k = [1031, 1327, 1523, 1801, 2053, 2311, 2579, 2861]
    private static let count = 8

    private var hpL: Biquad, hpR: Biquad
    private let lpCoef: Float
    private var lpL: Float = 0, lpR: Float = 0

    // Reflections, struct-of-arrays.
    private let nearDelay: UnsafeMutablePointer<Int>, farDelay: UnsafeMutablePointer<Int>
    private let nearGain: UnsafeMutablePointer<Float>, farGain: UnsafeMutablePointer<Float>
    private let side: UnsafeMutablePointer<Int>, rightIsNear: UnsafeMutablePointer<Bool>
    private let shadowCoef: UnsafeMutablePointer<Float>, shadowState: UnsafeMutablePointer<Float>

    // Bus history (reflections + FDN predelay).
    private let historyMask: Int
    private let busL: UnsafeMutablePointer<Float>, busR: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private let predelay: Int

    // FDN.
    private let lineLength: UnsafeMutablePointer<Int>
    private let lines: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let heads: UnsafeMutablePointer<Int>
    private let feedback: UnsafeMutablePointer<Float>
    private let dampCoef: Float
    private let dampState: UnsafeMutablePointer<Float>
    private let norm = Float(1 / 8.0.squareRoot())
    private let lateGain: Float = 0.32 * 0.35

    init(sampleRate: Double, rt60: Double = 0.42) {
        let n = Self.count
        hpL = .highPass(160, sampleRate: sampleRate)
        hpR = .highPass(160, sampleRate: sampleRate)
        lpCoef = onePoleCoefficient(7000, sampleRate: sampleRate)

        nearDelay = .allocate(capacity: n); farDelay = .allocate(capacity: n)
        nearGain = .allocate(capacity: n); farGain = .allocate(capacity: n)
        side = .allocate(capacity: n); rightIsNear = .allocate(capacity: n)
        shadowCoef = .allocate(capacity: n); shadowState = makeBuffer(n)
        let headDelay = 0.0875 / 343.0
        var longest = 0
        for (j, r) in Self.reflections.enumerated() {
            let theta = abs(r.azimuth) * .pi / 180
            let itd = headDelay * (min(theta, .pi / 2) + sin(theta)) * sampleRate
            let base = Int(r.delayMS / 1000 * sampleRate)
            let lateral = abs(sin(theta))
            let far = base + Int(itd.rounded())
            longest = max(longest, far)
            nearDelay[j] = base; farDelay[j] = far
            nearGain[j] = r.gain; farGain[j] = r.gain * Float(1 - 0.45 * lateral)
            side[j] = r.side; rightIsNear[j] = r.azimuth > 0
            shadowCoef[j] = onePoleCoefficient(18000 * pow(1800.0 / 18000.0, lateral), sampleRate: sampleRate)
        }
        predelay = Int(0.018 * sampleRate)
        let size = nextPowerOfTwo(atLeast: max(longest, predelay) + 2)
        historyMask = size - 1
        busL = makeBuffer(size); busR = makeBuffer(size)

        let scale = sampleRate / 48000
        lineLength = .allocate(capacity: n)
        lines = .allocate(capacity: n)
        heads = .allocate(capacity: n); heads.initialize(repeating: 0, count: n)
        feedback = .allocate(capacity: n)
        for j in 0..<n {
            let d = max(64, Int(Double(Self.fdnDelays48k[j]) * scale))
            lineLength[j] = d
            lines[j] = makeBuffer(d)
            feedback[j] = Float(pow(10, -3 * Double(d) / (rt60 * sampleRate)))
        }
        dampCoef = onePoleCoefficient(5200, sampleRate: sampleRate)
        dampState = makeBuffer(n)
    }

    deinit {
        for j in 0..<Self.count { lines[j].deallocate() }
        for p in [nearGain, farGain, shadowCoef, shadowState, busL, busR, feedback, dampState] { p.deallocate() }
        nearDelay.deallocate(); farDelay.deallocate(); side.deallocate(); rightIsNear.deallocate()
        lineLength.deallocate(); lines.deallocate(); heads.deallocate()
    }

    func reset() {
        hpL.reset(); hpR.reset()
        lpL = 0; lpR = 0
        vDSP_vclr(shadowState, 1, vDSP_Length(Self.count))
        vDSP_vclr(dampState, 1, vDSP_Length(Self.count))
        vDSP_vclr(busL, 1, vDSP_Length(historyMask + 1))
        vDSP_vclr(busR, 1, vDSP_Length(historyMask + 1))
        for j in 0..<Self.count {
            vDSP_vclr(lines[j], 1, vDSP_Length(lineLength[j]))
            heads[j] = 0
        }
        writeIndex = 0
    }

    /// Adds the room response to `outL`/`outR` for `frames` samples of send input.
    func process(sendL: UnsafePointer<Float>, sendR: UnsafePointer<Float>,
                 addingTo outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, frames: Int) {
        let mask = historyMask
        var hl = hpL, hr = hpR
        var ll = lpL, lr = lpR
        let lc = lpCoef, dc = dampCoef
        let busL = self.busL, busR = self.busR
        let nearDelay = self.nearDelay, farDelay = self.farDelay
        let nearGain = self.nearGain, farGain = self.farGain
        let side = self.side, rightIsNear = self.rightIsNear
        let shadowCoef = self.shadowCoef, shadowState = self.shadowState
        let lines = self.lines, heads = self.heads, lineLength = self.lineLength
        let feedback = self.feedback, damp = self.dampState
        let norm = self.norm, lateGain = self.lateGain, predelay = self.predelay
        var w = writeIndex

        @inline(__always) func write(_ j: Int, _ mixed: Float, _ input: Float) {
            damp[j] += dc * (mixed * norm * feedback[j] - damp[j])
            let h = heads[j]
            lines[j][h] = damp[j] + input
            heads[j] = h + 1 == lineLength[j] ? 0 : h + 1
        }

        for i in 0..<frames {
            // Condition the bus: keep the low end out of the room, soften the top.
            let xl = hl.process(sendL[i]); ll += lc * (xl - ll)
            let xr = hr.process(sendR[i]); lr += lc * (xr - lr)
            busL[w] = ll
            busR[w] = lr

            // 1. Early reflections.
            var l: Float = 0, r: Float = 0
            for j in 0..<8 {
                let near = nearDelay[j], far = farDelay[j]
                let xn: Float, xf: Float
                switch side[j] {
                case -1: xn = busL[(w - near) & mask]; xf = busL[(w - far) & mask]
                case 1: xn = busR[(w - near) & mask]; xf = busR[(w - far) & mask]
                default:
                    xn = 0.5 * (busL[(w - near) & mask] + busR[(w - near) & mask])
                    xf = 0.5 * (busL[(w - far) & mask] + busR[(w - far) & mask])
                }
                shadowState[j] += shadowCoef[j] * (xf - shadowState[j])
                let shadowed = shadowState[j]
                if rightIsNear[j] {
                    r += xn * nearGain[j]
                    l += shadowed * farGain[j]
                } else {
                    l += xn * nearGain[j]
                    r += shadowed * farGain[j]
                }
            }

            // 2. Late tail: 8-line FDN, order-8 Walsh–Hadamard feedback.
            let inL = busL[(w - predelay) & mask]
            let inR = busR[(w - predelay) & mask]
            let s0 = lines[0][heads[0]], s1 = lines[1][heads[1]], s2 = lines[2][heads[2]], s3 = lines[3][heads[3]]
            let s4 = lines[4][heads[4]], s5 = lines[5][heads[5]], s6 = lines[6][heads[6]], s7 = lines[7][heads[7]]
            l += (s0 + s1 + s2 + s3 - s4 - s5 - s6 - s7) * lateGain
            r += (s0 - s1 + s2 - s3 + s4 - s5 + s6 - s7) * lateGain
            let a0 = s0 + s1, a1 = s0 - s1, a2 = s2 + s3, a3 = s2 - s3
            let a4 = s4 + s5, a5 = s4 - s5, a6 = s6 + s7, a7 = s6 - s7
            let b0 = a0 + a2, b1 = a1 + a3, b2 = a0 - a2, b3 = a1 - a3
            let b4 = a4 + a6, b5 = a5 + a7, b6 = a4 - a6, b7 = a5 - a7
            write(0, b0 + b4, inL)
            write(1, b1 + b5, -inR)
            write(2, b2 + b6, inL)
            write(3, b3 + b7, -inR)
            write(4, b0 - b4, inL)
            write(5, b1 - b5, -inR)
            write(6, b2 - b6, inL)
            write(7, b3 - b7, -inR)

            outL[i] += l
            outR[i] += r
            w = (w + 1) & mask
        }
        writeIndex = w
        hpL = hl; hpR = hr
        lpL = ll; lpR = lr
    }
}

/// Streaming look-ahead peak limiter: sliding-window minimum of the required gain
/// (instant attack inside the look-ahead), exponential release, hard ceiling.
final class Limiter {
    let latency: Int
    private let mask: Int
    private let delayL: UnsafeMutablePointer<Float>, delayR: UnsafeMutablePointer<Float>
    private let qIndex: UnsafeMutablePointer<Int>, qValue: UnsafeMutablePointer<Float>
    private var qHead = 0, qTail = 0
    private var t = 0
    private var gain: Float = 1
    private let threshold: Float, ceiling: Float, releaseCoef: Float
    /// Only act on overs (> 0 dBFS): the untouched Original path.
    var transparent = false

    init(sampleRate: Double, thresholdDB: Double = -1.5, ceilingDB: Double = -0.3, lookaheadMS: Double = 2, releaseMS: Double = 160) {
        latency = max(1, Int(lookaheadMS / 1000 * sampleRate))
        let size = nextPowerOfTwo(atLeast: latency + 2)
        mask = size - 1
        delayL = makeBuffer(size); delayR = makeBuffer(size)
        qIndex = .allocate(capacity: size); qIndex.initialize(repeating: 0, count: size)
        qValue = makeBuffer(size, 1)
        threshold = Float(pow(10, thresholdDB / 20))
        ceiling = Float(pow(10, ceilingDB / 20))
        releaseCoef = Float(1 - exp(-1.0 / (releaseMS / 1000 * sampleRate)))
    }

    deinit { delayL.deallocate(); delayR.deallocate(); qIndex.deallocate(); qValue.deallocate() }

    func reset() {
        vDSP_vclr(delayL, 1, vDSP_Length(mask + 1))
        vDSP_vclr(delayR, 1, vDSP_Length(mask + 1))
        qHead = 0; qTail = 0; t = 0; gain = 1
        qIndex.update(repeating: 0, count: mask + 1)
        qValue.update(repeating: 1, count: mask + 1)
    }

    /// Limits in place (output delayed by the look-ahead).
    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let threshold: Float = transparent ? 1 : self.threshold
        let ceiling: Float = transparent ? 1 : self.ceiling
        let mask = self.mask, lookahead = latency
        let qIndex = self.qIndex, qValue = self.qValue, delayL = self.delayL, delayR = self.delayR
        var qHead = self.qHead, qTail = self.qTail, t = self.t, gain = self.gain
        let releaseKeep = 1 - releaseCoef
        for i in 0..<frames {
            let peak = max(abs(l[i]), abs(r[i]))
            let required: Float = peak > threshold ? threshold / peak : 1
            // Monotonic deque: minimum required gain over the last lookahead+1 samples.
            while qTail != qHead, qValue[(qTail - 1) & mask] >= required { qTail = (qTail - 1) & mask }
            qIndex[qTail] = t; qValue[qTail] = required; qTail = (qTail + 1) & mask
            while qIndex[qHead] <= t - (lookahead + 1) { qHead = (qHead + 1) & mask }
            let windowMin = qValue[qHead]
            // Release as a decaying distance to the target: `g += (t − g)·c` stalls
            // 2.3·10⁻⁴ short of unity in single precision and never fully recovers.
            if windowMin < gain { gain = windowMin } else { gain = windowMin - (windowMin - gain) * releaseKeep }

            let w = t & mask
            let dl = delayL[(t - lookahead) & mask], dr = delayR[(t - lookahead) & mask]
            delayL[w] = l[i]; delayR[w] = r[i]
            l[i] = min(max(dl * gain, -ceiling), ceiling)
            r[i] = min(max(dr * gain, -ceiling), ceiling)
            t += 1
        }
        self.qHead = qHead; self.qTail = qTail; self.t = t; self.gain = gain
    }
}
