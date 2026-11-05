import Foundation
import SferaCore

// Openness: on headphones the image leaves the head only when the two ears hear different
// signals. IACC (the largest normalised interaural cross-correlation within ±1 ms) measures
// it: 1 = identical ears, inside the head. The listener prefers Classic's image (vocal in
// the head, instruments around it, backing vocals behind), so Refined must never be more
// "in the head" than Classic. The first Refined room failed exactly this: its early
// reflections reached both ears alike (IACC 0.93–0.99 for C, Classic 0.17), the upmix put
// more of the mix in C, and smaller rear ITDs pulled the surrounds in.

private let rate = 48000.0
/// Margins: a quarter or less of the just-noticeable IACC difference, which is about 0.08
/// for IACC near 1 and grows to about 0.35 near 0 (Gabriel & Colburn 1981). Direct + room
/// and whole mixes sit at 0.45–0.95; the tail alone near 0.1.
private let margin = 0.02, tailMargin = 0.05

/// IACC of `l`/`r` over `range`: max |normalised cross-correlation| for lags within ±1 ms.
func iacc(_ l: [Float], _ r: [Float], _ range: Range<Int>) -> Double {
    let maxLag = Int(0.001 * rate)
    let a = range.lowerBound, b = min(range.upperBound, l.count, r.count)
    var el = 0.0, er = 0.0
    for i in a..<b { el += Double(l[i]) * Double(l[i]); er += Double(r[i]) * Double(r[i]) }
    guard el > 0, er > 0 else { return 0 }
    var best = 0.0
    l.withUnsafeBufferPointer { lp in
        r.withUnsafeBufferPointer { rp in
            for lag in -maxLag...maxLag {
                let lo = max(a, a - lag), hi = min(b, b - lag)
                var s = 0.0
                for i in lo..<hi { s += Double(lp[i]) * Double(rp[i + lag]) }
                best = max(best, abs(s))
            }
        }
    }
    return best / (el * er).squareRoot()
}

private func room(_ size: RoomSize) -> RoomSettings { var r = RoomSettings(); r.size = size; return r }

