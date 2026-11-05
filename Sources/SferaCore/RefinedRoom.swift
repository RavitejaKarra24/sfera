import Accelerate
import Foundation

/// The Refined renderer's virtual room: Classic's early reflections, scaled by room size, and
/// a new late tail.
///
/// **Early reflections** are Classic's eight, off the side walls, ceiling and back wall at fixed
/// directions (8.7–29.8 ms in Medium), fed by the two lateral send buses, each with its own ITD
/// and far-ear shadow. Every speaker excites the same pattern, so a vocal spread over L, C and
/// R gets as much room as a vocal on C alone: its reflections add coherently, as its direct
/// sound does. Size scales the delays (Small ×0.92, Large ×1.3). Per-speaker image-source
/// reflections were tried and measured worse on headphones: their floor, front and back
/// reflections reached both ears alike, and a phantom-centre vocal's reflections added only
/// in power, so it came out up to 3 dB drier than in Classic (bench: openness suite).
///
/// **Late tail.** The send bus (plus the LFE) feeds four short all-passes per side (a dense
/// onset instead of a few discrete echoes), then an 8-line Hadamard FDN whose lines decay by
/// frequency: 100 Hz 1.3× the set decay, 8 kHz 0.4× (a gain and two first-order shelves per
/// line, solved together; Jot & Chaigne 1991). Each ear's output then runs through its own
/// four all-passes, so the ears hear different tails even for a one-sided source. The tail
/// decays from its start, like Classic's, instead of swelling. Its high-pass moves from 160 Hz
/// down to 40 Hz with "bass in room"; the reflections keep Classic's 160 Hz.
///
/// Default levels match Classic's room at the same mode, per size: the same energy in the
/// first 80 ms and after it (bench: VALIDATION §3).
final class RefinedRoom {
    /// Classic's reflections (Room.swift): azimuth, delay in Medium, gain, the bus that feeds it
    /// (−1 left, 1 right, 0 both).
    private static let reflections: [(azimuth: Double, delayMS: Double, gain: Float, side: Int)] = [
        (-55, 8.7, 0.62, -1), (60, 10.3, 0.60, 1), (0, 12.9, 0.48, 0), (-115, 16.4, 0.45, -1),
        (120, 18.1, 0.44, 1), (-85, 22.6, 0.36, -1), (90, 25.2, 0.35, 1), (180, 29.8, 0.30, 0),
    ]
    private static let count = 8
    /// Per size (Small, Medium, Large): reflection delays, and the tail's lines, diffusers and
    /// predelay.
    private static let earlyScale: [Double] = [0.92, 1, 1.3]
    private static let tailScale: [Double] = [0.75, 1, 1.45]
    /// Calibration per size: with default settings, the same energy as Classic's room in the
    /// first 80 ms and after it. Size changes the timing, not the amount.
    private static let earlyNorm: [Float] = [1.004, 1.040, 1.049]
    private static let lateNorm: [Float] = [0.0985, 0.0617, 0.0457]

    private static let fdnDelays48k = [1031, 1327, 1523, 1801, 2053, 2311, 2579, 2861]
    /// All-pass chains: input L, input R (onset density), output L, output R (each ear's tail
    /// its own, so a source on one side doesn't reach both ears as the same tail).
    private static let diffuserMS: [[Double]] = [[1.9, 3.1, 4.3, 6.1], [2.1, 3.3, 4.7, 6.7],
                                                 [1.3, 2.3, 3.7, 5.3], [1.7, 2.9, 4.1, 5.9]]
    private static let chains = 4
    private static let diffuserGain: Float = 0.5

    private let sampleRate: Double
    private var sizeIndex = 1

    // MARK: Early reflections (struct-of-arrays, size * 8 + reflection)

