import Accelerate
import Foundation

/// Block-streaming stereo → 7.1.4 upmixer.
///
/// Principal-component direct/ambience separation in the STFT domain (Merimaa, Goodwin
/// & Jot, AES 2007; Avendano & Jot, JAES 2004). Per bin, the smoothed 2×2 L/R covariance
/// gives the ambience power (small eigenvalue) and the direct sound's pan (principal
/// eigenvector). Direct sound is re-panned across Lss·L·C·R·Rss; ambience is decorrelated
/// (random-phase all-pass + short delay per output) and spread over surrounds and heights.
///
/// N = 2048, hop 512, periodic Hann on analysis and synthesis. Output lags input by
/// `latency` samples. Allocation-free after init.
///
/// Level-preserving steering (`coherentSteering`, the refined renderer): the steered part of
/// a source and the part left on L or R are the same signal, so where both land in the same
/// speaker they add in phase (+2.7 dB on L for a hard-left source at Centre 0.75). The steered
/// share into L/R is then scaled so the coherent sum carries the intended energy. Classic
/// adds them as if they were uncorrelated.
final class Upmixer {
    static let fftSize = 2048
    static let hop = 512
    /// Output order (see `Layout.upmix`).
    static let outputCount = 12

    private enum Slot {
        static let l = 0, r = 1, c = 2, lfe = 3, lss = 4, rss = 5, lrs = 6, rrs = 7
        static let ltf = 8, rtf = 9, ltr = 10, rtr = 11, lssDirect = 12, rssDirect = 13
        static let count = 14
        static let ambient = [lss, rss, lrs, rrs, ltf, rtf, ltr, rtr]
    }
    private static let ambientDelayMS: [Int: Double] = [
        Slot.lss: 7, Slot.rss: 9, Slot.lrs: 13, Slot.rrs: 16, Slot.ltf: 5, Slot.rtf: 6, Slot.ltr: 11, Slot.rtr: 12,
    ]

    let latency = Upmixer.fftSize

    private let n = Upmixer.fftSize, hop = Upmixer.hop, half = Upmixer.fftSize / 2
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let alpha: Float

    private let window: UnsafeMutablePointer<Float>
    private let histL: UnsafeMutablePointer<Float>, histR: UnsafeMutablePointer<Float>
    private let pendL: UnsafeMutablePointer<Float>, pendR: UnsafeMutablePointer<Float>
    private let ready: UnsafeMutablePointer<Float>            // 12 × hop
    private let ola: UnsafeMutablePointer<Float>              // 14 × n
    private let bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>, timeBuf: UnsafeMutablePointer<Float>
    private let reL: UnsafeMutablePointer<Float>, imL: UnsafeMutablePointer<Float>
    private let reR: UnsafeMutablePointer<Float>, imR: UnsafeMutablePointer<Float>
    private let outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>   // 14 × half
    private let pLL: UnsafeMutablePointer<Float>, pRR: UnsafeMutablePointer<Float>
    private let cRe: UnsafeMutablePointer<Float>, cIm: UnsafeMutablePointer<Float>
    private let phaseCos: UnsafeMutablePointer<Float>, phaseSin: UnsafeMutablePointer<Float>
    private let heightCurve: UnsafeMutablePointer<Float>, lfeCurve: UnsafeMutablePointer<Float>
    private let delayRing: UnsafeMutablePointer<Float>
    private let ringSize: Int, ringMask: Int
    private var ringWrite = 0
    private var delaySamples = [Int](repeating: 0, count: Slot.count)
    private var fill = 0
    private var allocations: [UnsafeMutablePointer<Float>] = []

