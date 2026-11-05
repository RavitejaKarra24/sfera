import Foundation
import SferaCore

// Bench for the engine in the working tree (SferaCore).
//
// 1. Classic gate: SferaCore must reproduce Sfera 1.0 as frozen in git (ClassicCore) for
//    every room mode, including Far, at 44.1/48/96 kHz and irregular block sizes. A new
//    renderer may be added next to it; the Classic sound may not drift.
// 2. Refined renderer: cue geometry, upmix level, surround onsets, LFE balance, limiter
//    recovery; both renderers: room changes without clicks or stale room sound.
// 3. Limiter: it must actually limit loud material to the ceiling (and Classic's release
//    stall is reported as a known defect).
// 4. Sfera 0.9 equivalence (historical report, see docs/VALIDATION.md).
// 5. CPU per second of audio.
//
// Every comparison fails on non-finite output. Exit status 1 on any failure.
//
// Flags: --classic (gate only), --refined (gate + refined/transition checks), --no-cpu, --channels (per-channel 0.9 report),
//        --timeline (250 ms difference timeline of the 0.9 switching test), --profile [--dry].
//
// Two float artefacts of 0.9 are fixed in 1.0 and show up as small differences against 0.9:
// - 0.9's content crossfade `w += (1 − w)·c` stalls at 1 − 7·10⁻⁵, so its surround output
//   always carried the stereo upmix at −83 dB. Surround is therefore also compared with
//   0.9's surround chain on its own, which 1.0 matches.
// - 0.9's limiter release stalls 0.002 dB short of unity after the first peak it catches.
// Surround material also differs by ~−88 dB on the LFE alone: the 80 Hz low-pass sits close
// to DC, where single-precision rounding order shifts its phase by ~0.006 samples.

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let atmosChannels = Array(0..<16)

if args.contains("--profile") {
    // Spin the stereo chain for `sample`/Instruments.
    var st = LiveSettings()
    if args.contains("--dry") { st.renderMode = .off }
    let input = stereo(4)
    let end = Date().addingTimeInterval(8)
    while Date() < end { _ = rewrite(channels: 2, settings: st)(input) }
    exit(0)
}

/// Stereo loud enough to drive the limiter (peaks ≈ +2 dBFS before limiting at Far).
func loudStereo(_ seconds: Double, rate: Double = 48000) -> [[Float]] {
    stereo(seconds, rate: rate).map { $0.map { $0 * 2 } }
}

func settings(_ mode: RoomMode, spatial: Bool = true) -> LiveSettings {
    var s = LiveSettings(); s.renderMode = mode; s.spatial = spatial
    return s
}

// MARK: - 1. Classic gate

/// Classic must stay within ULP-level noise of the frozen engine (in practice bit-identical).
let classicLimit = -140.0

