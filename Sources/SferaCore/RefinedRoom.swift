import Accelerate
import Foundation

/// The Refined renderer's virtual room.
///
/// **Early reflections belong to the source.** Every speaker direction gets its own six
/// first-order image sources in a shoebox room (side walls, front, back, ceiling, floor), so a
/// centre voice, a hard-left guitar and a rear effect each excite the walls they would excite
/// in a real room. Each reflection arrives from its own direction with the head model's ITD,
/// ILD and shadow; ceiling and floor reflections carry the elevation cue. Gains follow path
/// length (1/r) and wall reflectance. To stay cheap, reflections are summed into a few buses
/// per ear (by shadow cutoff, plus "above" and "below") and each bus is filtered once.
/// Reflections stay above 200 Hz, so bass attacks aren't smeared.
///
/// **Late tail.** The lateral send bus feeds four series all-passes per side (a dense onset
/// instead of a few discrete echoes), then an 8-line Hadamard FDN whose lines decay by
/// frequency: 100 Hz 1.3× the set decay, 8 kHz 0.4× (a gain and two first-order shelves per
/// line, solved together; Jot & Chaigne 1991). The tail's high-pass moves from 160 Hz down
/// to 40 Hz with "bass in room", and the LFE feeds it too.
///
/// Size scales the room, the virtual speakers' distance, the tail lines and the diffusers.
/// Default levels are calibrated to Classic's room at the same mode: the same energy in the
/// first 50 ms and after it (bench: VALIDATION §3).
final class RefinedRoom {
    // Room geometry in metres around the listener's head: x right, y front, z up.
    private struct Geometry {
        let halfWidth, front, back, ceiling, floor, speakerRadius, scale: Double
    }
    private static func geometry(_ size: RoomSize) -> Geometry {
        switch size {
        case .small: Geometry(halfWidth: 1.9, front: 2.3, back: 2.4, ceiling: 1.5, floor: 1.1, speakerRadius: 1.6, scale: 0.75)
        case .medium: Geometry(halfWidth: 2.6, front: 2.9, back: 3.6, ceiling: 1.8, floor: 1.2, speakerRadius: 2.0, scale: 1.0)
        case .large: Geometry(halfWidth: 3.8, front: 3.9, back: 5.2, ceiling: 2.6, floor: 1.2, speakerRadius: 2.6, scale: 1.45)
        }
    }
    /// Reflectance of the side walls, front, back, ceiling, floor (rug).
    private static let reflectance: [Double] = [0.8, 0.8, 0.72, 0.8, 0.75, 0.55]
    /// Calibration: Classic's room energy in 0–50 ms and after 50 ms, with default settings.
    static let earlyNorm: Float = 1.112
    static let lateNorm: Float = 0.32 * 0.35

    private static let fdnDelays48k = [1031, 1327, 1523, 1801, 2053, 2311, 2579, 2861]
    private static let diffuserMS: [[Double]] = [[4.3, 6.1, 8.9, 12.7], [4.7, 6.7, 9.7, 13.9]]
    private static let diffuserGain: Float = 0.6
    private static let shadowCutoffs: [Double] = [9000, 4500, 2200, 1100]   // classes 1…4
    private static let classes = 7            // 0 none, 1…4 shadow, 5 above, 6 below
    private static let above = 5, below = 6

    private let sampleRate: Double
    private let maxFrames: Int
    private let groupCount: Int

    // MARK: Early reflections

    /// One ear of one reflection.
    private struct Tap { var group: Int; var delay: Int; var gain: Float; var bus: Int }
    private let taps: [[Tap]]                  // per size
    private var sizeIndex = 1
    private let historyMask: Int
    private let history: [UnsafeMutablePointer<Float>]
    private let groupSilent: UnsafeMutablePointer<Int>
    private var writeIndex = 0
    private let buses: [UnsafeMutablePointer<Float>]    // ear * classes + class
    private let shadowCoef: [Float]
    // Audio-thread state lives in raw memory: no copy-on-write in the render loop.
    private let shadowState: UnsafeMutablePointer<Float>                 // ear * 4 + class
    private let upFilters: UnsafeMutablePointer<Biquad>                  // ear * 2 + [boost, notch]
    private let downFilters: UnsafeMutablePointer<Biquad>
    private let earlyHP: UnsafeMutablePointer<Biquad>
    private let earlyLPCoef: Float
    private var earlyLPL: Float = 0, earlyLPR: Float = 0
    private let earlyL: UnsafeMutablePointer<Float>, earlyR: UnsafeMutablePointer<Float>

    // MARK: Late tail

