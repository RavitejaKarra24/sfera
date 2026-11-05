import Foundation
import LegacyCore
import SferaCore

// Sfera 0.9 engine (LegacyCore) vs the rewrite (SferaCore): same input, same block size.
// Reports the output difference relative to the signal, and CPU time per second of audio.
//
// Two float artefacts of 0.9 are fixed in the rewrite, and show up as small differences:
// - 0.9's content crossfade `w += (1 − w)·c` stalls at 1 − 7·10⁻⁵, so its surround output
//   always carried the stereo upmix at −83 dB. Surround is therefore also compared with
//   0.9's surround chain on its own, which the rewrite matches.
// - 0.9's limiter release stalls 0.002 dB short of unity after the first peak it catches.
// Surround material also differs by ~−88 dB on the LFE alone: the 80 Hz low-pass sits close
// to DC, where single-precision rounding order shifts its phase by ~0.006 samples.
// `--channels` compares each bed channel on its own.

setvbuf(stdout, nil, _IONBF, 0)
let sampleRate = 48000.0
let block = 512

// MARK: - Test material

struct Rng {
    var s: UInt64
    mutating func next() -> Float {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(Double(z >> 11) / Double(UInt64(1) << 53)) * 2 - 1
    }
}

/// Music-like stereo: centred vocal, panned guitar, wide pad, partly correlated noise.
func stereo(_ seconds: Double, seed: UInt64 = 1) -> [[Float]] {
    let n = Int(seconds * sampleRate)
    var rng = Rng(s: seed)
    var l = [Float](repeating: 0, count: n), r = l
    var pinkL: Float = 0, pinkR: Float = 0, common: Float = 0
    for i in 0..<n {
        let t = Double(i) / sampleRate
        let env = Float(0.6 + 0.4 * sin(2 * .pi * 0.7 * t))
        let vocal = Float(0.22 * sin(2 * .pi * 440 * t) + 0.08 * sin(2 * .pi * 880 * t)) * env
        let guitar = Float(0.18 * sin(2 * .pi * 1500 * t + 0.3 * sin(2 * .pi * 3 * t)))
        common = 0.97 * common + 0.03 * rng.next()
        pinkL = 0.9 * pinkL + 0.1 * rng.next()
        pinkR = 0.9 * pinkR + 0.1 * rng.next()
        l[i] = vocal + guitar * 0.9 + 0.5 * common + 0.25 * pinkL
        r[i] = vocal + guitar * 0.2 + 0.5 * common + 0.25 * pinkR
    }
    return [l, r]
}

/// A 16-channel bed (loopback order). `active` picks which channels carry signal.
func bed(_ seconds: Double, active: [Int], seed: UInt64 = 7) -> [[Float]] {
    let n = Int(seconds * sampleRate)
    var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: 16)
    let st = stereo(seconds, seed: seed)
    var rng = Rng(s: seed &+ 99)
    for ch in active {
        var state: Float = 0
        let f = 200.0 + 170.0 * Double(ch)
        for i in 0..<n {
            state = 0.8 * state + 0.2 * rng.next()
            let tone = Float(0.12 * sin(2 * .pi * f * Double(i) / sampleRate))
            switch ch {
            case 0: out[ch][i] = st[0][i] * 0.8
            case 1: out[ch][i] = st[1][i] * 0.8
            case 3: out[ch][i] = Float(0.3 * sin(2 * .pi * 45 * Double(i) / sampleRate)) // LFE
            default: out[ch][i] = 0.18 * state + tone
            }
        }
    }
    return out
}

/// Equivalence runs at a level where neither limiter acts (see "loud" below for when it does).
func quiet(_ x: [[Float]], _ g: Float = 0.3) -> [[Float]] { x.map { $0.map { $0 * g } } }

func concat(_ parts: [[[Float]]], channels: Int) -> [[Float]] {
    (0..<channels).map { ch in parts.flatMap { p in ch < p.count ? p[ch] : [Float](repeating: 0, count: p[0].count) } }
}

// MARK: - Runners

typealias Runner = (_ input: [[Float]]) -> (l: [Float], r: [Float], seconds: Double)