func opennessSuite() {
    print("\nOpenness: Refined's ears no more alike than Classic's (IACC, Far, 1 = inside the head)")

    // 1. Each speaker, direct sound + room, 0–0.5 s.
    let speakers: [Speaker] = [.c, .l, .r, .lss, .rss, .lrs, .rrs, .ltf, .rtf, .ltr, .rtr, .cts]
    let window = 0..<Int(0.5 * rate)
    func total(_ x: (direct: [[Float]], room: [[Float]])) -> [[Float]] {
        (0..<2).map { ear in zip(x.direct[ear], x.room[ear]).map { $0 + $1 } }
    }
    var rows: [String] = []
    var worse: [String] = []
    for s in speakers {
        let c = total(Diagnostics.roomResponse(speaker: s, renderer: .classic, seconds: 0.5))
        let ci = iacc(c[0], c[1], window)
        var row = String(format: "%@ %.2f→", "\(s)".uppercased(), ci)
        for size in RoomSize.allCases {
            let r = total(Diagnostics.roomResponse(speaker: s, renderer: .refined, room: room(size), seconds: 0.5))
            let ri = iacc(r[0], r[1], window)
            row += String(format: "%.2f%@", ri, size == .large ? "" : "/")
            if ri > ci + margin { worse.append(String(format: "%@ %@ %.2f vs %.2f", "\(s)", size.label, ri, ci)) }
        }
        rows.append(row)
    }
    print("    per speaker, classic→refined S/M/L: " + rows.prefix(6).joined(separator: "  "))
    print("                                        " + rows.dropFirst(6).joined(separator: "  "))
    expect("every speaker, every size: IACC ≤ Classic's", worse.isEmpty, worse.isEmpty ? "12 speakers × 3 sizes" : worse.joined(separator: "; "))

    // 2. The room on its own: early reflections (0–80 ms) clearly different at the two ears,
    //    and a tail (80–500 ms) at least as diffuse as Classic's.
    var earlyWorst = 0.0, earlyWho = "", tailWorse: [String] = []
    var earlyLine = "    room alone, 0–80 ms, Medium:", tailLine = "    room alone, 80–500 ms, Medium:"
    let earlyRange = 0..<Int(0.08 * rate), tailRange = Int(0.08 * rate)..<Int(0.5 * rate)
    for s in [Speaker.c, .l, .lss, .lrs, .ltf, .ltr, .cts] {
        let c = Diagnostics.roomResponse(speaker: s, renderer: .classic, seconds: 0.5).room
        for size in RoomSize.allCases {
            let r = Diagnostics.roomResponse(speaker: s, renderer: .refined, room: room(size), seconds: 0.5).room
            let e = iacc(r[0], r[1], earlyRange), t = iacc(r[0], r[1], tailRange), ct = iacc(c[0], c[1], tailRange)
            if e > earlyWorst { earlyWorst = e; earlyWho = "\(s) \(size.label)" }
            if t > ct + tailMargin { tailWorse.append(String(format: "%@ %@ %.2f vs %.2f", "\(s)", size.label, t, ct)) }
            if size == .medium {
                earlyLine += String(format: "  %@ %.2f→%.2f", "\(s)".uppercased(), iacc(c[0], c[1], earlyRange), e)
                tailLine += String(format: "  %@ %.2f→%.2f", "\(s)".uppercased(), ct, t)
            }
        }
    }
    print(earlyLine); print(tailLine)
    expect("early reflections differ at the two ears (IACC ≤ 0.35)", earlyWorst <= 0.35,
           String(format: "highest %.2f (%@); the first Refined room: 0.93–0.99", earlyWorst, earlyWho))
    expect("tail at least as diffuse as Classic's", tailWorse.isEmpty, tailWorse.isEmpty ? "7 speakers × 3 sizes" : tailWorse.joined(separator: "; "))

    // 3. End to end: a stereo mix through upmix, head and room. The whole mix and its parts:
    //    a centred vocal, a guitar panned left, and the ambience.
    let n = Int(4 * rate)
    var rng = Rng(s: 41)
    var vocal = [Float](repeating: 0, count: n), guitar = vocal, ambL = vocal, ambR = vocal
    var v: Float = 0, g: Float = 0
    for i in 0..<n {
        v = 0.6 * v + 0.4 * rng.next(); g = 0.3 * g + 0.7 * rng.next()
        vocal[i] = 0.25 * v; guitar[i] = 0.2 * g
        ambL[i] = 0.08 * rng.next(); ambR[i] = 0.08 * rng.next()
    }
    let parts: [(String, [Float], [Float])] = [
        ("mix", (0..<n).map { vocal[$0] + 0.8 * guitar[$0] + ambL[$0] }, (0..<n).map { vocal[$0] + 0.3 * guitar[$0] + ambR[$0] }),
        ("vocal", vocal, vocal),
        ("guitar left", guitar.map { 0.8 * $0 }, guitar.map { 0.3 * $0 }),
        ("ambience", ambL, ambR),
    ]
    let measure = Int(1.5 * rate)..<Int(3.5 * rate)
    for (name, l, r) in parts {
        var s = LiveSettings(); s.renderMode = .far; s.renderer = .classic
        let c = rewrite(channels: 2, settings: s)([l, r])
        let ci = iacc(c.l, c.r, measure)
        var line = String(format: "    stereo %@: classic %.2f, refined", name, ci)
        var bad: [String] = []
        for size in RoomSize.allCases {
            s.renderer = .refined; s.room = room(size)
            let out = rewrite(channels: 2, settings: s)([l, r])
            let ri = iacc(out.l, out.r, measure)
            line += String(format: " %@ %.2f", size.label, ri)
            if ri > ci + margin { bad.append(String(format: "%@ %.2f", size.label, ri)) }
        }
        print(line)
        expect("stereo \(name): IACC ≤ Classic's", bad.isEmpty, bad.isEmpty ? String(format: "classic %.2f", ci) : bad.joined(separator: ", "))
    }
}