    private let inputHP: UnsafeMutablePointer<Biquad>
    private var bassAmount = -1.0
    private let inputLPCoef: Float
    private var inputLPL: Float = 0, inputLPR: Float = 0
    private let diffusers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>     // side * 4 + stage
    private let diffuserMax: [Int]
    private let diffuserLength: UnsafeMutablePointer<Int>
    private let diffuserIndex: UnsafeMutablePointer<Int>
    private let predelayLine: [UnsafeMutablePointer<Float>]
    private let predelayMask: Int
    private var predelay = 1
    private var predelayIndex = 0
    private let lines: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
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

    init(sampleRate: Double, maxFrames: Int, groups: [(azimuth: Double, elevation: Double)]) {
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        groupCount = groups.count

        // Image sources for every size, so a size change only switches tables.
        let c = Cue.speedOfSound
        var longest = 0
        taps = RoomSize.allCases.map { size in
            let g = Self.geometry(size)
            var list: [Tap] = []
            for (gi, dir) in groups.enumerated() {
                let az = dir.azimuth * .pi / 180, el = dir.elevation * .pi / 180
                let r = g.speakerRadius
                let m = 0.3
                let x = min(max(r * cos(el) * sin(az), -g.halfWidth + m), g.halfWidth - m)
                let y = min(max(r * cos(el) * cos(az), -g.back + m), g.front - m)
                let z = min(max(r * sin(el), -g.floor + m), g.ceiling - m)
                let d = (x * x + y * y + z * z).squareRoot()
                let images: [(Double, Double, Double)] = [
                    (-2 * g.halfWidth - x, y, z), (2 * g.halfWidth - x, y, z),
                    (x, 2 * g.front - y, z), (x, -2 * g.back - y, z),
                    (x, y, 2 * g.ceiling - z), (x, y, -2 * g.floor - z),
                ]
                for (wall, p) in images.enumerated() {
                    let dist = (p.0 * p.0 + p.1 * p.1 + p.2 * p.2).squareRoot()
                    let arrivalAz = atan2(p.0, p.1) * 180 / .pi
                    let arrivalEl = atan2(p.2, (p.0 * p.0 + p.1 * p.1).squareRoot()) * 180 / .pi
                    let cue = Cue(azimuth: arrivalAz, elevation: arrivalEl, sampleRate: sampleRate, renderer: .refined)
                    let base = (dist - d) / c * sampleRate
                    let gain = Float(Self.reflectance[wall] * d / dist)
                    for ear in 0..<2 {
                        let itd = Double(ear == 0 ? cue.delayL : cue.delayR)
                        let cutoff = ear == 0 ? cue.shadowCutoffL : cue.shadowCutoffR
                        let ild = ear == 0 ? cue.ildL : cue.ildR
                        let cls: Int
                        if arrivalEl > 20 { cls = Self.above }
                        else if arrivalEl < -20 { cls = Self.below }
                        else if cutoff >= 14000 { cls = 0 }
                        else {
                            let k = Self.shadowCutoffs.enumerated().min { abs(log($0.1 / cutoff)) < abs(log($1.1 / cutoff)) }!.offset
                            cls = k + 1
                        }
                        let delay = max(1, Int((base + itd).rounded()))
                        longest = max(longest, delay)
                        list.append(Tap(group: gi, delay: delay, gain: gain * ild, bus: ear * Self.classes + cls))
                    }
                }
            }
            return list
        }
        let historySize = nextPowerOfTwo(atLeast: longest + maxFrames + 1)
        historyMask = historySize - 1
        history = (0..<groups.count).map { _ in makeBuffer(historySize) }
        groupSilent = .allocate(capacity: max(groups.count, 1))
        groupSilent.initialize(repeating: Int.max, count: max(groups.count, 1))
        buses = (0..<(2 * Self.classes)).map { _ in makeBuffer(maxFrames) }
        shadowCoef = Self.shadowCutoffs.map { onePoleCoefficient($0, sampleRate: sampleRate) }
        shadowState = makeBuffer(8)
        let (upBoost, upNotch) = Cue.elevationFilters(elevation: 45, sampleRate: sampleRate)
        let (downBoost, downNotch) = Cue.elevationFilters(elevation: -35, sampleRate: sampleRate)
        upFilters = .allocate(capacity: 4); upFilters.initialize(from: [upBoost, upNotch, upBoost, upNotch], count: 4)
        downFilters = .allocate(capacity: 4); downFilters.initialize(from: [downBoost, downNotch, downBoost, downNotch], count: 4)
        earlyHP = .allocate(capacity: 2); earlyHP.initialize(repeating: .highPass(200, sampleRate: sampleRate), count: 2)
        earlyLPCoef = onePoleCoefficient(9000, sampleRate: sampleRate)
        earlyL = makeBuffer(maxFrames); earlyR = makeBuffer(maxFrames)

        // Late tail, allocated for the largest room.
        let largest = Self.geometry(.large).scale
        inputHP = .allocate(capacity: 2); inputHP.initialize(repeating: .highPass(80, sampleRate: sampleRate), count: 2)
        inputLPCoef = onePoleCoefficient(8000, sampleRate: sampleRate)
        var dmax: [Int] = []
        var dbufs: [UnsafeMutablePointer<Float>] = []
        for side in 0..<2 {
            for ms in Self.diffuserMS[side] {
                let n = Int(ms / 1000 * largest * sampleRate) + 2
                dmax.append(n); dbufs.append(makeBuffer(n))
            }
        }
        diffuserMax = dmax
        diffusers = .allocate(capacity: 8); diffusers.initialize(from: dbufs, count: 8)
        diffuserLength = .allocate(capacity: 8); diffuserLength.initialize(repeating: 1, count: 8)
        diffuserIndex = .allocate(capacity: 8); diffuserIndex.initialize(repeating: 0, count: 8)
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
        for j in 0..<8 {
            let n = Int(Double(Self.fdnDelays48k[j]) * largest * rateScale) + 1
            lines[j] = makeBuffer(n)
            lineLength[j] = n
        }
        configure(size: .medium)
        tune(RoomSettings())
        earlyGain = earlyTarget; lateGain = lateTarget
    }

