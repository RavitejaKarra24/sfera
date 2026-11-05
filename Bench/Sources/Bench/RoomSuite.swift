import Foundation
import SferaCore

// The Refined room. Classic's room (frozen) is the reference for level and, in the openness
// suite, for how different the two ears are. The checks here are about what the new room
// adds: reflections scaled by room size, a frequency-dependent decay that doesn't swell, bass
// in the room, and clean switching between room sizes.

private let rate = 48000.0

private func energy(_ x: [[Float]], _ range: Range<Int>) -> Double {
    var e = 0.0
    for ch in x { for i in range where i < ch.count { e += Double(ch[i]) * Double(ch[i]) } }
    return e
}

func roomSuite() {
    print("\nRefined room (48 kHz, Far, default room settings)")
    let speakers: [Speaker] = [.l, .r, .c, .lss, .rss, .lrs, .rrs, .ltf, .rtr, .cts]

    // 1. Level, per size: the same energy as Classic's room in the first 80 ms and after it,
    //    summed over the bed.
    let first = 0..<Int(0.08 * rate), after = Int(0.08 * rate)..<Int(2 * rate)
    var ce = 0.0, cl = 0.0
    var classicIR: [Speaker: [[Float]]] = [:]
    for s in speakers {
        let c = Diagnostics.roomResponse(speaker: s, renderer: .classic).room
        classicIR[s] = c
        ce += energy(c, first); cl += energy(c, after)
    }
    for size in RoomSize.allCases {
        var st = RoomSettings(); st.size = size
        var re = 0.0, rl = 0.0
        for s in speakers {
            let r = Diagnostics.roomResponse(speaker: s, renderer: .refined, room: st).room
            re += energy(r, first); rl += energy(r, after)
        }
        let e = db(re / ce), l = db(rl / cl)
        expect("level: \(size.label) room matches Classic's (0–80 ms, 80 ms+)", abs(e) <= 1 && abs(l) <= 1, String(format: "%+.2f / %+.2f dB", e, l))
    }
    // No swell: the tail decays from its start, like Classic's, instead of building up for
    // 100 ms (the first version's tail sat 8–10 dB above Classic's at 150–200 ms).
    let cIR = classicIR[.c]!, rIR = Diagnostics.roomResponse(speaker: .c, renderer: .refined).room
    let cTot = energy(cIR, 0..<Int(2 * rate))
    func level(_ x: [[Float]], _ ms: Double) -> Double { db(energy(x, Int(ms / 1000 * rate)..<Int((ms + 20) / 1000 * rate)) / cTot) }
    let swell = [100.0, 150, 200].map { level(rIR, $0) - level(cIR, $0) }.max()!
    print("    C room energy per 20 ms (dB re Classic's total) at 100/150/200 ms: classic "
          + [100.0, 150, 200].map { String(format: "%.0f", level(cIR, $0)) }.joined(separator: " ")
          + " · refined " + [100.0, 150, 200].map { String(format: "%.0f", level(rIR, $0)) }.joined(separator: " "))
    expect("tail: no swell over Classic's (Medium, 100–200 ms)", swell <= 2, String(format: "at most %+.1f dB", swell))

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

    // 2. Reflections: Classic's pattern, scaled by size (Medium is Classic's timing), none
    //    sooner than 8 ms.
    let delays = RoomSize.allCases.map { Diagnostics.refinedReflectionDelays(size: $0) }
    print("    reflections (ms, Small/Medium/Large): " + delays.map { d in d.map { String(format: "%.1f", $0) }.joined(separator: " ") }.joined(separator: " · "))
    let classicDelays = [8.7, 10.3, 12.9, 16.4, 18.1, 22.6, 25.2, 29.8]
    let medium = zip(delays[1], classicDelays).map { abs($0 - $1) }.max()!
    expect("reflections: Medium at Classic's delays", medium < 0.03, String(format: "largest difference %.3f ms", medium))
    expect("reflections: none before 8 ms, later in a bigger room", delays[0].min()! >= 7.98 && delays[0].max()! < delays[1].max()! && delays[1].max()! < delays[2].max()!,
           String(format: "first %.1f / %.1f / %.1f ms, last %.1f / %.1f / %.1f ms", delays[0].min()!, delays[1].min()!, delays[2].min()!,
                  delays[0].max()!, delays[1].max()!, delays[2].max()!))

    // 3. Bass in the room: the tail only (reflections stay above 200 Hz so bass attacks
    //    don't smear). Classic's tail for reference, measured after 50 ms.
    let tailRange = Int(0.05 * rate)..<Int(2 * rate)
    func tailBass(_ x: [[Float]]) -> Double { Diagnostics.bandEnergy(x.map { Array($0[tailRange]) }, center: 63) }
    let classicBass = tailBass(Diagnostics.roomResponse(speaker: .c, renderer: .classic).room)
    var none = RoomSettings(); none.bass = 0
    var half = RoomSettings(); half.bass = 0.5
    var full = RoomSettings(); full.bass = 1
    let bass = [none, RoomSettings(), half, full].map {
        db(tailBass(Diagnostics.roomResponse(speaker: .c, renderer: .refined, room: $0, part: .late).room) / classicBass)
    }
    print(String(format: "    tail energy at 63 Hz re Classic: bass 0 %+.1f dB, 0.25 (default) %+.1f dB, 0.5 %+.1f dB, 1 %+.1f dB",
                 bass[0], bass[1], bass[2], bass[3]))
    expect("bass in room: each step adds low end", bass[1] >= bass[0] + 2 && bass[2] >= bass[1] + 2 && bass[3] >= bass[2] + 2,
           String(format: "%+.1f / %+.1f / %+.1f / %+.1f dB", bass[0], bass[1], bass[2], bass[3]))

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
        ("bass in room 0.25 → 1", { $0.room.bass = 1 }),
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