func classicSuite(rate: Double, blocks: Blocks, full: Bool) {
    print("\nClassic gate at \(Int(rate)) Hz, \(blocks.name)")
    let len = full ? 8.0 : 6.0
    let music = quiet(stereo(len, rate: rate))
    let atmos = quiet(bed(len, active: atmosChannels, rate: rate), 0.05)
    func gate(_ name: String, channels: Int, _ s: LiveSettings, _ input: [[Float]], change: Change? = nil) {
        let a = classic(channels: channels, settings: s, rate: rate, blocks: blocks, change: change)(input)
        let b = rewrite(channels: channels, settings: s, rate: rate, blocks: blocks, change: change)(input)
        check(name, compare(a, b, 0..<input[0].count), limit: classicLimit)
    }
    let modes: [RoomMode] = full ? RoomMode.allCases : [.far, .off]
    for mode in modes {
        gate("stereo upmix, room \(mode.label)", channels: 2, settings(mode), music)
        gate("9.1.6 Atmos bed, room \(mode.label)", channels: 16, settings(mode), atmos)
    }
    gate("stereo, Original (A/B)", channels: 2, settings(.far, spatial: false), music)
    gate("stereo on 16 ch loopback, Far", channels: 16, settings(.far), concat([music], channels: 16))
    if full {
        var x = settings(.far)
        x.upmix.centerExtraction = 1; x.upmix.width = 1; x.upmix.surround = 0.3; x.upmix.height = 1
        x.upmix.generateLFE = true; x.outputGainDB = 4
        gate("stereo, extreme upmix + LFE + 4 dB, Far", channels: 2, x, music)
        gate("5.1 film, Far", channels: 16, settings(.far), quiet(bed(len, active: [0, 1, 2, 3, 4, 5], rate: rate), 0.1))
        gate("Atmos, Original (fold-down)", channels: 16, settings(.far, spatial: false), atmos)
        gate("stereo, Far → Original mid-stream", channels: 2, settings(.far), music,
             change: (Int(3 * rate), settings(.far, spatial: false)))
    }
    // Stereo → Atmos → stereo: both content switches and the 3 s hold.
    let seq = concat([quiet(stereo(4, seed: 3, rate: rate)), atmos.map { Array($0.prefix(Int(4 * rate))) },
                      quiet(stereo(7, seed: 5, rate: rate))], channels: 16)
    gate("stereo → Atmos → stereo switching, Far", channels: 16, settings(.far), seq)
    // Loud: the limiter is working.
    gate("loud stereo (limiting), Far", channels: 2, settings(.far), loudStereo(len, rate: rate))
    gate("loud Atmos (limiting), Far", channels: 16, settings(.far), bed(len, active: atmosChannels, rate: rate))
}

classicSuite(rate: 48000, blocks: .fixed(512), full: true)
classicSuite(rate: 44100, blocks: .irregular(max: 1024), full: false)
classicSuite(rate: 96000, blocks: .irregular(max: 256, seed: 7), full: false)
classicSuite(rate: 48000, blocks: .fixed(64), full: false)

func finish() -> Never {
    if !knownIssues.isEmpty { print("\n⚠ known defects (not failures): \(knownIssues.joined(separator: ", "))") }
    if failures.isEmpty {
        print("\n✓ all checks passed")
        exit(0)
    }
    print("\n✗ failed: \(failures.joined(separator: ", "))")
    exit(1)
}

if args.contains("--classic") { finish() }

refinedSuite()
transitionSuite()
if args.contains("--refined") { finish() }

// MARK: - 3. Limiter (current engine on its own)

print("\nLimiter (current engine, Classic, Far, 48 kHz)")
do {
    let ceilingDB = -0.3, thresholdDB = -1.5
    for (name, channels, input) in [("loud stereo", 2, loudStereo(8)), ("loud Atmos", 16, bed(8, active: atmosChannels))] {
        let out = rewrite(channels: channels, settings: settings(.far))(input)
        let p = peakDB(out)
        expect("\(name): output peak ≤ −0.3 dBFS ceiling", p <= ceilingDB + 1e-4, String(format: "peak %.2f dBFS", p))
        expect("\(name): limiter engaged (peak ≥ −1.6 dBFS)", p >= thresholdDB - 0.1, String(format: "peak %.2f dBFS", p))
    }
    // Recovery: after a heavily limited burst, quiet material must come out exactly as if the
    // burst had never happened (gain back at unity, room and upmix state flushed).
    let tail = quiet(stereo(4, seed: 9))
    let burst = stereo(2, seed: 3).map { $0.map { $0 * 3 } }
    let after = rewrite(channels: 2, settings: settings(.far))(concat([burst, tail], channels: 2))
    let clean = rewrite(channels: 2, settings: settings(.far))(concat([silence(2, channels: 2), tail], channels: 2))
    // Known defect (Phase 1): the release recomputes its distance from the rounded gain
    // every sample, so it stalls at 1 − 2.3·10⁻⁴ (−0.002 dB) — Classic behaviour.
    knownIssue("recovery: quiet after a limited burst", compare(clean, after, seconds(4.5, 6)), limit: -100,
               note: "release stalls at −0.002 dB")
}

// MARK: - 4. Sfera 0.9 equivalence