    deinit {
        for p in history + buses + predelayLine { p.deallocate() }
        for j in 0..<8 { lines[j].deallocate(); diffusers[j].deallocate() }
        lines.deallocate(); lineLength.deallocate(); heads.deallocate(); groupSilent.deallocate()
        earlyL.deallocate(); earlyR.deallocate(); shadowState.deallocate()
        upFilters.deallocate(); downFilters.deallocate(); earlyHP.deallocate(); inputHP.deallocate()
        diffusers.deallocate(); diffuserLength.deallocate(); diffuserIndex.deallocate()
        midGain.deallocate(); lowShelf.deallocate(); highShelf.deallocate()
        fromGain.deallocate(); toGain.deallocate(); fromLow.deallocate(); toLow.deallocate()
        fromHigh.deallocate(); toHigh.deallocate()
    }

    /// Switches room size (call while the room is silent: it starts empty).
    func configure(size: RoomSize) {
        sizeIndex = RoomSize.allCases.firstIndex(of: size)!
        let g = Self.geometry(size)
        let rateScale = sampleRate / 48000
        for j in 0..<8 { lineLength[j] = max(64, Int(Double(Self.fdnDelays48k[j]) * g.scale * rateScale)) }
        for side in 0..<2 {
            for (k, ms) in Self.diffuserMS[side].enumerated() {
                diffuserLength[side * 4 + k] = min(diffuserMax[side * 4 + k], max(1, Int(ms / 1000 * g.scale * sampleRate)))
            }
        }
        predelay = max(1, min(predelayMask, Int(0.004 * g.scale * sampleRate)))
        decay = -1                      // line lengths changed: recompute the decay filters
        reset()
    }

    /// Decay, levels and bass. Cheap when nothing changed.
    func tune(_ r: RoomSettings) {
        earlyTarget = muteEarly ? 0 : Self.earlyNorm * dbToGain(min(max(r.early, RoomSettings.levelRange.lowerBound), RoomSettings.levelRange.upperBound))
        lateTarget = muteLate ? 0 : Self.lateNorm * dbToGain(min(max(r.late, RoomSettings.levelRange.lowerBound), RoomSettings.levelRange.upperBound))
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
        for p in history { vDSP_vclr(p, 1, vDSP_Length(historyMask + 1)) }
        for g in 0..<groupCount { groupSilent[g] = Int.max }
        writeIndex = 0
        vDSP_vclr(shadowState, 1, 8)
        for k in 0..<4 { upFilters[k].reset(); downFilters[k].reset() }
        for k in 0..<2 { earlyHP[k].reset(); inputHP[k].reset() }
        earlyLPL = 0; earlyLPR = 0; inputLPL = 0; inputLPR = 0
        for k in 0..<8 { vDSP_vclr(diffusers[k], 1, vDSP_Length(diffuserMax[k])); diffuserIndex[k] = 0 }
        for p in predelayLine { vDSP_vclr(p, 1, vDSP_Length(predelayMask + 1)) }
        predelayIndex = 0
        for j in 0..<8 {
            vDSP_vclr(lines[j], 1, vDSP_Length(Int(Double(Self.fdnDelays48k[j]) * Self.geometry(.large).scale * sampleRate / 48000) + 1))
            heads[j] = 0
            lowShelf[j].reset(); highShelf[j].reset()
        }
    }