    /// Per-bin scratch for the staged analysis.
    private struct Bins {
        let vL, vR, steer, sRe, sIm, mL, mR, gAL, gAR, theta, x, sin, cos: UnsafeMutablePointer<Float>
        let aLr, aLi, aRr, aRi, topF, topR: UnsafeMutablePointer<Float>
        /// Coherent steering: m·v·cos δ / √steer for L and R (the kept part's in-phase
        /// amplitude relative to the steered source).
        let cohL, cohR: UnsafeMutablePointer<Float>
        let segment: UnsafeMutablePointer<Int32>
        let active: UnsafeMutablePointer<Bool>
    }
    private let bin: Bins

    private struct Gains {
        var front: Float = 1, side: Float = 0, rear: Float = 0, topF: Float = 0, topR: Float = 0
        var maxAzimuth = 30.0
        var focus: Float = 0
        var lfe = false
    }
    private var gains = Gains()
    /// Refined renderer: level-preserving steering. Read once per frame.
    var coherentSteering = false

    init(sampleRate: Double, settings: UpmixSettings = UpmixSettings()) {
        let n = Upmixer.fftSize, half = n / 2, hop = Upmixer.hop
        log2n = vDSP_Length(log2(Double(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        alpha = Float(exp(-Double(hop) / (0.04 * sampleRate)))

        var all: [UnsafeMutablePointer<Float>] = []
        func buffer(_ count: Int, _ value: Float = 0) -> UnsafeMutablePointer<Float> {
            let p = makeBuffer(count, value)
            all.append(p)
            return p
        }
        window = buffer(n)
        for i in 0..<n { window[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))) }
        histL = buffer(n); histR = buffer(n)
        pendL = buffer(hop); pendR = buffer(hop)
        ready = buffer(Upmixer.outputCount * hop)
        ola = buffer(Slot.count * n)
        bufL = buffer(n); bufR = buffer(n); timeBuf = buffer(n)
        reL = buffer(half); imL = buffer(half); reR = buffer(half); imR = buffer(half)
        outRe = buffer(Slot.count * half); outIm = buffer(Slot.count * half)
        pLL = buffer(half); pRR = buffer(half); cRe = buffer(half); cIm = buffer(half)
        phaseCos = buffer(Slot.count * half, 1); phaseSin = buffer(Slot.count * half)
        heightCurve = buffer(half, 1); lfeCurve = buffer(half)
        bin = Bins(vL: buffer(half), vR: buffer(half), steer: buffer(half), sRe: buffer(half), sIm: buffer(half),
                   mL: buffer(half), mR: buffer(half), gAL: buffer(half), gAR: buffer(half), theta: buffer(half),
                   x: buffer(half), sin: buffer(half), cos: buffer(half),
                   aLr: buffer(half), aLi: buffer(half), aRr: buffer(half), aRi: buffer(half),
                   topF: buffer(half), topR: buffer(half), cohL: buffer(half), cohR: buffer(half),
                   segment: .allocate(capacity: half), active: .allocate(capacity: half))
        bin.segment.initialize(repeating: 0, count: half)
        bin.active.initialize(repeating: false, count: half)

        // Decorrelation: smooth random-phase walks (|Δφ| ≤ π/4 per bin, group delay ≤ n/8).
        var rng = SplitMix64(seed: 0x5F3A_91C2)
        for slot in Slot.ambient {
            var phi = 0.0
            for k in 0..<half {
                phi += (rng.nextUniform() * 2 - 1) * Double.pi / 4
                phaseCos[slot * half + k] = Float(cos(phi))
                phaseSin[slot * half + k] = Float(sin(phi))
            }
        }
        // Height ambience rolls off below ~180 Hz; LFE is a smooth 80–160 Hz low-pass.
        let binHz = sampleRate / Double(n)
        for k in 0..<half {
            let f = Double(k) * binHz
            heightCurve[k] = Float(min(1, pow(f / 180, 2)))
            lfeCurve[k] = f <= 80 ? 1 : (f >= 160 ? 0 : Float(0.5 + 0.5 * cos(Double.pi * (f - 80) / 80)))
        }
        var maxDelay = 0
        for (slot, ms) in Self.ambientDelayMS {
            delaySamples[slot] = Int(ms / 1000 * sampleRate)
            maxDelay = max(maxDelay, delaySamples[slot])
        }
        ringSize = nextPowerOfTwo(atLeast: maxDelay + 1)
        ringMask = ringSize - 1
        delayRing = buffer(Slot.count * ringSize)
        allocations = all
        update(settings: settings)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        allocations.forEach { $0.deallocate() }
        bin.segment.deallocate()
        bin.active.deallocate()
    }

    /// Allocation-free; takes effect from the next FFT frame.
    func update(settings: UpmixSettings) {
        let s = min(max(settings.surround, 0), 1)
        let h = min(max(settings.height, 0), 1)
        // Ambience destinations: front, side, rear, top-front, top-rear (energy-normalised).
        let r0 = 1.0, r1 = 1.0 * s, r2 = 0.8 * s, r3 = 0.7 * h, r4 = 0.6 * h
        let norm = (r0 * r0 + r1 * r1 + r2 * r2 + r3 * r3 + r4 * r4).squareRoot()
        var g = Gains()
        g.front = Float(r0 / norm); g.side = Float(r1 / norm); g.rear = Float(r2 / norm)
        g.topF = Float(r3 / norm); g.topR = Float(r4 / norm)
        g.maxAzimuth = 30 * (1 + 2 * min(max(settings.width, 0), 1))
        g.focus = Float(min(max(settings.centerExtraction, 0), 1))
        g.lfe = settings.generateLFE
        gains = g
    }

    /// Back to the just-created state (used before the upmixer resumes after idling).
    func reset() {
        vDSP_vclr(histL, 1, vDSP_Length(n)); vDSP_vclr(histR, 1, vDSP_Length(n))
        vDSP_vclr(pendL, 1, vDSP_Length(hop)); vDSP_vclr(pendR, 1, vDSP_Length(hop))
        vDSP_vclr(ready, 1, vDSP_Length(Upmixer.outputCount * hop))
        vDSP_vclr(ola, 1, vDSP_Length(Slot.count * n))
        vDSP_vclr(pLL, 1, vDSP_Length(half)); vDSP_vclr(pRR, 1, vDSP_Length(half))
        vDSP_vclr(cRe, 1, vDSP_Length(half)); vDSP_vclr(cIm, 1, vDSP_Length(half))
        vDSP_vclr(delayRing, 1, vDSP_Length(Slot.count * ringSize))
        ringWrite = 0
        fill = 0
    }

    /// Consumes `frames` stereo samples and writes `frames` samples to each of the 12
    /// outputs (in `Layout.upmix` order), delayed by `latency`.
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int,
                 outputs: UnsafePointer<UnsafeMutablePointer<Float>>) {
        var done = 0
        while done < frames {
            let k = min(frames - done, hop - fill)
            for ch in 0..<Upmixer.outputCount {
                outputs[ch].advanced(by: done).update(from: ready.advanced(by: ch * hop + fill), count: k)
            }
            pendL.advanced(by: fill).update(from: left.advanced(by: done), count: k)
            pendR.advanced(by: fill).update(from: right.advanced(by: done), count: k)
            fill += k
            done += k
            if fill == hop {
                runFrame()
                fill = 0
            }
        }
    }