    private let nearDelay: UnsafeMutablePointer<Int>, farDelay: UnsafeMutablePointer<Int>
    private let nearGain: UnsafeMutablePointer<Float>, farGain: UnsafeMutablePointer<Float>
    private let side: UnsafeMutablePointer<Int>, rightIsNear: UnsafeMutablePointer<Bool>
    private let shadowCoef: UnsafeMutablePointer<Float>, shadowState: UnsafeMutablePointer<Float>
    private let busMask: Int
    private let busL: UnsafeMutablePointer<Float>, busR: UnsafeMutablePointer<Float>
    private var busWrite = 0
    // Audio-thread state lives in raw memory: no copy-on-write in the render loop.
    private let earlyHP: UnsafeMutablePointer<Biquad>
    private let earlyLPCoef: Float
    private var earlyLPL: Float = 0, earlyLPR: Float = 0

    // MARK: Late tail

    private let inputHP: UnsafeMutablePointer<Biquad>
    private var bassAmount = -1.0
    private let inputLPCoef: Float
    private var inputLPL: Float = 0, inputLPR: Float = 0
    private let diffusers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>     // chain * 4 + stage
    private let diffuserMax: [Int]
    private let diffuserLength: UnsafeMutablePointer<Int>
    private let diffuserIndex: UnsafeMutablePointer<Int>
    private let predelayLine: [UnsafeMutablePointer<Float>]
    private let predelayMask: Int
    private var predelay = 1
    private var predelayIndex = 0
    private let lines: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let lineCapacity: [Int]
    private let lineLength: UnsafeMutablePointer<Int>
    private let heads: UnsafeMutablePointer<Int>
    private let midGain: UnsafeMutablePointer<Float>
    private let lowShelf: UnsafeMutablePointer<Shelf>
    private let highShelf: UnsafeMutablePointer<Shelf>
    /// A decay change glides the loop filters from these to the new design over ~100 ms
    /// (interpolating first-order coefficients keeps every step stable).
    private let fromGain: UnsafeMutablePointer<Float>, toGain: UnsafeMutablePointer<Float>
    private let fromLow: UnsafeMutablePointer<Shelf>, toLow: UnsafeMutablePointer<Shelf>
    private let fromHigh: UnsafeMutablePointer<Shelf>, toHigh: UnsafeMutablePointer<Shelf>
    private var glide: Double = 1
    private let glideStepPerFrame: Double
    private var decay = -1.0

    // MARK: Levels (glide per block)

    /// Bench only: silence the early reflections or the tail (from the start).
    var muteEarly = false { didSet { earlyGain = muteEarly ? 0 : earlyGain } }
    var muteLate = false { didSet { lateGain = muteLate ? 0 : lateGain } }
    private var earlyGain: Float = 1, lateGain: Float = 1
    private var earlyTarget: Float = 1, lateTarget: Float = 1

