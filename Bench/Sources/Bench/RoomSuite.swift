import Foundation
import SferaCore

// Phase 2: the Refined room. Classic's room (frozen) is the reference for level; the checks
// are about what the new room adds: source-dependent early reflections, overhead and floor
// reflections with an elevation cue, a frequency-dependent decay, bass in the room, and
// clean switching between room sizes.

private let rate = 48000.0

private func energy(_ x: [[Float]], _ range: Range<Int>) -> Double {
    var e = 0.0
    for ch in x { for i in range where i < ch.count { e += Double(ch[i]) * Double(ch[i]) } }
    return e
}

/// Zero-lag normalised correlation of two binaural responses over `range`.
private func correlation(_ a: [[Float]], _ b: [[Float]], _ range: Range<Int>) -> Double {
    var ab = 0.0, aa = 0.0, bb = 0.0
    for ear in 0..<2 {
        for i in range {
            let x = Double(a[ear][i]), y = Double(b[ear][i])
            ab += x * y; aa += x * x; bb += y * y
        }
    }
    return ab / max((aa * bb).squareRoot(), 1e-30)
}

func roomSuite() {
    print("\nRefined room (48 kHz, Far, default room settings)")
    let early = 0..<Int(0.05 * rate), late = Int(0.05 * rate)..<Int(2 * rate)
    let speakers: [Speaker] = [.l, .r, .c, .lss, .rss, .lrs, .rrs, .ltf, .rtr, .cts]

    // 1. Level: the same early and late energy as Classic's room, summed over the bed.
    var ce = 0.0, cl = 0.0, re = 0.0, rl = 0.0
    var cDirect = 0.0, rDirect = 0.0
    for s in speakers {
        let c = Diagnostics.roomResponse(speaker: s, renderer: .classic)
        let r = Diagnostics.roomResponse(speaker: s, renderer: .refined)
        ce += energy(c.room, early); cl += energy(c.room, late)
        re += energy(r.room, early); rl += energy(r.room, late)
        cDirect += energy(c.direct, 0..<Int(0.01 * rate)); rDirect += energy(r.direct, 0..<Int(0.01 * rate))
    }
    let earlyDiff = db(re / ce), lateDiff = db(rl / cl)
    print(String(format: "    room energy re Classic: 0–50 ms %+.2f dB, 50 ms+ %+.2f dB; direct path %+.2f dB (equal-distance heights)",
                 earlyDiff, lateDiff, db(rDirect / cDirect)))
    expect("level: room's first 50 ms match Classic", abs(earlyDiff) <= 1, String(format: "%+.2f dB", earlyDiff))
    expect("level: room after 50 ms matches Classic", abs(lateDiff) <= 1, String(format: "%+.2f dB", lateDiff))

    let bands = [125.0, 500, 1000, 2000, 4000, 8000]
    let rc = Diagnostics.decayTimes(renderer: .classic, bands: bands)
    let rr = Diagnostics.decayTimes(renderer: .refined, bands: bands)
    print("    T30 (s) at " + bands.map { String(format: "%.0f", $0) }.joined(separator: "/") + " Hz: classic "
          + rc.map { String(format: "%.2f", $0) }.joined(separator: " ") + " · refined " + rr.map { String(format: "%.2f", $0) }.joined(separator: " "))
    func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol * b }
    for (size, d) in [(RoomSize.medium, 0.45), (.small, 0.45), (.medium, 0.8), (.large, 0.8)] {
        var st = RoomSettings(); st.size = size; st.decay = d
        let t = d == 0.45 && size == .medium ? rr : Diagnostics.decayTimes(renderer: .refined, room: st, bands: bands)
        let ok = near(t[2], d, 0.12) && t[0] >= 1.1 * t[2] && t[5] <= 0.8 * t[2]
        expect("decay: \(size.label) \(d) s", ok, String(format: "1 kHz %.2f s, 125 Hz ×%.2f, 8 kHz ×%.2f", t[2], t[0] / t[2], t[5] / t[2]))
    }

    // 2. Reflections belong to the source: a side and a rear speaker on the same side used to
    //    excite the same pattern (Classic pans both into one lateral bus).
    let firstReflections = 0..<Int(0.03 * rate)
    func earlyOnly(_ s: Speaker, _ r: Renderer) -> [[Float]] {
        r == .classic ? Diagnostics.roomResponse(speaker: s, renderer: r, seconds: 0.1).room
                      : Diagnostics.roomResponse(speaker: s, renderer: r, part: .early, seconds: 0.1).room
    }
    let pairs: [(Speaker, Speaker)] = [(.lss, .lrs), (.l, .lss), (.c, .cts)]
    var line = "    early-reflection similarity (0–30 ms, 1 = same pattern):"
    var worst = 0.0
    for (a, b) in pairs {
        let c = correlation(earlyOnly(a, .classic), earlyOnly(b, .classic), firstReflections)
        let r = correlation(earlyOnly(a, .refined), earlyOnly(b, .refined), firstReflections)
        worst = max(worst, r)
        line += String(format: "  %@/%@ %.2f→%.2f", "\(a)".uppercased(), "\(b)".uppercased(), c, r)
    }
    print(line)
    expect("reflections differ by source direction", worst < 0.5, String(format: "largest similarity %.2f", worst))

    let c = earlyOnly(.c, .refined)
    check("C: left and right ear reflections identical", compare(Render(l: c[0], r: c[0], seconds: 0), Render(l: c[1], r: c[1], seconds: 0), 0..<c[0].count), limit: -100)
    let lrs = earlyOnly(.lrs, .refined), rrs = earlyOnly(.rrs, .refined)
    check("Lrs and Rrs reflections mirror", compare(Render(l: lrs[0], r: lrs[1], seconds: 0), Render(l: rrs[1], r: rrs[0], seconds: 0), 0..<lrs[0].count), limit: -100)

    var missing: [String] = []
    for s in Speaker.allCases where !s.isLFE {
        let taps = Diagnostics.refinedReflections(speaker: s)
        if !taps.contains(where: \.above) || !taps.contains(where: \.below) || taps.count != 12 { missing.append("\(s)") }
    }
    expect("every speaker: 6 reflections incl. ceiling and floor", missing.isEmpty, missing.isEmpty ? "15 speakers × 6 × 2 ears" : "missing: \(missing)")
    // The floor stays at ear height − 1.2 m, so compare the median reflection.
    let medianDelay = RoomSize.allCases.map { size in
        let d = Diagnostics.refinedReflections(speaker: .l, size: size).map(\.delay).sorted()
        return Double(d[d.count / 2]) / rate * 1000
    }
    expect("reflections later in a bigger room", medianDelay[0] < medianDelay[1] && medianDelay[1] < medianDelay[2],
           String(format: "L median: %.1f / %.1f / %.1f ms (Small/Medium/Large)", medianDelay[0], medianDelay[1], medianDelay[2]))

    // 3. Bass in the room: the tail only (reflections stay above 140 Hz so bass attacks
    //    don't smear). Classic's tail for reference, measured after 50 ms.
    let tailRange = Int(0.05 * rate)..<Int(2 * rate)
    func tailBass(_ x: [[Float]]) -> Double { Diagnostics.bandEnergy(x.map { Array($0[tailRange]) }, center: 63) }
    let classicBass = tailBass(Diagnostics.roomResponse(speaker: .c, renderer: .classic).room)
    var none = RoomSettings(); none.bass = 0
    var full = RoomSettings(); full.bass = 1
    let bass = [none, RoomSettings(), full].map {
        db(tailBass(Diagnostics.roomResponse(speaker: .c, renderer: .refined, room: $0, part: .late).room) / classicBass)
    }
    print(String(format: "    tail energy at 63 Hz re Classic: bass 0 %+.1f dB, 0.5 (default) %+.1f dB, 1 %+.1f dB", bass[0], bass[1], bass[2]))
    expect("bass in room: each step adds low end", bass[1] >= bass[0] + 6 && bass[2] >= bass[1] + 3,
           String(format: "%+.1f / %+.1f / %+.1f dB", bass[0], bass[1], bass[2]))

    // 4. Elevation cue.
    func g(_ el: Double, _ f: Double, _ r: Renderer) -> Double { Diagnostics.elevationGain(elevation: el, frequency: f, renderer: r) }
    print(String(format: "    elevation filter at 45° (dB, 7 / 8.2 / 10.1 kHz): classic %+.1f %+.1f %+.1f · refined %+.1f %+.1f %+.1f",
                 g(45, 7000, .classic), g(45, 8200, .classic), g(45, 10100, .classic), g(45, 7000, .refined), g(45, 8200, .refined), g(45, 10100, .refined)))
    let flat = [1000.0, 4000, 7000, 10000, 14000].map { abs(g(0, $0, .refined)) }.max()!
    expect("elevation: raised source gains 7 kHz, loses 10 kHz", g(45, 7000, .refined) >= 2.5 && g(45, 10100, .refined) <= -3,
           String(format: "%+.1f / %+.1f dB", g(45, 7000, .refined), g(45, 10100, .refined)))
    expect("elevation: ear plane untouched", flat < 0.01, String(format: "max %.3f dB", flat))
    expect("elevation: notch moves up with height", g(60, 10800, .refined) < g(30, 10800, .refined) && g(30, 9200, .refined) < g(60, 9200, .refined),
           String(format: "10.8 kHz: 30° %+.1f, 60° %+.1f dB", g(30, 10800, .refined), g(60, 10800, .refined)))

    // 5. Changing the room while playing.
    let n = Int(4 * rate), at = Int(2 * rate)
    let tone = (0..<n).map { Float(0.2 * sin(2 * .pi * 100 * Double($0) / rate)) }
    func farRefined(_ edit: (inout LiveSettings) -> Void = { _ in }) -> LiveSettings {
        var s = settings(.far); s.renderer = .refined; edit(&s); return s
    }
    func jumpRatio(_ out: Render) -> Double {
        func maxStep(_ r: Range<Int>) -> Float {
            var m: Float = 0
            for i in r { m = max(m, abs(out.l[i] - out.l[i - 1]), abs(out.r[i] - out.r[i - 1])) }
            return m
        }
        let steady = max(maxStep(seconds(1, 1.9)), maxStep(seconds(2.6, 3.5)))
        return Double(maxStep((at - 2048)..<(at + 6000)) / steady)
    }
    let edits: [(String, (inout LiveSettings) -> Void)] = [
        ("size Medium → Large", { $0.room.size = .large }),
        ("size Medium → Small", { $0.room.size = .small }),
        ("decay 0.45 → 1.2 s", { $0.room.decay = 1.2 }),
        ("early −12 dB, late +6 dB", { $0.room.early = -12; $0.room.late = 6 }),
        ("bass in room 0.5 → 1", { $0.room.bass = 1 }),
    ]
    for (name, edit) in edits {
        let ratio = jumpRatio(rewrite(channels: 2, settings: farRefined(), change: (at, farRefined(edit)))([tone, tone]))
        expect("change \(name) without a click", ratio < 1.25, String(format: "largest step ×%.2f of the tone's", ratio))
    }
    // A 5.1 bed (no upmixer, whose steering remembers the noise): noise, then a quiet tone.
    let active = [0, 1, 2, 4, 5]
    let noise = quiet(bed(2, active: active, seed: 33), 0.5)
    let quietTone = (0..<Int(2 * rate)).map { Float(0.05 * sin(2 * .pi * 300 * Double($0) / rate)) }
    let tones = (0..<16).map { active.contains($0) ? quietTone : [Float](repeating: 0, count: quietTone.count) }
    // Switch after the noise has left the 43 ms input delay, while its room is still ringing.
    let toLarge: [Change] = [(Int(2.15 * rate), farRefined { $0.room.size = .large })]
    let a = rewrite(channels: 16, settings: farRefined(), changes: toLarge)(concat([noise, tones], channels: 16))
    let b = rewrite(channels: 16, settings: farRefined(), changes: toLarge)(concat([silence(2, channels: 16), tones], channels: 16))
    let kept = rewrite(channels: 16, settings: farRefined())(concat([noise, tones], channels: 16))
    print(String(format: "    (without the change, the old room is still there at %.1f dB re signal)", compare(b, kept, seconds(2.4, 3.5)).rel))
    check("size change: old room doesn't carry over", compare(b, a, seconds(2.4, 3.5)), limit: -100)

    // 6. Other rates and block sizes: finite, limited, and the room really runs.
    for (r, blocks) in [(44100.0, Blocks.irregular(max: 1024)), (96000, .irregular(max: 256)), (192000, .fixed(4096))] {
        let inputs: [(String, Int, [[Float]])] = [("stereo", 2, loudStereo(3, rate: r)),
                                                  ("Atmos", 16, bed(3, active: Array(0..<16), rate: r).map { $0.map { $0 * 2 } })]
        for (name, channels, input) in inputs {
            for size in RoomSize.allCases {
                let out = rewrite(channels: channels, settings: farRefined { $0.room.size = size }, rate: r, blocks: blocks)(input)
                let p = peakDB(out)
                expect("\(Int(r / 1000)) kHz \(blocks.name), \(name), \(size.label)", allFinite(out) && p <= -0.3 && p > -20,
                       String(format: "peak %.2f dBFS", p))
            }
        }
    }
}