    /// Early reflections of one speaker direction (bench): delay in samples and gain per ear.
    func taps(group: Int, size: RoomSize) -> [(ear: Int, delay: Int, gain: Float, above: Bool, below: Bool)] {
        taps[RoomSize.allCases.firstIndex(of: size)!].filter { $0.group == group }.map {
            let cls = $0.bus % Self.classes
            return ($0.bus / Self.classes, $0.delay, $0.gain, cls == Self.above, cls == Self.below)
        }
    }

    /// Adds the room to `outL/outR`. `groupSends[i]` is speaker direction i's send (valid when
    /// `groupActive[i]`); `sendL/sendR` is the lateral bus that feeds the tail.
    func process(groupSends: UnsafePointer<UnsafeMutablePointer<Float>>, groupActive: UnsafePointer<Bool>,
                 sendL: UnsafePointer<Float>, sendR: UnsafePointer<Float>,
                 addingTo outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, frames: Int) {
        let frames = min(frames, maxFrames)
        let n = vDSP_Length(frames)
        let mask = historyMask, size = mask + 1
        if glide < 1 { applyGlide(glide + Double(frames) * glideStepPerFrame) }
        let w = writeIndex

        // 1. Each direction's send into its history (silence once, then nothing).
        for g in 0..<groupCount {
            let h = history[g]
            let first = min(frames, size - w)
            if groupActive[g] {
                h.advanced(by: w).update(from: groupSends[g], count: first)
                if first < frames { h.update(from: groupSends[g] + first, count: frames - first) }
                groupSilent[g] = 0
            } else if groupSilent[g] < size {
                vDSP_vclr(h + w, 1, vDSP_Length(first))
                if first < frames { vDSP_vclr(h, 1, vDSP_Length(frames - first)) }
                groupSilent[g] += frames
            }
        }

        // 2. Reflections into the ear buses.
        for b in buses { vDSP_vclr(b, 1, n) }
        for tap in taps[sizeIndex] where groupSilent[tap.group] < size {
            let h = history[tap.group], bus = buses[tap.bus]
            var gain = tap.gain
            let start = (w - tap.delay) & mask
            let first = min(frames, size - start)
            vDSP_vsma(h + start, 1, &gain, bus, 1, bus, 1, vDSP_Length(first))
            if first < frames { vDSP_vsma(h, 1, &gain, bus + first, 1, bus + first, 1, vDSP_Length(frames - first)) }
        }
        writeIndex = (w + frames) & mask

        // 3. One filter per bus, summed per ear.
        for ear in 0..<2 {
            let out = ear == 0 ? earlyL : earlyR
            let base = ear * Self.classes
            out.update(from: buses[base], count: frames)
            for k in 0..<4 {
                let b = buses[base + 1 + k], c = shadowCoef[k]
                var y = shadowState[ear * 4 + k]
                for i in 0..<frames { y += c * (b[i] - y); out[i] += y }
                shadowState[ear * 4 + k] = y
            }
            let up = buses[base + Self.above], down = buses[base + Self.below]
            upFilters[ear * 2].run(up, frames); upFilters[ear * 2 + 1].run(up, frames)
            downFilters[ear * 2].run(down, frames); downFilters[ear * 2 + 1].run(down, frames)
            vDSP_vadd(out, 1, up, 1, out, 1, n)
            vDSP_vadd(out, 1, down, 1, out, 1, n)
            earlyHP[ear].run(out, frames)
            var lp = ear == 0 ? earlyLPL : earlyLPR
            let lc = earlyLPCoef
            for i in 0..<frames { lp += lc * (out[i] - lp); out[i] = lp }
            if ear == 0 { earlyLPL = lp } else { earlyLPR = lp }
        }

        // 4. Late tail.
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
            let xl = hl.process(sendL[i]); ll += ic * (xl - ll)
            let xr = hr.process(sendR[i]); lr += ic * (xr - lr)
            let dl = diffuse(ll, 0), dr = diffuse(lr, 4)
            pL[pi] = dl; pR[pi] = dr
            let inL = pL[(pi - pre) & pMask], inR = pR[(pi - pre) & pMask]
            pi = (pi + 1) & pMask

            let s0 = lines[0][heads[0]], s1 = lines[1][heads[1]], s2 = lines[2][heads[2]], s3 = lines[3][heads[3]]
            let s4 = lines[4][heads[4]], s5 = lines[5][heads[5]], s6 = lines[6][heads[6]], s7 = lines[7][heads[7]]
            eg += eStep; lg += lStep
            outL[i] += earlyL[i] * eg + (s0 + s1 + s2 + s3 - s4 - s5 - s6 - s7) * lg
            outR[i] += earlyR[i] * eg + (s0 - s1 + s2 - s3 + s4 - s5 + s6 - s7) * lg
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
        inputHP[0] = hl; inputHP[1] = hr
        inputLPL = ll; inputLPR = lr
        predelayIndex = pi
    }
}