    init(sampleRate: Double) {
        self.sampleRate = sampleRate

        // Early reflections for every size, so a size change only switches tables.
        let n = Self.count, all = n * Self.earlyScale.count
        nearDelay = .allocate(capacity: all); farDelay = .allocate(capacity: all)
        nearGain = .allocate(capacity: all); farGain = .allocate(capacity: all)
        side = .allocate(capacity: all); rightIsNear = .allocate(capacity: all)
        shadowCoef = .allocate(capacity: all); shadowState = makeBuffer(n)
        let headDelay = Cue.headRadius / Cue.speedOfSound
        var longest = 0
        for (k, scale) in Self.earlyScale.enumerated() {
            for (i, r) in Self.reflections.enumerated() {
                // Classic's model: ITD from min(θ, 90°) + sin θ, far ear shadowed by laterality.
                let j = k * n + i
                let theta = abs(r.azimuth) * .pi / 180
                let lateral = abs(sin(theta))
                let itd = headDelay * (min(theta, .pi / 2) + sin(theta)) * sampleRate
                let base = Int(r.delayMS * scale / 1000 * sampleRate)
                nearDelay[j] = base; farDelay[j] = base + Int(itd.rounded())
                longest = max(longest, farDelay[j])
                nearGain[j] = r.gain; farGain[j] = r.gain * Float(1 - 0.45 * lateral)
                side[j] = r.side; rightIsNear[j] = r.azimuth > 0
                shadowCoef[j] = onePoleCoefficient(18000 * pow(1800.0 / 18000.0, lateral), sampleRate: sampleRate)
            }
        }
        let busSize = nextPowerOfTwo(atLeast: longest + 2)
        busMask = busSize - 1
        busL = makeBuffer(busSize); busR = makeBuffer(busSize)
        earlyHP = .allocate(capacity: 2); earlyHP.initialize(repeating: .highPass(160, sampleRate: sampleRate), count: 2)
        earlyLPCoef = onePoleCoefficient(7000, sampleRate: sampleRate)

        // Late tail, allocated for the largest room.
        let largest = Self.tailScale.max()!
        inputHP = .allocate(capacity: 2); inputHP.initialize(repeating: .highPass(80, sampleRate: sampleRate), count: 2)
        inputLPCoef = onePoleCoefficient(8000, sampleRate: sampleRate)
        var dmax: [Int] = []
        var dbufs: [UnsafeMutablePointer<Float>] = []
        for chain in 0..<Self.chains {
            for ms in Self.diffuserMS[chain] {
                let m = Int(ms / 1000 * largest * sampleRate) + 2
                dmax.append(m); dbufs.append(makeBuffer(m))
            }
        }
        diffuserMax = dmax
        let stages = 4 * Self.chains
        diffusers = .allocate(capacity: stages); diffusers.initialize(from: dbufs, count: stages)
        diffuserLength = .allocate(capacity: stages); diffuserLength.initialize(repeating: 1, count: stages)
        diffuserIndex = .allocate(capacity: stages); diffuserIndex.initialize(repeating: 0, count: stages)
        midGain = makeBuffer(8)
        lowShelf = .allocate(capacity: 8); lowShelf.initialize(repeating: Shelf(), count: 8)
        highShelf = .allocate(capacity: 8); highShelf.initialize(repeating: Shelf(), count: 8)
        fromGain = makeBuffer(8); toGain = makeBuffer(8)
        fromLow = .allocate(capacity: 8); fromLow.initialize(repeating: Shelf(), count: 8)
        toLow = .allocate(capacity: 8); toLow.initialize(repeating: Shelf(), count: 8)
        fromHigh = .allocate(capacity: 8); fromHigh.initialize(repeating: Shelf(), count: 8)
        toHigh = .allocate(capacity: 8); toHigh.initialize(repeating: Shelf(), count: 8)
        glideStepPerFrame = 1 / (0.1 * sampleRate)
        let pre = nextPowerOfTwo(atLeast: Int(0.004 * largest * sampleRate) + 2)
        predelayMask = pre - 1
        predelayLine = [makeBuffer(pre), makeBuffer(pre)]
        let rateScale = sampleRate / 48000
        lines = .allocate(capacity: 8)
        lineLength = .allocate(capacity: 8)
        heads = .allocate(capacity: 8); heads.initialize(repeating: 0, count: 8)
        var capacity: [Int] = []
        for j in 0..<8 {
            let m = Int(Double(Self.fdnDelays48k[j]) * largest * rateScale) + 1
            lines[j] = makeBuffer(m)
            lineLength[j] = m
            capacity.append(m)
        }
        lineCapacity = capacity
        configure(size: .medium)
        tune(RoomSettings())
        earlyGain = earlyTarget; lateGain = lateTarget
    }

    deinit {
        for p in [busL, busR, shadowState, nearGain, farGain, shadowCoef, midGain, fromGain, toGain] + predelayLine { p.deallocate() }
        nearDelay.deallocate(); farDelay.deallocate(); side.deallocate(); rightIsNear.deallocate()
        for j in 0..<8 { lines[j].deallocate() }
        for k in 0..<(4 * Self.chains) { diffusers[k].deallocate() }
        lines.deallocate(); lineLength.deallocate(); heads.deallocate()
        earlyHP.deallocate(); inputHP.deallocate()
        diffusers.deallocate(); diffuserLength.deallocate(); diffuserIndex.deallocate()
        lowShelf.deallocate(); highShelf.deallocate()
        fromLow.deallocate(); toLow.deallocate(); fromHigh.deallocate(); toHigh.deallocate()
    }