if args.contains("--channels") {
    // Each bed channel on its own. L-only and R-only are stereo content (upmixed), so they
    // are compared with 0.9's adaptive chain; every other channel selects the bed.
    print("\nPer-channel 0.9 equivalence (16 ch loopback, 48 kHz, 512-frame blocks)")
    for mode in [RoomMode.off, .mid, .far] {
        for ch in 0..<16 {
            let x = quiet(bed(3, active: [ch]), 0.1)
            let st = settings(mode)
            let reference = ch < 2 ? legacy(channels: 16, settings: st)(x) : legacyBedOnly(settings: st)(x)
            let b = rewrite(channels: 16, settings: st)(x)
            check("\(mode.label), channel \(ch) alone", compare(reference, b, seconds(1, 3)), limit: -80)
        }
    }
    finish()
}

print("\nOutput equivalence (current engine vs Sfera 0.9, 512-frame blocks, 48 kHz)")
let music = quiet(stereo(8))
for mode in RoomMode.allCases {
    let s = settings(mode)
    let a = legacy(channels: 2, settings: s)(music), b = rewrite(channels: 2, settings: s)(music)
    check("stereo upmix, room \(mode.label)", compare(a, b, seconds(0.5, 8)), limit: -100)
}
do {
    var s = LiveSettings()
    s.upmix = UpmixSettings(); s.upmix.centerExtraction = 1; s.upmix.width = 1; s.upmix.surround = 0.3; s.upmix.height = 1
    s.upmix.generateLFE = true; s.outputGainDB = 4
    let a = legacy(channels: 2, settings: s)(music), b = rewrite(channels: 2, settings: s)(music)
    check("stereo, extreme upmix + LFE + 4 dB gain", compare(a, b, seconds(0.5, 8)), limit: -100)

    var off = LiveSettings(); off.spatial = false
    let c = legacy(channels: 2, settings: off)(music), d = rewrite(channels: 2, settings: off)(music)
    check("stereo, Original (A/B)", compare(c, d, seconds(0.5, 8)), limit: -100)

    // Toggle Spatial → Original mid-stream.
    let on = LiveSettings()
    let e = legacy(channels: 2, settings: on, change: (Int(3 * 48000.0), off))(music)
    let f = rewrite(channels: 2, settings: on, change: (Int(3 * 48000.0), off))(music)
    check("stereo, Spatial → Original switch", compare(e, f, seconds(0.5, 8)), limit: -100)
}

let atmos = quiet(bed(8, active: atmosChannels), 0.05)
let film = quiet(bed(8, active: [0, 1, 2, 3, 4, 5]), 0.1)
let stereoOnLoopback = quiet(concat([stereo(8)], channels: 16))
for mode in [RoomMode.mid, .far, .off] {
    let s = settings(mode)
    let a = legacy(channels: 16, settings: s)(atmos), b = rewrite(channels: 16, settings: s)(atmos)
    check("BlackHole 9.1.6 Atmos bed, room \(mode.label)", compare(a, b, seconds(0.5, 8)), limit: -80)
    let c = legacyBedOnly(settings: s)(atmos)
    check("  same, vs 0.9's surround chain alone", compare(c, b, seconds(1, 8)), limit: -85)
    check("  (0.9 adaptive vs 0.9 surround chain alone)", compare(c, a, seconds(1, 8)), limit: 0)
}
do {
    let s = LiveSettings()
    let a = legacy(channels: 16, settings: s)(film), b = rewrite(channels: 16, settings: s)(film)
    check("BlackHole 5.1 film", compare(a, b, seconds(0.5, 8)), limit: -80)
    check("  same, vs 0.9's surround chain alone", compare(legacyBedOnly(settings: s)(film), b, seconds(1, 8)), limit: -85)
    let c = legacy(channels: 16, settings: s)(stereoOnLoopback), d = rewrite(channels: 16, settings: s)(stereoOnLoopback)
    check("BlackHole stereo song (upmixed)", compare(c, d, seconds(0.5, 8)), limit: -100)
    var off = s; off.spatial = false
    let e = legacyBedOnly(settings: off)(atmos), f = rewrite(channels: 16, settings: off)(atmos)
    check("BlackHole Atmos, Original (fold-down)", compare(e, f, seconds(1, 8)), limit: -100)

    // Stereo 4 s → Atmos 4 s → stereo 7 s: switches at 4 s and (after the 3 s hold) ~11 s.
    let seq = concat([quiet(stereo(4, seed: 3)), atmos.map { Array($0.prefix(Int(4 * 48000.0))) }, quiet(stereo(7, seed: 5))], channels: 16)
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
    if args.contains("--timeline") {
        for k in 0..<57 {
            let t = 0.5 + Double(k) * 0.25
            print(String(format: "      %5.2f s  %7.1f dB", t, compare(g, h, seconds(t, t + 0.25)).rel))
        }
    }
}