    // MARK: - Frame

    private func runFrame() {
        let n = self.n, hop = self.hop, half = self.half
        histL.update(from: histL.advanced(by: hop), count: n - hop)
        histR.update(from: histR.advanced(by: hop), count: n - hop)
        histL.advanced(by: n - hop).update(from: pendL, count: hop)
        histR.advanced(by: n - hop).update(from: pendR, count: hop)
        vDSP_vmul(histL, 1, window, 1, bufL, 1, vDSP_Length(n))
        vDSP_vmul(histR, 1, window, 1, bufR, 1, vDSP_Length(n))
        forward(bufL, re: reL, im: imL)
        forward(bufR, re: reR, im: imR)

        vDSP_vclr(outRe, 1, vDSP_Length(Slot.count * half))
        vDSP_vclr(outIm, 1, vDSP_Length(Slot.count * half))
        // Packed DC (re[0]) and Nyquist (im[0]) pass straight to L/R.
        outRe[Slot.l * half] = reL[0]; outIm[Slot.l * half] = imL[0]
        outRe[Slot.r * half] = reR[0]; outIm[Slot.r * half] = imR[0]

        let directUsed = analyse()

        // Which slots carry anything this frame (an all-zero spectrum adds nothing).
        let g = gains
        var unused: UInt32 = 0
        func skip(_ slot: Int, _ condition: Bool) { if condition { unused |= 1 << UInt32(slot) } }
        skip(Slot.lfe, !g.lfe)
        skip(Slot.c, g.focus <= 0)
        skip(Slot.lss, g.side == 0); skip(Slot.rss, g.side == 0)
        skip(Slot.lrs, g.rear == 0); skip(Slot.rrs, g.rear == 0)
        skip(Slot.ltf, g.topF == 0); skip(Slot.rtf, g.topF == 0)
        skip(Slot.ltr, g.topR == 0); skip(Slot.rtr, g.topR == 0)
        skip(Slot.lssDirect, !directUsed.left)
        skip(Slot.rssDirect, !directUsed.right)

        // Synthesis + overlap-add. vDSP's real FFT round trip scales by 2n; Σw² = 1.5.
        var scale = 1 / (1.5 * Float(2 * n))
        for slot in 0..<Slot.count where unused & (1 << UInt32(slot)) == 0 {
            inverse(re: outRe.advanced(by: slot * half), im: outIm.advanced(by: slot * half), into: timeBuf)
            vDSP_vmul(timeBuf, 1, window, 1, timeBuf, 1, vDSP_Length(n))
            let dst = ola.advanced(by: slot * n)
            vDSP_vsma(timeBuf, 1, &scale, dst, 1, dst, 1, vDSP_Length(n))
        }

        // The oldest hop of the OLA buffer is complete: emit it.
        let mask = ringMask
        for ch in 0..<Upmixer.outputCount {
            let src = ola.advanced(by: ch * n)
            let out = ready.advanced(by: ch * hop)
            let delay = delaySamples[ch]
            if delay > 0 {
                let ring = delayRing.advanced(by: ch * ringSize)
                var w = ringWrite
                for i in 0..<hop {
                    ring[w] = src[i]
                    out[i] = ring[(w - delay) & mask]
                    w = (w + 1) & mask
                }
            } else {
                out.update(from: src, count: hop)
            }
        }
        ringWrite = (ringWrite + hop) & mask
        // Widened direct sound joins Lss/Rss without the ambience delay.
        vDSP_vadd(ready.advanced(by: Slot.lss * hop), 1, ola.advanced(by: Slot.lssDirect * n), 1,
                  ready.advanced(by: Slot.lss * hop), 1, vDSP_Length(hop))
        vDSP_vadd(ready.advanced(by: Slot.rss * hop), 1, ola.advanced(by: Slot.rssDirect * n), 1,
                  ready.advanced(by: Slot.rss * hop), 1, vDSP_Length(hop))

        for slot in 0..<Slot.count {
            let p = ola.advanced(by: slot * n)
            p.update(from: p.advanced(by: hop), count: n - hop)
            vDSP_vclr(p.advanced(by: n - hop), 1, vDSP_Length(hop))
        }
    }