    /// Switches room size (call while the room is silent: it starts empty).
    func configure(size: RoomSize) {
        sizeIndex = RoomSize.allCases.firstIndex(of: size)!
        let scale = Self.tailScale[sizeIndex]
        let rateScale = sampleRate / 48000
        for j in 0..<8 { lineLength[j] = min(lineCapacity[j], max(64, Int(Double(Self.fdnDelays48k[j]) * scale * rateScale))) }
        for chain in 0..<Self.chains {
            for (k, ms) in Self.diffuserMS[chain].enumerated() {
                diffuserLength[chain * 4 + k] = min(diffuserMax[chain * 4 + k], max(1, Int(ms / 1000 * scale * sampleRate)))
            }
        }
        predelay = max(1, min(predelayMask, Int(0.004 * scale * sampleRate)))
        decay = -1                      // line lengths changed: recompute the decay filters
        reset()
    }

    /// Decay, levels and bass. Cheap when nothing changed.
    func tune(_ r: RoomSettings) {
        let levels = RoomSettings.levelRange
        earlyTarget = muteEarly ? 0 : Self.earlyNorm[sizeIndex] * dbToGain(min(max(r.early, levels.lowerBound), levels.upperBound))
        lateTarget = muteLate ? 0 : Self.lateNorm[sizeIndex] * dbToGain(min(max(r.late, levels.lowerBound), levels.upperBound))
        let t = min(max(r.decay, RoomSettings.decayRange.lowerBound), RoomSettings.decayRange.upperBound)
        if t != decay {
            let first = decay < 0
            decay = t
            for j in 0..<8 {
                fromGain[j] = midGain[j]; fromLow[j].take(lowShelf[j]); fromHigh[j].take(highShelf[j])
                designLine(j, decay: t)
            }
            glide = 0
            if first { applyGlide(1) }      // a new room starts at its design
        }
        let bass = min(max(r.bass, 0), 1)
        if bass != bassAmount {
            bassAmount = bass
            let hp = Biquad.highPass(160 * pow(40.0 / 160.0, bass), sampleRate: sampleRate)
            for k in 0..<2 { inputHP[k].b0 = hp.b0; inputHP[k].b1 = hp.b1; inputHP[k].b2 = hp.b2; inputHP[k].a1 = hp.a1; inputHP[k].a2 = hp.a2 }
        }
    }

    /// Decay targets: bass (100 Hz) 1.3×, treble (8 kHz) 0.4× the mid (1 kHz) decay.
    private static let decayShape: [(frequency: Double, factor: Double)] = [(100, 1.3), (1000, 1), (8000, 0.4)]

    /// Per-line loss: mid gain × low shelf (220 Hz) × high shelf (3 kHz). The first-order
    /// shelves overlap, so the three gains are solved together (a few correction passes,
    /// each gain mostly owns its own band) until the line's loss in dB at 100 Hz, 1 kHz and
    /// 8 kHz is −60·d/(fs·T) for the target decay T there.
    private func designLine(_ j: Int, decay t: Double) {
        let d = Double(lineLength[j])
        let target = Self.decayShape.map { -60 * d / (sampleRate * t * $0.factor) }
        var lowDB = target[0] - target[1], midDB = target[1], highDB = target[2] - target[1]
        func design() -> (Shelf, Shelf) {
            (Shelf(low: true, frequency: 220, gain: pow(10, lowDB / 20), sampleRate: sampleRate),
             Shelf(low: false, frequency: 3000, gain: pow(10, highDB / 20), sampleRate: sampleRate))
        }
        for _ in 0..<12 {
            let (lo, hi) = design()
            let got = Self.decayShape.map {
                midDB + 20 * log10(lo.magnitude(at: $0.frequency, sampleRate: sampleRate) * hi.magnitude(at: $0.frequency, sampleRate: sampleRate))
            }
            lowDB += target[0] - got[0]
            midDB += target[1] - got[1]
            highDB += target[2] - got[2]
        }
        let (lo, hi) = design()
        toGain[j] = Float(pow(10, midDB / 20))
        toLow[j].take(lo)
        toHigh[j].take(hi)
    }

