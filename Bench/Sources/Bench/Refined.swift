import Foundation
import SferaCore

// Checks for the refined renderer (and for behaviour both renderers now share). Each one
// measures the defect it is about, so it fails if the fix regresses; Classic's value is
// printed alongside for comparison where it differs.

private let rate = 48000.0

private func settings(_ mode: RoomMode, _ renderer: Renderer) -> LiveSettings {
    var s = LiveSettings(); s.renderMode = mode; s.renderer = renderer
    return s
}

private func energy(_ a: Render, _ range: Range<Int>) -> Double {
    var e = 0.0
    for i in range { e += Double(a.l[i]) * Double(a.l[i]) + Double(a.r[i]) * Double(a.r[i]) }
    return e
}

private func ratioDB(_ a: Double, _ b: Double) -> Double { 10 * log10(max(a, 1e-30) / max(b, 1e-30)) }

/// Interaural lag (ms, positive = right ear later) of the first 4 ms after `start`:
/// cross-correlation peak within ±1.2 ms, refined by a parabola.
private func lagMS(_ a: Render, start: Int) -> Double {
    let n = Int(0.004 * rate), maxLag = Int(0.0012 * rate)
    func xc(_ k: Int) -> Double {
        var s = 0.0
        for i in start..<(start + n) where i + k >= 0 && i + k < a.r.count { s += Double(a.l[i]) * Double(a.r[i + k]) }
        return s
    }
    var best = 0, bestV = -Double.infinity
    for k in -maxLag...maxLag { let v = xc(k); if v > bestV { bestV = v; best = k } }
    let y0 = xc(best - 1), y1 = bestV, y2 = xc(best + 1)
    let d = y0 - 2 * y1 + y2
    let frac = d != 0 ? 0.5 * (y0 - y2) / d : 0
    return (Double(best) + frac) / rate * 1000
}

/// Output for a unit impulse on one bed channel (16-channel loopback), Far.
private func impulse(channel: Int, renderer: Renderer) -> (Render, Int) {
    let at = Int(0.5 * rate)
    var x = silence(1, channels: 16)
    x[channel][at] = 0.5
    let latency = Spatializer(sampleRate: rate, channels: 16, maxFrames: 512).latency
    return (rewrite(channels: 16, settings: settings(.far, renderer))(x), at + latency)
}