    /// Per-bin analysis and steering. Returns whether the widened direct slots were used.
    ///
    /// Staged so the expensive parts run vectorised: (1) a scalar pass over the bins for
    /// the covariance, eigen-decomposition and masks; (2) the pan angle for every bin with
    /// one `vvatan2f`; (3) the pan gains with one `vvsincosf`; (4) the steered direct
    /// sound and front L/R; (5) the eight decorrelated ambience sends as vector complex
    /// multiplies.
    private func analyse() -> (left: Bool, right: Bool) {
        let half = self.half, count = half - 1
        let g = gains
        let coherent = coherentSteering
        let cohL = bin.cohL, cohR = bin.cohR
        let alpha = self.alpha, oneMinusAlpha = 1 - alpha
        let reL = self.reL, imL = self.imL, reR = self.reR, imR = self.imR
        let pLL = self.pLL, pRR = self.pRR, cRe = self.cRe, cIm = self.cIm
        let outRe = self.outRe, outIm = self.outIm
        let bin = self.bin
        let vL = bin.vL, vR = bin.vR, steerB = bin.steer, sRe = bin.sRe, sIm = bin.sIm
        let mL = bin.mL, mR = bin.mR, gAL = bin.gAL, gAR = bin.gAR, active = bin.active
        let theta = bin.theta, x = bin.x, sinB = bin.sin, cosB = bin.cos, segment = bin.segment

        // 1. Covariance, eigen-decomposition, masks: 8 bins per step, branch-free.
        typealias V = SIMD8<Float>
        @inline(__always) func load(_ p: UnsafeMutablePointer<Float>, _ k: Int) -> V {
            UnsafeRawPointer(p + k).loadUnaligned(as: V.self)
        }
        @inline(__always) func store(_ v: V, _ p: UnsafeMutablePointer<Float>, _ k: Int) {
            UnsafeMutableRawPointer(p + k).storeBytes(of: v, as: V.self)
        }
        let va = V(repeating: alpha), vb = V(repeating: oneMinusAlpha)
        let zero = V(repeating: 0), one = V(repeating: 1), half5 = V(repeating: 0.5), tiny = V(repeating: 1e-12)
        let focus = V(repeating: g.focus), front2 = V(repeating: g.front * g.front)
        var steering = SIMDMask<SIMD8<Int32>>(repeating: false)
        for k in stride(from: 0, to: half, by: 8) {
            let xlr = load(reL, k), xli = load(imL, k), xrr = load(reR, k), xri = load(imR, k)
            let eL = xlr * xlr + xli * xli
            let eR = xrr * xrr + xri * xri
            let crossRe = xlr * xrr + xli * xri      // L·conj(R)
            let crossIm = xli * xrr - xlr * xri
            let a = va * load(pLL, k) + vb * eL
            let b = va * load(pRR, k) + vb * eR
            let cr = va * load(cRe, k) + vb * crossRe
            let ci = va * load(cIm, k) + vb * crossIm
            store(a, pLL, k); store(b, pRR, k); store(cr, cRe, k); store(ci, cIm, k)

            let total = a + b
            let live = total .>= tiny
            let cMag2 = cr * cr + ci * ci
            let disc = ((a - b) * (a - b) + 4 * cMag2).squareRoot()
            let lambda1 = half5 * (total + disc)
            let lambda2 = pointwiseMax(zero, half5 * (total - disc))

            // Energy-preserving ambient / direct masks per channel.
            let al = pointwiseMin(one, (lambda2 / a).squareRoot()).replacing(with: 0, where: .!(a .> tiny))
            let ar = pointwiseMin(one, (lambda2 / b).squareRoot()).replacing(with: 0, where: .!(b .> tiny))
            let gDL = (one - al * al).squareRoot()
            let gDR = (one - ar * ar).squareRoot()

            // Principal direction.
            let vL2 = pointwiseMin(pointwiseMax((lambda1 - b) / disc, zero), one).replacing(with: 0.5, where: .!(disc .> tiny))
            let l = vL2.squareRoot()
            let r = (one - vL2).squareRoot()

            // Only in-phase direct sound is steered; anti-phase stays on L/R.
            let cMag = cMag2.squareRoot()
            let cosPhase = pointwiseMax(zero, cr / cMag).replacing(with: 0, where: .!(cMag .> tiny))
            let steer = focus * (one - 2 * l * r * (one - cosPhase))

            // Steered source Ŝ: energy of both direct parts, phase of the weighted sum.
            let dlr = gDL * xlr, dli = gDL * xli, drr = gDR * xrr, dri = gDR * xri
            let sMag = (dlr * dlr + dli * dli + drr * drr + dri * dri).squareRoot()
            var sumRe = l * dlr + r * drr
            var sumIm = l * dli + r * dri
            var sumMag = (sumRe * sumRe + sumIm * sumIm).squareRoot()
            let degenerate = sumMag .< 1e-9 * pointwiseMax(sMag, V(repeating: 1e-30))
            if any(degenerate) {
                let leftWins = a .>= b
                let fRe = drr.replacing(with: dlr, where: leftWins), fIm = dri.replacing(with: dli, where: leftWins)
                sumRe.replace(with: fRe, where: degenerate)
                sumIm.replace(with: fIm, where: degenerate)
                sumMag.replace(with: pointwiseMax((fRe * fRe + fIm * fIm).squareRoot(), V(repeating: 1e-30)), where: degenerate)
            }
            let steerRoot = steer.squareRoot()
            store(sMag * sumRe / sumMag * steerRoot, sRe, k)
            store(sMag * sumIm / sumMag * steerRoot, sIm, k)

            // Front L/R: unsteered direct + front ambience, as uncorrelated energies.
            let keep = one - steer
            let mLk = (gDL * gDL * keep + front2 * al * al).squareRoot().replacing(with: 0, where: .!live)
            let mRk = (gDR * gDR * keep + front2 * ar * ar).squareRoot().replacing(with: 0, where: .!live)
            store(mLk, mL, k)
            store(mRk, mR, k)

            if coherent {
                // Model: X_L = l·s, X_R = r·s·e^{iψ}. The steered source has the phase of
                // l²+r²e^{iψ}, i.e. δ_L from X_L and δ_R from X_R. The part left in L has
                // in-phase amplitude m_L·l·cos δ_L per unit of the steered source's √steer.
                let l2 = vL2, r2 = one - vL2
                let cosPsi = (cr / cMag).replacing(with: 1, where: .!(cMag .> tiny))
                let den = pointwiseMax(l2 * l2 + r2 * r2 + 2 * l2 * r2 * cosPsi, zero).squareRoot()
                let ok = (den .> tiny) .& (steerRoot .> tiny)
                let cosL = (l2 + r2 * cosPsi) / den, cosR = (r2 + l2 * cosPsi) / den
                store((mLk * l * cosL / steerRoot).replacing(with: 0, where: .!ok), cohL, k)
                store((mRk * r * cosR / steerRoot).replacing(with: 0, where: .!ok), cohR, k)
            }
            store(l.replacing(with: 1, where: .!live), vL, k)
            store(r.replacing(with: 0, where: .!live), vR, k)
            let st = steer.replacing(with: 0, where: .!live)
            store(st, steerB, k)
            store(al.replacing(with: 0, where: .!live), gAL, k)
            store(ar.replacing(with: 0, where: .!live), gAR, k)
            for j in 0..<8 { active[k + j] = live[j] }
            steering .|= st .> zero
        }
        let anySteer = any(steering)

        var usedLeft = false, usedRight = false
        if anySteer {
            // 2. Pan angle θ = atan2(vR, vL) for every bin; p = θ/(π/4) − 1 ∈ [−1, 1].
            var n32 = Int32(count)
            vvatan2f(theta.advanced(by: 1), vR.advanced(by: 1), vL.advanced(by: 1), &n32)
            // Azimuth along Lss(−90) L(−30) C(0) R(30) Rss(90): segment and position in it.
            let maxAz = V(repeating: Float(g.maxAzimuth)), quarterPi = V(repeating: Float.pi / 4)
            let m90 = V(repeating: -90), m30 = V(repeating: -30), p30 = V(repeating: 30), p90 = V(repeating: 90)
            let halfPi = V(repeating: Float.pi / 2)
            for k in stride(from: 0, to: half, by: 8) {
                let p = load(theta, k) / quarterPi - one
                let az = pointwiseMin(pointwiseMax(p * maxAz, m90), p90)
                let s0 = az .<= m30, s1 = az .<= zero, s2 = az .<= p30
                let lo = p30.replacing(with: zero, where: s2).replacing(with: m30, where: s1).replacing(with: m90, where: s0)
                let hi = p90.replacing(with: p30, where: s2).replacing(with: zero, where: s1).replacing(with: m30, where: s0)
                store((az - lo) / (hi - lo) * halfPi, x, k)
                let seg = SIMD8<Int32>(repeating: 3).replacing(with: 2, where: s2).replacing(with: 1, where: s1).replacing(with: 0, where: s0)
                UnsafeMutableRawPointer(segment + k).storeBytes(of: seg, as: SIMD8<Int32>.self)
            }
            // 3. Constant-power pan gains for every bin at once.
            vvsincosf(sinB.advanced(by: 1), cosB.advanced(by: 1), x.advanced(by: 1), &n32)

            // 4. Steered direct sound into the five frontal slots (zero where not steered).
            let sl = Slot.lssDirect * half, ll = Slot.l * half, cc = Slot.c * half, rr = Slot.r * half, sr = Slot.rssDirect * half
            if coherent {
                // Scale the steered share g into L/R by k so that |kept + k·g·S|² equals
                // kept² + g²·S² for in-phase parts: k = √(b² + 1) − b with b = cohX / g,
                // written as 1/(√(b² + 1) + b). Anti-phase (b ≤ 0) is never boosted.
                @inline(__always) func scaled(_ g: Float, _ c: Float) -> Float {
                    guard g > 0, c > 0 else { return g }
                    let b = c / g
                    return g / ((b * b + 1).squareRoot() + b)
                }
                for k in 1..<half where steerB[k] > 0 {
                    switch segment[k] {
                    case 0: sinB[k] = scaled(sinB[k], cohL[k])
                    case 1: cosB[k] = scaled(cosB[k], cohL[k])
                    case 2: sinB[k] = scaled(sinB[k], cohR[k])
                    default: cosB[k] = scaled(cosB[k], cohR[k])
                    }
                }
            }
            for k in 1..<half where steerB[k] > 0 {
                let lo = cosB[k], hi = sinB[k]
                let re = sRe[k], im = sIm[k]
                switch segment[k] {
                case 0:
                    outRe[sl + k] += lo * re; outIm[sl + k] += lo * im
                    outRe[ll + k] += hi * re; outIm[ll + k] += hi * im
                    if lo != 0 { usedLeft = true }
                case 1:
                    outRe[ll + k] += lo * re; outIm[ll + k] += lo * im
                    outRe[cc + k] += hi * re; outIm[cc + k] += hi * im
                case 2:
                    outRe[cc + k] += lo * re; outIm[cc + k] += lo * im
                    outRe[rr + k] += hi * re; outIm[rr + k] += hi * im
                default:
                    outRe[rr + k] += lo * re; outIm[rr + k] += lo * im
                    outRe[sr + k] += hi * re; outIm[sr + k] += hi * im
                    if hi != 0 { usedRight = true }
                }
            }
        }

        // Front L/R (mL/mR are zero for silent bins).
        let n = vDSP_Length(count)
        vDSP_vma(mL + 1, 1, reL + 1, 1, outRe + Slot.l * half + 1, 1, outRe + Slot.l * half + 1, 1, n)
        vDSP_vma(mL + 1, 1, imL + 1, 1, outIm + Slot.l * half + 1, 1, outIm + Slot.l * half + 1, 1, n)
        vDSP_vma(mR + 1, 1, reR + 1, 1, outRe + Slot.r * half + 1, 1, outRe + Slot.r * half + 1, 1, n)
        vDSP_vma(mR + 1, 1, imR + 1, 1, outIm + Slot.r * half + 1, 1, outIm + Slot.r * half + 1, 1, n)

        // 5. Decorrelated ambience: A = gA·X, out = gain · (A ⊙ e^{jφ_slot}).
        let aLr = bin.aLr + 1, aLi = bin.aLi + 1, aRr = bin.aRr + 1, aRi = bin.aRi + 1
        vDSP_vmul(gAL + 1, 1, reL + 1, 1, aLr, 1, n); vDSP_vmul(gAL + 1, 1, imL + 1, 1, aLi, 1, n)
        vDSP_vmul(gAR + 1, 1, reR + 1, 1, aRr, 1, n); vDSP_vmul(gAR + 1, 1, imR + 1, 1, aRi, 1, n)
        var ambL = DSPSplitComplex(realp: aLr, imagp: aLi)
        var ambR = DSPSplitComplex(realp: aRr, imagp: aRi)
        let topF = bin.topF + 1, topR = bin.topR + 1
        var gf = g.topF, gr = g.topR
        vDSP_vsmul(heightCurve + 1, 1, &gf, topF, 1, n)
        vDSP_vsmul(heightCurve + 1, 1, &gr, topR, 1, n)
        func ambience(_ slot: Int, _ source: inout DSPSplitComplex, scalar: Float, vector: UnsafeMutablePointer<Float>?) {
            let offset = slot * half + 1
            var phase = DSPSplitComplex(realp: phaseCos + offset, imagp: phaseSin + offset)
            var out = DSPSplitComplex(realp: outRe + offset, imagp: outIm + offset)
            vDSP_zvmul(&source, 1, &phase, 1, &out, 1, n, 1)
            if let vector {
                vDSP_vmul(out.realp, 1, vector, 1, out.realp, 1, n)
                vDSP_vmul(out.imagp, 1, vector, 1, out.imagp, 1, n)
            } else {
                var s = scalar
                vDSP_vsmul(out.realp, 1, &s, out.realp, 1, n)
                vDSP_vsmul(out.imagp, 1, &s, out.imagp, 1, n)
            }
        }
        if g.side != 0 {
            ambience(Slot.lss, &ambL, scalar: g.side, vector: nil)
            ambience(Slot.rss, &ambR, scalar: g.side, vector: nil)
        }
        if g.rear != 0 {
            ambience(Slot.lrs, &ambL, scalar: g.rear, vector: nil)
            ambience(Slot.rrs, &ambR, scalar: g.rear, vector: nil)
        }
        if g.topF != 0 {
            ambience(Slot.ltf, &ambL, scalar: 0, vector: topF)
            ambience(Slot.rtf, &ambR, scalar: 0, vector: topF)
        }
        if g.topR != 0 {
            ambience(Slot.ltr, &ambL, scalar: 0, vector: topR)
            ambience(Slot.rtr, &ambR, scalar: 0, vector: topR)
        }

        // Optional LFE: a smooth 80–160 Hz low-pass of the mono sum (a handful of bins).
        if g.lfe {
            for k in 1..<half where active[k] {
                let c = lfeCurve[k]
                guard c > 0 else { break }
                let gl = 0.5 * c
                outRe[Slot.lfe * half + k] = gl * (reL[k] + reR[k])
                outIm[Slot.lfe * half + k] = gl * (imL[k] + imR[k])
            }
        }
        return (usedLeft, usedRight)
    }

    // MARK: - FFT

    private func forward(_ buffer: UnsafeMutablePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        buffer.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    }

    private func inverse(re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>, into buffer: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        buffer.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
            vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(half))
        }
    }
}