    /// Loop filters at `fraction` of the way from the old design to the new one.
    private func applyGlide(_ fraction: Double) {
        glide = min(fraction, 1)
        let f = Float(glide), k = 1 - f
        func mix(_ a: Shelf, _ b: Shelf) -> Shelf {
            var s = Shelf(); s.b0 = a.b0 * k + b.b0 * f; s.b1 = a.b1 * k + b.b1 * f; s.a1 = a.a1 * k + b.a1 * f; return s
        }
        for j in 0..<8 {
            midGain[j] = fromGain[j] * k + toGain[j] * f
            lowShelf[j].take(mix(fromLow[j], toLow[j]))
            highShelf[j].take(mix(fromHigh[j], toHigh[j]))
        }
    }

    func reset() {
        vDSP_vclr(busL, 1, vDSP_Length(busMask + 1)); vDSP_vclr(busR, 1, vDSP_Length(busMask + 1))
        busWrite = 0
        vDSP_vclr(shadowState, 1, vDSP_Length(Self.count))
        for k in 0..<2 { earlyHP[k].reset(); inputHP[k].reset() }
        earlyLPL = 0; earlyLPR = 0; inputLPL = 0; inputLPR = 0
        for k in 0..<(4 * Self.chains) { vDSP_vclr(diffusers[k], 1, vDSP_Length(diffuserMax[k])); diffuserIndex[k] = 0 }
        for p in predelayLine { vDSP_vclr(p, 1, vDSP_Length(predelayMask + 1)) }
        predelayIndex = 0
        for j in 0..<8 {
            vDSP_vclr(lines[j], 1, vDSP_Length(lineCapacity[j]))
            heads[j] = 0
            lowShelf[j].reset(); highShelf[j].reset()
        }
    }

    /// Early reflections of a size (bench): near- and far-ear delay in samples.
    func reflectionDelays(size: RoomSize) -> [(near: Int, far: Int)] {
        let t = RoomSize.allCases.firstIndex(of: size)! * Self.count
        return (0..<Self.count).map { (nearDelay[t + $0], farDelay[t + $0]) }
    }