func refinedSuite() {
    print("\nRefined renderer (48 kHz, 512-frame blocks)")

    // 1. Direction cues: Refined keeps Classic's ITD, shadow and level (the physically
    //    correct, smaller rear and height ITDs collapsed the image on headphones).
    var worstLag = 0.0
    var lagLine = "    rendered interaural lag (ms, + = right ear later):"
    for (name, ch) in [("L", 0), ("C", 2), ("Lss", 4), ("Rss", 5), ("Lrs", 6), ("Rrs", 7), ("Ltf", 10), ("Cts", 12), ("Ltr", 14)] {
        let (c, sc) = impulse(channel: ch, renderer: .classic)
        let (r, sr) = impulse(channel: ch, renderer: .refined)
        guard allFinite(r) else { expect("rendered \(name)", false, "non-finite output"); continue }
        let a = lagMS(c, start: sc), b = lagMS(r, start: sr)
        worstLag = max(worstLag, abs(a - b))
        lagLine += String(format: "  %@ %.2f", name, b)
    }
    print(lagLine)
    expect("rendered: interaural lags equal Classic's", worstLag < 0.01, String(format: "largest difference %.3f ms", worstLag))
    let rearITD = Diagnostics.itd(azimuth: 135, elevation: 0) * 1000, sideITD = Diagnostics.itd(azimuth: 90, elevation: 0) * 1000
    expect("ITD: rear wider than side (Classic's width)", rearITD > sideITD, String(format: "135° %.3f ms, 90° %.3f ms", rearITD, sideITD))

    // 2. Upmix: both renderers share it (the level-preserving steering moved +8 points of a
    //    stereo mix into C). Its level for reference; the image is gated in the openness suite.
    do {
        let n = Int(3 * rate)
        var rng = Rng(s: 11)
        let src = (0..<n).map { _ in rng.next() * 0.3 }
        let silent = [Float](repeating: 0, count: n)
        let inputE = src.reduce(0.0) { $0 + Double($1) * Double($1) }
        func gain(_ l: [Float], _ r: [Float], _ e: Double) -> Double {
            let skip = Int(0.5 * rate)
            let total = Diagnostics.upmixEnergies(left: l, right: r, settings: UpmixSettings(), skip: skip).reduce(0) { $0 + $1.energy }
            return ratioDB(total, e * Double(n - skip - 2048) / Double(n))
        }
        print(String(format: "    upmix level vs input (dB): hard left %+.2f, centre %+.2f, half left %+.2f",
                     gain(src, silent, inputE), gain(src, src, 2 * inputE), gain(src, src.map { $0 * 0.5 }, inputE * 1.25)))
    }

    // 3. Native surround: a fresh rear event after silence vs the same event with the bed held.
    do {
        var rng = Rng(s: 5)
        let burst = (0..<Int(0.03 * rate)).map { _ in rng.next() * 0.2 }
        func seq(early: Bool) -> [[Float]] {
            var x = silence(1.6, channels: 16)
            if early { for (i, v) in burst.enumerated() { x[6][Int(0.2 * rate) + i] = v } }
            for (i, v) in burst.enumerated() { x[6][Int(1.0 * rate) + i] = v }
            return x
        }
        let latency = Spatializer(sampleRate: rate, channels: 16, maxFrames: 512).latency
        let window = (Int(1.0 * rate) + latency)..<(Int(1.0 * rate) + latency + burst.count)
        func onset(_ r: Renderer) -> Double {
            let fresh = rewrite(channels: 16, settings: settings(.far, r))(seq(early: false))
            let held = rewrite(channels: 16, settings: settings(.far, r))(seq(early: true))
            return ratioDB(energy(fresh, window), energy(held, window))
        }
        let c = onset(.classic), f = onset(.refined)
        expect("bed: new rear event at full level", abs(f) < 0.2, String(format: "first 30 ms %+.2f dB (classic %+.2f)", f, c))
    }

    // 4. LFE balance against the mains does not move with the room.
    do {
        func tone(_ ch: Int) -> [[Float]] {
            var x = silence(3, channels: 16)
            for i in 0..<x[ch].count { x[ch][i] = Float(0.1 * sin(2 * .pi * 45 * Double(i) / rate)) }
            return x
        }
        let lfe = tone(3), centre = tone(2)
        func balance(_ m: RoomMode, _ r: Renderer, bass: Double = 0) -> Double {
            var s = settings(m, r)
            s.room.bass = bass
            return ratioDB(energy(rewrite(channels: 16, settings: s)(lfe), seconds(1, 3)),
                           energy(rewrite(channels: 16, settings: s)(centre), seconds(1, 3)))
        }
        // The design: bass kept out of the room (Refined's room then high-passes like Classic's).
        let modes = RoomMode.allCases
        let ref = balance(.far, .classic)
        let refined = modes.map { balance($0, .refined) }, classic = modes.map { balance($0, .classic) }
        let withBass = modes.map { balance($0, .refined, bass: RoomSettings().bass) }
        let spread = refined.max()! - refined.min()!
        print("    LFE vs centre at 45 Hz (dB, Dry/Near/Mid/Far): classic " + classic.map { String(format: "%+.1f", $0) }.joined(separator: " ")
              + " · refined " + refined.map { String(format: "%+.1f", $0) }.joined(separator: " ")
              + " · with default bass in room " + withBass.map { String(format: "%+.1f", $0) }.joined(separator: " "))
        expect("LFE: same balance in every room mode", spread < 0.25, String(format: "spread %.2f dB", spread))
        expect("LFE: equal to Classic Far's balance", abs(refined.last! - ref) < 0.05, String(format: "%+.2f vs %+.2f dB", refined.last!, ref))
        let bassSpread = withBass.max()! - withBass.min()!
        expect("LFE: bass in room keeps it within 0.5 dB", bassSpread < 0.5, String(format: "spread %.2f dB", bassSpread))
    }

    // 5. Limiter returns to unity.
    do {
        // On a 5.1 bed, so the upmixer (whose steering keeps adapting after loud stereo) is
        // out of the picture; the stereo figure is printed for reference.
        let s = settings(.far, .refined)
        let active = [0, 1, 2, 4, 5]
        let bedTail = quiet(bed(4, active: active, seed: 9))
        let bedBurst = bed(2, active: active, seed: 3).map { $0.map { $0 * 3 } }
        let after = rewrite(channels: 16, settings: s)(concat([bedBurst, bedTail], channels: 16))
        let clean = rewrite(channels: 16, settings: s)(concat([silence(2, channels: 16), bedTail], channels: 16))
        // Against the same burst kept below the limiter: what's left is the Far path's float
        // rounding floor (Classic leaves the same without limiting), so the limiter adds nothing.
        let soft = rewrite(channels: 16, settings: s)(concat([bedBurst.map { $0.map { $0 / 6 } }, bedTail], channels: 16))
        let limited = compare(clean, after, seconds(4.5, 6)).rel, floor = compare(clean, soft, seconds(4.5, 6)).rel
        let classicLimited = compare(classic(channels: 16, settings: s)(concat([silence(2, channels: 16), bedTail], channels: 16)),
                                     classic(channels: 16, settings: s)(concat([bedBurst, bedTail], channels: 16)), seconds(4.5, 6)).rel
        expect("limiter: quiet after a limited burst is unaffected", limited <= floor + 3,
               String(format: "%.1f dB re signal; unlimited burst %.1f dB (Sfera 1.0: %.1f dB)", limited, floor, classicLimited))
        let tail = quiet(stereo(4, seed: 9))
        let burst = stereo(2, seed: 3).map { $0.map { $0 * 3 } }
        let sa = rewrite(channels: 2, settings: s)(concat([burst, tail], channels: 2))
        let sc = rewrite(channels: 2, settings: s)(concat([silence(2, channels: 2), tail], channels: 2))
        print(String(format: "    (stereo: %.1f dB re signal, the upmixer still adapting from the burst)", compare(sc, sa, seconds(4.5, 6)).rel))
    }
}