do {
    // Loud material: the limiter works (both engines' releases stall 0.002 dB short of unity).
    let s = LiveSettings()
    let loud = loudStereo(8)
    let a = legacy(channels: 2, settings: s)(loud), b = rewrite(channels: 2, settings: s)(loud)
    check("loud stereo, limiter active", compare(a, b, seconds(0.5, 8)), limit: -65)
    let la = bed(8, active: atmosChannels)
    let c = legacyBedOnly(settings: s)(la), d = rewrite(channels: 16, settings: s)(la)
    check("loud Atmos, limiter active", compare(c, d, seconds(0.5, 8)), limit: -65)
}

// MARK: - 5. CPU

if !args.contains("--no-cpu") {
    print("\nCPU per second of audio (single core, M-series, 512-frame blocks)")
    func cpu(_ name: String, legacy: Runner, rewrite: Runner, input: [[Float]]) {
        _ = legacy(input); _ = rewrite(input)                          // warm caches
        let a = (0..<3).map { _ in legacy(input).seconds }.min()!
        let b = (0..<3).map { _ in rewrite(input).seconds }.min()!
        let dur = Double(input[0].count) / 48000
        print(String(format: "  %-34@ 0.9: %5.2f%%   current: %5.2f%%   (%4.1f× less)",
                     name as NSString, 100 * a / dur, 100 * b / dur, a / max(b, 1e-9)))
    }
    let s = LiveSettings()
    let long = 20.0
    let dry = settings(.off)
    cpu("  (profile: stereo, Dry room)", legacy: legacy(channels: 2, settings: dry), rewrite: rewrite(channels: 2, settings: dry), input: stereo(long))
    cpu("Tap / stereo source", legacy: legacy(channels: 2, settings: s), rewrite: rewrite(channels: 2, settings: s), input: stereo(long))
    cpu("BlackHole, stereo song", legacy: legacy(channels: 16, settings: s), rewrite: rewrite(channels: 16, settings: s),
        input: concat([stereo(long)], channels: 16))
    cpu("BlackHole, 5.1 film", legacy: legacy(channels: 16, settings: s), rewrite: rewrite(channels: 16, settings: s),
        input: bed(long, active: [0, 1, 2, 3, 4, 5]))
    cpu("BlackHole, 9.1.6 Atmos", legacy: legacy(channels: 16, settings: s), rewrite: rewrite(channels: 16, settings: s),
        input: bed(long, active: atmosChannels))
    cpu("BlackHole, nothing playing", legacy: legacy(channels: 16, settings: s), rewrite: rewrite(channels: 16, settings: s),
        input: silence(long, channels: 16))

    var refined = s; refined.renderer = .refined
    func cpuRefined(_ name: String, channels: Int, input: [[Float]]) {
        let a = rewrite(channels: channels, settings: s), b = rewrite(channels: channels, settings: refined)
        _ = a(input); _ = b(input)
        let ta = (0..<3).map { _ in a(input).seconds }.min()!, tb = (0..<3).map { _ in b(input).seconds }.min()!
        let dur = Double(input[0].count) / 48000
        print(String(format: "  %-34@ Classic: %5.2f%%   Refined: %5.2f%%", name as NSString, 100 * ta / dur, 100 * tb / dur))
    }
    cpuRefined("Tap / stereo source", channels: 2, input: stereo(long))
    cpuRefined("BlackHole, 9.1.6 Atmos", channels: 16, input: bed(long, active: atmosChannels))
}

finish()