func run(inputs: [UnsafeMutablePointer<Float>], process: (Int, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void,
         input: [[Float]]) -> (l: [Float], r: [Float], seconds: Double) {
    let frames = input[0].count
    var outL = [Float](repeating: 0, count: frames), outR = outL
    let tl = UnsafeMutablePointer<Float>.allocate(capacity: block), tr = UnsafeMutablePointer<Float>.allocate(capacity: block)
    defer { tl.deallocate(); tr.deallocate() }
    var elapsed = 0.0
    var pos = 0
    while pos < frames {
        let count = min(block, frames - pos)
        for (ch, p) in inputs.enumerated() {
            input[min(ch, input.count - 1)].withUnsafeBufferPointer { src in
                p.update(from: src.baseAddress!.advanced(by: pos), count: count)
            }
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        process(count, tl, tr)
        elapsed += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        for i in 0..<count { outL[pos + i] = tl[i]; outR[pos + i] = tr[i] }
        pos += count
    }
    return (outL, outR, elapsed)
}

func legacySettings(_ s: SferaCore.LiveSettings) -> LegacyCore.LiveSettings {
    var l = LegacyCore.LiveSettings()
    l.spatial = s.spatial
    l.upmix = LegacyCore.UpmixSettings(centerExtraction: s.upmix.centerExtraction, width: s.upmix.width,
                                       surround: s.upmix.surround, height: s.upmix.height, generateLFE: s.upmix.generateLFE)
    l.renderMode = LegacyCore.DistanceModel(rawValue: s.renderMode.rawValue)!
    l.outputGainDB = s.outputGainDB
    return l
}

func legacy(channels: Int, settings: SferaCore.LiveSettings, change: (frame: Int, settings: SferaCore.LiveSettings)? = nil) -> Runner {
    { input in
        let ls = legacySettings(settings)
        let p: any LiveProcessor = channels > 2
            ? AdaptiveSpatializer(sampleRate: sampleRate, inputLayout: SpatialDiagnostics.loopbackLayout, settings: ls, maxFrames: block)
            : LiveSpatializer(sampleRate: sampleRate, inputLayout: .stereo, settings: ls, maxFrames: block)
        var done = 0
        return run(inputs: p.inputs, process: { n, l, r in
            if let change, done <= change.frame, done + n > change.frame { p.update(legacySettings(change.settings)) }
            p.process(frames: n, outL: l, outR: r)
            done += n
        }, input: input)
    }
}

/// Sfera 0.9's surround chain alone (no adaptive crossfade), delayed to the adaptive latency.
func legacyBedOnly(settings: SferaCore.LiveSettings) -> Runner {
    { input in
        let p = LiveSpatializer(sampleRate: sampleRate, inputLayout: SpatialDiagnostics.loopbackLayout,
                                settings: legacySettings(settings), maxFrames: block)
        var out = run(inputs: p.inputs, process: { n, l, r in p.process(frames: n, outL: l, outR: r) }, input: input)
        let d = 2048
        out.l = [Float](repeating: 0, count: d) + out.l.dropLast(d)
        out.r = [Float](repeating: 0, count: d) + out.r.dropLast(d)
        return out
    }
}

func rewrite(channels: Int, settings: SferaCore.LiveSettings, change: (frame: Int, settings: SferaCore.LiveSettings)? = nil) -> Runner {
    { input in
        let p = Spatializer(sampleRate: sampleRate, channels: channels, settings: settings, maxFrames: block)
        var done = 0
        return run(inputs: p.inputs, process: { n, l, r in
            if let change, done <= change.frame, done + n > change.frame { p.update(change.settings) }
            p.process(frames: n, outL: l, outR: r)
            done += n
        }, input: input)
    }
}

// MARK: - Metrics

func db(_ x: Double) -> Double { x > 0 ? 10 * log10(x) : -400 }

/// Difference energy relative to signal energy over `range` (dB), and worst sample error (dBFS).
func compare(_ a: (l: [Float], r: [Float], seconds: Double), _ b: (l: [Float], r: [Float], seconds: Double), _ range: Range<Int>) -> (rel: Double, peak: Double) {
    var sig = 0.0, err = 0.0, worst: Float = 0
    for i in range {
        for (x, y) in [(a.l[i], b.l[i]), (a.r[i], b.r[i])] {
            sig += Double(x) * Double(x)
            let d = x - y
            err += Double(d) * Double(d)
            worst = max(worst, abs(d))
        }
    }
    return (db(err / max(sig, 1e-30)), worst > 0 ? 20 * log10(Double(worst)) : -400)
}

func seconds(_ a: Double, _ b: Double) -> Range<Int> { Int(a * sampleRate)..<Int(b * sampleRate) }

var failures: [String] = []
func check(_ name: String, _ result: (rel: Double, peak: Double), limit: Double) {
    let ok = result.rel <= limit
    print(String(format: "  %@ %-46@ diff %7.1f dB re signal, worst sample %7.1f dBFS", ok ? "✓" : "✗", name as NSString, result.rel, result.peak))
    if !ok { failures.append(name) }
}

if CommandLine.arguments.contains("--profile") {
    // Spin the stereo chain for `sample`/Instruments.
    var st = SferaCore.LiveSettings()
    if CommandLine.arguments.contains("--dry") { st.renderMode = .off }
    let input = stereo(4)
    let end = Date().addingTimeInterval(8)
    while Date() < end { _ = rewrite(channels: 2, settings: st)(input) }
    exit(0)
}

if CommandLine.arguments.contains("--channels") {
    for mode in [SferaCore.RoomMode.off, .mid] {
        var st = SferaCore.LiveSettings(); st.renderMode = mode
        for ch in 0..<16 {
            let x = quiet(bed(3, active: [ch]), 0.1)
            let a = legacyBedOnly(settings: st)(x), b = rewrite(channels: 16, settings: st)(x)
            let r = compare(a, b, seconds(1, 3))
            print(mode.label, ch, String(format: "%.1f", r.rel))
        }
    }
    exit(0)
}

// MARK: - Equivalence

print("Output equivalence (rewrite vs Sfera 0.9, 512-frame blocks, 48 kHz)")
let music = quiet(stereo(8))
for mode in SferaCore.RoomMode.allCases {
    var s = SferaCore.LiveSettings(); s.renderMode = mode
    let a = legacy(channels: 2, settings: s)(music), b = rewrite(channels: 2, settings: s)(music)
    check("stereo upmix, room \(mode.label)", compare(a, b, seconds(0.5, 8)), limit: -100)
}
do {
    var s = SferaCore.LiveSettings()
    s.upmix = UpmixSettings(); s.upmix.centerExtraction = 1; s.upmix.width = 1; s.upmix.surround = 0.3; s.upmix.height = 1
    s.upmix.generateLFE = true; s.outputGainDB = 4
    let a = legacy(channels: 2, settings: s)(music), b = rewrite(channels: 2, settings: s)(music)
    check("stereo, extreme upmix + LFE + 4 dB gain", compare(a, b, seconds(0.5, 8)), limit: -100)

    var off = SferaCore.LiveSettings(); off.spatial = false
    let c = legacy(channels: 2, settings: off)(music), d = rewrite(channels: 2, settings: off)(music)
    check("stereo, Original (A/B)", compare(c, d, seconds(0.5, 8)), limit: -100)

    // Toggle Spatial → Original mid-stream.
    let on = SferaCore.LiveSettings()
    let e = legacy(channels: 2, settings: on, change: (Int(3 * sampleRate), off))(music)
    let f = rewrite(channels: 2, settings: on, change: (Int(3 * sampleRate), off))(music)
    check("stereo, Spatial → Original switch", compare(e, f, seconds(0.5, 8)), limit: -100)
}

let atmosChannels = Array(0..<16)
let atmos = quiet(bed(8, active: atmosChannels), 0.05)
let film = quiet(bed(8, active: [0, 1, 2, 3, 4, 5]), 0.1)
let stereoOnLoopback = quiet(concat([stereo(8)], channels: 16))
for mode in [SferaCore.RoomMode.mid, .far, .off] {
    var s = SferaCore.LiveSettings(); s.renderMode = mode
    let a = legacy(channels: 16, settings: s)(atmos), b = rewrite(channels: 16, settings: s)(atmos)
    check("BlackHole 9.1.6 Atmos bed, room \(mode.label)", compare(a, b, seconds(0.5, 8)), limit: -80)
    let c = legacyBedOnly(settings: s)(atmos)
    check("  same, vs 0.9's surround chain alone", compare(c, b, seconds(1, 8)), limit: -85)
    check("  (0.9 adaptive vs 0.9 surround chain alone)", compare(c, a, seconds(1, 8)), limit: 0)
}
do {
    let s = SferaCore.LiveSettings()
    let a = legacy(channels: 16, settings: s)(film), b = rewrite(channels: 16, settings: s)(film)
    check("BlackHole 5.1 film", compare(a, b, seconds(0.5, 8)), limit: -80)
    check("  same, vs 0.9's surround chain alone", compare(legacyBedOnly(settings: s)(film), b, seconds(1, 8)), limit: -85)
    let c = legacy(channels: 16, settings: s)(stereoOnLoopback), d = rewrite(channels: 16, settings: s)(stereoOnLoopback)
    check("BlackHole stereo song (upmixed)", compare(c, d, seconds(0.5, 8)), limit: -100)
    var off = s; off.spatial = false
    let e = legacyBedOnly(settings: off)(atmos), f = rewrite(channels: 16, settings: off)(atmos)
    check("BlackHole Atmos, Original (fold-down)", compare(e, f, seconds(1, 8)), limit: -100)

    // Stereo 4 s → Atmos 4 s → stereo 7 s: switches at 4 s and (after the 3 s hold) ~11 s.
    let seq = concat([quiet(stereo(4, seed: 3)), atmos.map { Array($0.prefix(Int(4 * sampleRate))) }, quiet(stereo(7, seed: 5))], channels: 16)
    let g = legacy(channels: 16, settings: s)(seq), h = rewrite(channels: 16, settings: s)(seq)
    // The room tail (RT60 0.42 s) carries a switch for ~1.5 s, so steady-state windows start after that.
    check("switching: stereo segment", compare(g, h, seconds(0.5, 4)), limit: -100)
    check("switching: Atmos segment (steady)", compare(g, h, seconds(5.5, 8)), limit: -80)
    check("switching: held surround", compare(g, h, seconds(8, 10.9)), limit: -80)
    check("switching: stereo again (steady)", compare(g, h, seconds(12.5, 15)), limit: -100)
    check("switching: whole programme incl. both fades", compare(g, h, seconds(0.5, 15)), limit: -35)
    var worst = (t: 0.0, rel: -400.0)
    for k in 0..<57 {
        let r = compare(g, h, seconds(0.5 + Double(k) * 0.25, 0.75 + Double(k) * 0.25)).rel
        if r > worst.rel { worst = (0.5 + Double(k) * 0.25, r) }
    }
    print(String(format: "    largest difference: %.1f dB re signal in the 250 ms from %.2f s", worst.rel, worst.t))
    if CommandLine.arguments.contains("--timeline") {
        for k in 0..<57 {
            let t = 0.5 + Double(k) * 0.25
            print(String(format: "      %5.2f s  %7.1f dB", t, compare(g, h, seconds(t, t + 0.25)).rel))
        }
    }
}

do {
    // Loud material: the limiter works. 0.9's release never quite returns to unity
    // (it stalls 0.002 dB short), the rewrite's does; that is the whole difference.
    let s = SferaCore.LiveSettings()
    let loud = stereo(8)
    let a = legacy(channels: 2, settings: s)(loud), b = rewrite(channels: 2, settings: s)(loud)
    check("loud stereo, limiter active", compare(a, b, seconds(0.5, 8)), limit: -65)
    let la = bed(8, active: atmosChannels)
    let c = legacyBedOnly(settings: s)(la), d = rewrite(channels: 16, settings: s)(la)
    check("loud Atmos, limiter active", compare(c, d, seconds(0.5, 8)), limit: -65)
}

// MARK: - CPU

print("\nCPU per second of audio (single core, M-series, 512-frame blocks)")
func cpu(_ name: String, legacy: Runner, rewrite: Runner, input: [[Float]]) {
    _ = legacy(input); _ = rewrite(input)                          // warm caches
    let a = (0..<3).map { _ in legacy(input).seconds }.min()!
    let b = (0..<3).map { _ in rewrite(input).seconds }.min()!
    let dur = Double(input[0].count) / sampleRate
    print(String(format: "  %-34@ 0.9: %5.2f%%   rewrite: %5.2f%%   (%4.1f× less)",
                 name as NSString, 100 * a / dur, 100 * b / dur, a / max(b, 1e-9)))
}
let s = SferaCore.LiveSettings()
let long = 20.0
var dry = s; dry.renderMode = .off
cpu("  (profile: stereo, Dry room)", legacy: legacy(channels: 2, settings: dry), rewrite: rewrite(channels: 2, settings: dry), input: stereo(long))
cpu("Tap / stereo source", legacy: legacy(channels: 2, settings: s), rewrite: rewrite(channels: 2, settings: s), input: stereo(long))
cpu("BlackHole, stereo song", legacy: legacy(channels: 16, settings: s), rewrite: rewrite(channels: 16, settings: s),
    input: concat([stereo(long)], channels: 16))
cpu("BlackHole, 5.1 film", legacy: legacy(channels: 16, settings: s), rewrite: rewrite(channels: 16, settings: s),
    input: bed(long, active: [0, 1, 2, 3, 4, 5]))
cpu("BlackHole, 9.1.6 Atmos", legacy: legacy(channels: 16, settings: s), rewrite: rewrite(channels: 16, settings: s),
    input: bed(long, active: atmosChannels))
cpu("BlackHole, nothing playing", legacy: legacy(channels: 16, settings: s), rewrite: rewrite(channels: 16, settings: s),
    input: [[Float]](repeating: [Float](repeating: 0, count: Int(long * sampleRate)), count: 16))

if failures.isEmpty {
    print("\n✓ equivalent")
} else {
    print("\n✗ differs: \(failures.joined(separator: ", "))")
    exit(1)
}