/// Both renderers: room changes neither click nor bring back old room sound.
func transitionSuite() {
    print("\nRoom and renderer changes (both renderers)")
    // Low tone: any step shows up as a sample-to-sample jump far above the tone's own slope.
    // The dip itself and the room building up again after it move the level smoothly, which
    // stays within ×1.25; a discontinuity (the old engine's ×2–×11) does not.
    let n = Int(4 * rate)
    let tone = (0..<n).map { Float(0.2 * sin(2 * .pi * 100 * Double($0) / rate)) }
    let input = [tone, tone]
    let at = Int(2 * rate)
    func jumpRatio(_ out: Render) -> Double {
        func maxStep(_ r: Range<Int>) -> Float {
            var m: Float = 0
            for i in r { m = max(m, abs(out.l[i] - out.l[i - 1]), abs(out.r[i] - out.r[i - 1])) }
            return m
        }
        // The steady slope before and after the change: the new mode may be louder.
        let steady = max(maxStep(seconds(1, 1.9)), maxStep(seconds(2.6, 3.5)))
        return Double(maxStep((at - 2048)..<(at + 6000)) / steady)
    }
    for (from, to) in [(RoomMode.far, RoomMode.mid), (.far, .off), (.off, .far)] {
        for r in Renderer.allCases {
            let ratio = jumpRatio(rewrite(channels: 2, settings: settings(from, r), change: (at, settings(to, r)))(input))
            expect("\(r.label): \(from.label) → \(to.label) without a click", ratio < 1.25, String(format: "largest step ×%.2f of the tone's", ratio))
        }
        let old = jumpRatio(classic(channels: 2, settings: settings(from, .classic), change: (at, settings(to, .classic)))(input))
        print(String(format: "    (Sfera 1.0 at d18a518: ×%.2f)", old))
    }
    for (from, to) in [(Renderer.classic, Renderer.refined), (.refined, .classic)] {
        let ratio = jumpRatio(rewrite(channels: 2, settings: settings(.far, from), change: (at, settings(.far, to)))(input))
        expect("Far: \(from.label) → \(to.label) without a click", ratio < 1.25, String(format: "largest step ×%.2f of the tone's", ratio))
    }

    // Far with loud noise → Dry with a quiet tone → Far: nothing of the noise comes back.
    // On a 5.1 bed, so only the room can remember the noise (the stereo upmixer's steering
    // keeps adapting for a while after loud material; that's reported separately).
    let noise = quiet(stereo(2, seed: 21), 0.5)
    let quietTone = (0..<Int(3 * rate)).map { Float(0.05 * sin(2 * .pi * 300 * Double($0) / rate)) }
    let withNoise = concat([noise, [quietTone, quietTone]], channels: 2)
    let withSilence = concat([silence(2, channels: 2), [quietTone, quietTone]], channels: 2)
    let active = [0, 1, 2, 4, 5]
    let tones = (0..<16).map { active.contains($0) ? quietTone : [Float](repeating: 0, count: quietTone.count) }
    let bedNoise = concat([quiet(bed(2, active: active, seed: 21), 0.5), tones], channels: 16)
    let bedSilence = concat([silence(2, channels: 16), tones], channels: 16)
    for r in Renderer.allCases {
        let changes: [Change] = [(Int(2 * rate), settings(.off, r)), (Int(4 * rate), settings(.far, r))]
        let a = rewrite(channels: 16, settings: settings(.far, r), changes: changes)(bedNoise)
        let b = rewrite(channels: 16, settings: settings(.far, r), changes: changes)(bedSilence)
        check("\(r.label): Far → Dry → Far, no stale room (5.1)", compare(b, a, seconds(4, 4.6)), limit: -100)
        let sa = rewrite(channels: 2, settings: settings(.far, r), changes: changes)(withNoise)
        let sb = rewrite(channels: 2, settings: settings(.far, r), changes: changes)(withSilence)
        print(String(format: "    (stereo: %.1f dB re signal, the upmixer still adapting from the noise)", compare(sb, sa, seconds(4, 4.6)).rel))
    }
    let changes: [Change] = [(Int(2 * rate), settings(.off, .classic)), (Int(4 * rate), settings(.far, .classic))]
    let a = classic(channels: 2, settings: settings(.far, .classic), changes: changes)(withNoise)
    let b = classic(channels: 2, settings: settings(.far, .classic), changes: changes)(withSilence)
    print(String(format: "    (Sfera 1.0 at d18a518: old room sound returns at %.1f dB re signal)", compare(b, a, seconds(4, 4.6)).rel))
}
