import Accelerate
import Foundation

/// Block-streaming stereo → 7.x.4 upmixer (the single implementation behind `Upmixer`).
///
/// Accepts any block size. Output lags input by `latency` samples (one FFT frame).
/// All buffers are allocated in `init`; `process` and `update` do not allocate, so they
/// are safe on a real-time audio thread. See `Upmixer` for the algorithm description.
public final class StreamingUpmixer {
    public static let fftSize = 2048
    public static let hop = 512
    /// Output channel order (7.1.4, WAVE order). LFE stays silent unless `generateLFE`.
    public static let speakers: [Speaker] = [.l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs, .ltf, .rtf, .ltr, .rtr]

    public var latency: Int { n }

    // Spectral output slots: the 12 speakers, plus widened direct sound for Lss/Rss
    // which bypasses the ambience delay.
    private enum Slot {
        static let l = 0, r = 1, c = 2, lfe = 3, lss = 4, rss = 5, lrs = 6, rrs = 7
        static let ltf = 8, rtf = 9, ltr = 10, rtr = 11, lssDirect = 12, rssDirect = 13
        static let count = 14
        static let ambient = [lss, rss, lrs, rrs, ltf, rtf, ltr, rtr]
    }
    private static let ambientDelayMS: [Int: Double] = [
        Slot.lss: 7, Slot.rss: 9, Slot.lrs: 13, Slot.rrs: 16, Slot.ltf: 5, Slot.rtf: 6, Slot.ltr: 11, Slot.rtr: 12,
    ]

    private let n = StreamingUpmixer.fftSize
    private let hop = StreamingUpmixer.hop
    private let half = StreamingUpmixer.fftSize / 2
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let sampleRate: Double
    private let alpha: Float

    // Buffers (flat, allocated once).
    private let window: UnsafeMutablePointer<Float>
    private let histL: UnsafeMutablePointer<Float>, histR: UnsafeMutablePointer<Float>
    private let pendL: UnsafeMutablePointer<Float>, pendR: UnsafeMutablePointer<Float>
    private let ready: UnsafeMutablePointer<Float>           // 12 × hop
    private let ola: UnsafeMutablePointer<Float>             // 14 × n
    private let bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>, timeBuf: UnsafeMutablePointer<Float>
    private let reL: UnsafeMutablePointer<Float>, imL: UnsafeMutablePointer<Float>
    private let reR: UnsafeMutablePointer<Float>, imR: UnsafeMutablePointer<Float>
    private let outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>   // 14 × half
    private let pLL: UnsafeMutablePointer<Float>, pRR: UnsafeMutablePointer<Float>
    private let cRe: UnsafeMutablePointer<Float>, cIm: UnsafeMutablePointer<Float>
    private let phaseCos: UnsafeMutablePointer<Float>, phaseSin: UnsafeMutablePointer<Float>  // 14 × half
    private let heightCurve: UnsafeMutablePointer<Float>, lfeCurve: UnsafeMutablePointer<Float>
    private let delayRing: UnsafeMutablePointer<Float>      // 14 × ringSize (ambient slots used)
    private let ringMask: Int
    private var ringWrite = 0
    private var delaySamples = [Int](repeating: 0, count: 14)
    private var fill = 0

    // Settings-derived values (scalars only, so `update` is allocation-free).
    private var gFront: Float = 1, gSide: Float = 0, gRear: Float = 0, gTopF: Float = 0, gTopR: Float = 0
    private var maxAzimuth = 30.0
    private var focus: Float = 0
    private var lfeEnabled = false