    /// Adds the room to `outL/outR`. `sendL/sendR` is the lateral send bus; `lfe` (optional)
    /// feeds the tail only.
    func process(sendL: UnsafePointer<Float>, sendR: UnsafePointer<Float>, lfe: UnsafePointer<Float>?,
                 addingTo outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, frames: Int) {
        if glide < 1 { applyGlide(glide + Double(frames) * glideStepPerFrame) }
        let t = sizeIndex * Self.count
        let nearDelay = self.nearDelay + t, farDelay = self.farDelay + t
        let nearGain = self.nearGain + t, farGain = self.farGain + t
        let side = self.side + t, rightIsNear = self.rightIsNear + t
        let shadowCoef = self.shadowCoef + t, shadowState = self.shadowState
        let busL = self.busL, busR = self.busR, busMask = self.busMask
        var w = busWrite
        var ehl = earlyHP[0], ehr = earlyHP[1]
        var el = earlyLPL, er = earlyLPR
        let ec = earlyLPCoef

        var hl = inputHP[0], hr = inputHP[1]
        var ll = inputLPL, lr = inputLPR
        let ic = inputLPCoef
        let dg = Self.diffuserGain
        let lines = self.lines, heads = self.heads, lineLength = self.lineLength
        let norm = Float(1 / 8.0.squareRoot())
        let dIndex = diffuserIndex, dLength = diffuserLength, dBuf = diffusers
        let low = lowShelf, high = highShelf, mg = midGain
        let pL = predelayLine[0], pR = predelayLine[1], pMask = predelayMask, pre = predelay
        var pi = predelayIndex
        let eStep = (earlyTarget - earlyGain) / Float(frames), lStep = (lateTarget - lateGain) / Float(frames)
        var eg = earlyGain, lg = lateGain

        @inline(__always) func diffuse(_ x: Float, _ first: Int) -> Float {
            var v = x
            for k in first..<(first + 4) {
                let b = dBuf[k], idx = dIndex[k]
                let delayed = b[idx]
                let u = v + dg * delayed
                v = delayed - dg * u
                b[idx] = u
                dIndex[k] = idx + 1 == dLength[k] ? 0 : idx + 1
            }
            return v
        }

        for i in 0..<frames {
            // 1. Early reflections, Classic's network: condition the bus, then eight taps.
            let xl = ehl.process(sendL[i]); el += ec * (xl - el)
            let xr = ehr.process(sendR[i]); er += ec * (xr - er)
            busL[w] = el
            busR[w] = er
            var l: Float = 0, r: Float = 0
            for j in 0..<8 {
                let near = nearDelay[j], far = farDelay[j]
                let xn: Float, xf: Float
                switch side[j] {
                case -1: xn = busL[(w - near) & busMask]; xf = busL[(w - far) & busMask]
                case 1: xn = busR[(w - near) & busMask]; xf = busR[(w - far) & busMask]
                default:
                    xn = 0.5 * (busL[(w - near) & busMask] + busR[(w - near) & busMask])
                    xf = 0.5 * (busL[(w - far) & busMask] + busR[(w - far) & busMask])
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
            w = (w + 1) & busMask

            // 2. Late tail.
            let bass = lfe?[i] ?? 0
            let tl = hl.process(sendL[i] + bass); ll += ic * (tl - ll)
            let tr = hr.process(sendR[i] + bass); lr += ic * (tr - lr)
            let dl = diffuse(ll, 0), dr = diffuse(lr, 4)
            pL[pi] = dl; pR[pi] = dr
            let inL = pL[(pi - pre) & pMask], inR = pR[(pi - pre) & pMask]
            pi = (pi + 1) & pMask

            let s0 = lines[0][heads[0]], s1 = lines[1][heads[1]], s2 = lines[2][heads[2]], s3 = lines[3][heads[3]]
            let s4 = lines[4][heads[4]], s5 = lines[5][heads[5]], s6 = lines[6][heads[6]], s7 = lines[7][heads[7]]
            eg += eStep; lg += lStep
            outL[i] += l * eg + diffuse(s0 + s1 + s2 + s3 - s4 - s5 - s6 - s7, 8) * lg
            outR[i] += r * eg + diffuse(s0 - s1 + s2 - s3 + s4 - s5 + s6 - s7, 12) * lg
            let a0 = s0 + s1, a1 = s0 - s1, a2 = s2 + s3, a3 = s2 - s3
            let a4 = s4 + s5, a5 = s4 - s5, a6 = s6 + s7, a7 = s6 - s7
            let b0 = a0 + a2, b1 = a1 + a3, b2 = a0 - a2, b3 = a1 - a3
            let b4 = a4 + a6, b5 = a5 + a7, b6 = a4 - a6, b7 = a5 - a7
            let mixed: (Float, Float, Float, Float, Float, Float, Float, Float) =
                (b0 + b4, b1 + b5, b2 + b6, b3 + b7, b0 - b4, b1 - b5, b2 - b6, b3 - b7)
            @inline(__always) func write(_ j: Int, _ m: Float, _ input: Float) {
                let y = high[j].process(low[j].process(m * norm * mg[j]))
                let h = heads[j]
                lines[j][h] = y + input
                heads[j] = h + 1 == lineLength[j] ? 0 : h + 1
            }
            write(0, mixed.0, inL); write(1, mixed.1, -inR)
            write(2, mixed.2, inL); write(3, mixed.3, -inR)
            write(4, mixed.4, inL); write(5, mixed.5, -inR)
            write(6, mixed.6, inL); write(7, mixed.7, -inR)
        }
        earlyGain = earlyTarget; lateGain = lateTarget
        busWrite = w
        earlyHP[0] = ehl; earlyHP[1] = ehr
        earlyLPL = el; earlyLPR = er
        inputHP[0] = hl; inputHP[1] = hr
        inputLPL = ll; inputLPR = lr
        predelayIndex = pi
    }
}