    public init(sampleRate: Double, settings: UpmixSettings = UpmixSettings()) {
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(StreamingUpmixer.fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        alpha = Float(exp(-Double(StreamingUpmixer.hop) / (0.04 * sampleRate)))

        func buffer(_ count: Int, _ value: Float = 0) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: value, count: count)
            return p
        }
        let n = StreamingUpmixer.fftSize, half = n / 2, hop = StreamingUpmixer.hop
        window = buffer(n)
        // Periodic Hann; with hop n/4, Σw² = 1.5 so analysis·synthesis OLA is flat.
        for i in 0..<n { window[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))) }
        histL = buffer(n); histR = buffer(n)
        pendL = buffer(hop); pendR = buffer(hop)
        ready = buffer(12 * hop)
        ola = buffer(Slot.count * n)
        bufL = buffer(n); bufR = buffer(n); timeBuf = buffer(n)
        reL = buffer(half); imL = buffer(half); reR = buffer(half); imR = buffer(half)
        outRe = buffer(Slot.count * half); outIm = buffer(Slot.count * half)
        pLL = buffer(half); pRR = buffer(half); cRe = buffer(half); cIm = buffer(half)
        phaseCos = buffer(Slot.count * half, 1); phaseSin = buffer(Slot.count * half)
        heightCurve = buffer(half, 1); lfeCurve = buffer(half)

        // Decorrelation: smooth random-phase walks (group delay ≤ n/8 samples).
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
        var size = 1
        while size < maxDelay + 1 { size <<= 1 }
        ringMask = size - 1
        delayRing = buffer(Slot.count * size)
        update(settings: settings)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for p in [window, histL, histR, pendL, pendR, ready, ola, bufL, bufR, timeBuf, reL, imL, reR, imR,
                  outRe, outIm, pLL, pRR, cRe, cIm, phaseCos, phaseSin, heightCurve, lfeCurve, delayRing] {
            p.deallocate()
        }
    }

    /// Applies new settings. Allocation-free; takes effect from the next FFT frame.
    public func update(settings: UpmixSettings) {
        let s = min(max(settings.surround, 0), 1)
        let h = min(max(settings.height, 0), 1)
        // Ambience destinations: front, side, rear, top-front, top-rear (energy-normalised).
        let r0 = 1.0, r1 = 1.0 * s, r2 = 0.8 * s, r3 = 0.7 * h, r4 = 0.6 * h
        let norm = (r0 * r0 + r1 * r1 + r2 * r2 + r3 * r3 + r4 * r4).squareRoot()
        gFront = Float(r0 / norm); gSide = Float(r1 / norm); gRear = Float(r2 / norm)
        gTopF = Float(r3 / norm); gTopR = Float(r4 / norm)
        maxAzimuth = 30 * (1 + 2 * min(max(settings.width, 0), 1))
        focus = Float(min(max(settings.centerExtraction, 0), 1))
        lfeEnabled = settings.generateLFE
    }

    /// Consumes `frames` stereo samples and writes `frames` samples to each of the 12
    /// `outputs` (in `speakers` order), delayed by `latency`.
    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int,
                        outputs: inout [UnsafeMutablePointer<Float>]) {
        var done = 0
        while done < frames {
            let k = min(frames - done, hop - fill)
            for ch in 0..<12 {
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
        // Slide the analysis history by one hop.
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
        // Packed DC (re[0]) and Nyquist (im[0]): pass straight to L/R.
        outRe[Slot.l * half] = reL[0]; outIm[Slot.l * half] = imL[0]
        outRe[Slot.r * half] = reR[0]; outIm[Slot.r * half] = imR[0]

        for k in 1..<half { analyseBin(k) }

        // Synthesis + overlap-add. vDSP real FFT round trip scales by 2n; Σw² = 1.5.
        var scale = 1 / (1.5 * Float(2 * n))
        for slot in 0..<Slot.count {
            if slot == Slot.lfe, !lfeEnabled { continue }
            inverse(re: outRe.advanced(by: slot * half), im: outIm.advanced(by: slot * half), into: timeBuf)
            vDSP_vmul(timeBuf, 1, window, 1, timeBuf, 1, vDSP_Length(n))
            let dst = ola.advanced(by: slot * n)
            vDSP_vsma(timeBuf, 1, &scale, dst, 1, dst, 1, vDSP_Length(n))
        }

        // The oldest hop of the OLA buffer is complete: emit it.
        let ringSize = ringMask + 1
        for ch in 0..<12 {
            let src = ola.advanced(by: ch * n)
            let out = ready.advanced(by: ch * hop)
            let delay = delaySamples[ch]
            if delay > 0 {
                let ring = delayRing.advanced(by: ch * ringSize)
                var w = ringWrite
                for i in 0..<hop {
                    ring[w] = src[i]
                    out[i] = ring[(w - delay) & ringMask]
                    w = (w + 1) & ringMask
                }
            } else {
                out.update(from: src, count: hop)
            }
        }
        ringWrite = (ringWrite + hop) & ringMask
        vDSP_vadd(ready.advanced(by: Slot.lss * hop), 1, ola.advanced(by: Slot.lssDirect * n), 1,
                  ready.advanced(by: Slot.lss * hop), 1, vDSP_Length(hop))
        vDSP_vadd(ready.advanced(by: Slot.rss * hop), 1, ola.advanced(by: Slot.rssDirect * n), 1,
                  ready.advanced(by: Slot.rss * hop), 1, vDSP_Length(hop))

        // Shift every OLA accumulator by one hop.
        for slot in 0..<Slot.count {
            let p = ola.advanced(by: slot * n)
            p.update(from: p.advanced(by: hop), count: n - hop)
            vDSP_vclr(p.advanced(by: n - hop), 1, vDSP_Length(hop))
        }
    }

    @inline(__always)
    private func add(_ slot: Int, _ k: Int, _ re: Float, _ im: Float) {
        outRe[slot * half + k] += re
        outIm[slot * half + k] += im
    }

    @inline(__always)
    private func send(_ slot: Int, _ k: Int, _ g: Float, _ re: Float, _ im: Float) {
        let c = phaseCos[slot * half + k], s = phaseSin[slot * half + k]
        outRe[slot * half + k] += g * (re * c - im * s)
        outIm[slot * half + k] += g * (re * s + im * c)
    }

    private func analyseBin(_ k: Int) {
        let xlr = reL[k], xli = imL[k], xrr = reR[k], xri = imR[k]
        let eL = xlr * xlr + xli * xli
        let eR = xrr * xrr + xri * xri
        let crossRe = xlr * xrr + xli * xri      // L·conj(R)
        let crossIm = xli * xrr - xlr * xri
        pLL[k] = alpha * pLL[k] + (1 - alpha) * eL
        pRR[k] = alpha * pRR[k] + (1 - alpha) * eR
        cRe[k] = alpha * cRe[k] + (1 - alpha) * crossRe
        cIm[k] = alpha * cIm[k] + (1 - alpha) * crossIm

        let a = pLL[k], b = pRR[k]
        let total = a + b
        if total < 1e-12 { return }
        let cMag2 = cRe[k] * cRe[k] + cIm[k] * cIm[k]
        let disc = ((a - b) * (a - b) + 4 * cMag2).squareRoot()
        let lambda1 = 0.5 * (total + disc)
        let lambda2 = max(0, 0.5 * (total - disc))

        // Ambient / direct split per channel (energy-preserving masks).
        let gAL = a > 1e-12 ? min(1, (lambda2 / a).squareRoot()) : 0
        let gAR = b > 1e-12 ? min(1, (lambda2 / b).squareRoot()) : 0
        let gDL = (1 - gAL * gAL).squareRoot()
        let gDR = (1 - gAR * gAR).squareRoot()

        // Principal direction → pan position p ∈ [−1, 1].
        var vL2: Float = 0.5
        if disc > 1e-12 { vL2 = min(max((lambda1 - b) / disc, 0), 1) }
        let vL = vL2.squareRoot()
        let vR = (1 - vL2).squareRoot()
        let p = Double(atan2(vR, vL) / (Float.pi / 4) - 1)

        // Only in-phase direct sound is steered; anti-phase stays on L/R. Phase only
        // matters when both channels carry the source (balance → 1 at centre).
        let cMag = cMag2.squareRoot()
        let cosPhase = cMag > 1e-12 ? max(0, cRe[k] / cMag) : 0
        let steer = focus * (1 - 2 * vL * vR * (1 - cosPhase))

        // Steered direct source Ŝ: energy of both direct parts, phase of the weighted sum.
        let dlr = gDL * xlr, dli = gDL * xli, drr = gDR * xrr, dri = gDR * xri
        let sMag = (dlr * dlr + dli * dli + drr * drr + dri * dri).squareRoot()
        var sumRe = vL * dlr + vR * drr
        var sumIm = vL * dli + vR * dri
        var sumMag = (sumRe * sumRe + sumIm * sumIm).squareRoot()
        if sumMag < 1e-9 * max(sMag, 1e-30) {
            if a >= b { sumRe = dlr; sumIm = dli } else { sumRe = drr; sumIm = dri }
            sumMag = max((sumRe * sumRe + sumIm * sumIm).squareRoot(), 1e-30)
        }
        let steerRoot = steer.squareRoot()
        let sRe = sMag * sumRe / sumMag * steerRoot
        let sIm = sMag * sumIm / sumMag * steerRoot

        if steer > 0 {
            // Constant-power pan along Lss(−90) L(−30) C(0) R(30) Rss(90).
            let az = min(max(p * maxAzimuth, -90), 90)
            var g0: Float = 0, g1: Float = 0, g2: Float = 0, g3: Float = 0, g4: Float = 0
            func pair(_ lo: Double, _ hi: Double) -> (Float, Float) {
                let t = (az - lo) / (hi - lo)
                return (Float(cos(t * Double.pi / 2)), Float(sin(t * Double.pi / 2)))
            }
            if az <= -30 { (g0, g1) = pair(-90, -30) }
            else if az <= 0 { (g1, g2) = pair(-30, 0) }
            else if az <= 30 { (g2, g3) = pair(0, 30) }
            else { (g3, g4) = pair(30, 90) }
            add(Slot.lssDirect, k, g0 * sRe, g0 * sIm)
            add(Slot.l, k, g1 * sRe, g1 * sIm)
            add(Slot.c, k, g2 * sRe, g2 * sIm)
            add(Slot.r, k, g3 * sRe, g3 * sIm)
            add(Slot.rssDirect, k, g4 * sRe, g4 * sIm)
        }

        // Front L/R: unsteered direct + front ambience, combined as uncorrelated energies.
        let keep = 1 - steer
        let mL = (gDL * gDL * keep + gFront * gFront * gAL * gAL).squareRoot()
        let mR = (gDR * gDR * keep + gFront * gFront * gAR * gAR).squareRoot()
        add(Slot.l, k, mL * xlr, mL * xli)
        add(Slot.r, k, mR * xrr, mR * xri)

        // Decorrelated ambience to surrounds and heights.
        let alr = gAL * xlr, ali = gAL * xli, arr = gAR * xrr, ari = gAR * xri
        let hc = heightCurve[k]
        send(Slot.lss, k, gSide, alr, ali); send(Slot.rss, k, gSide, arr, ari)
        send(Slot.lrs, k, gRear, alr, ali); send(Slot.rrs, k, gRear, arr, ari)
        send(Slot.ltf, k, gTopF * hc, alr, ali); send(Slot.rtf, k, gTopF * hc, arr, ari)
        send(Slot.ltr, k, gTopR * hc, alr, ali); send(Slot.rtr, k, gTopR * hc, arr, ari)

        if lfeEnabled, lfeCurve[k] > 0 {
            let g = 0.5 * lfeCurve[k]
            outRe[Slot.lfe * half + k] = g * (xlr + xrr)
            outIm[Slot.lfe * half + k] = g * (xli + xri)
        }
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
