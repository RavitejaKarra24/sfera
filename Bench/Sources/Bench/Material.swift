import Foundation

// Deterministic test material. Every generator takes the sample rate, so the same
// programme can be rendered at 44.1, 48 and 96 kHz.

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
func stereo(_ seconds: Double, seed: UInt64 = 1, rate: Double = 48000) -> [[Float]] {
    let n = Int(seconds * rate)
    var rng = Rng(s: seed)
    var l = [Float](repeating: 0, count: n), r = l
    var pinkL: Float = 0, pinkR: Float = 0, common: Float = 0
    for i in 0..<n {
        let t = Double(i) / rate
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
func bed(_ seconds: Double, active: [Int], seed: UInt64 = 7, rate: Double = 48000) -> [[Float]] {
    let n = Int(seconds * rate)
    var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: 16)
    let st = stereo(seconds, seed: seed, rate: rate)
    var rng = Rng(s: seed &+ 99)
    for ch in active {
        var state: Float = 0
        let f = 200.0 + 170.0 * Double(ch)
        for i in 0..<n {
            state = 0.8 * state + 0.2 * rng.next()
            let tone = Float(0.12 * sin(2 * .pi * f * Double(i) / rate))
            switch ch {
            case 0: out[ch][i] = st[0][i] * 0.8
            case 1: out[ch][i] = st[1][i] * 0.8
            case 3: out[ch][i] = Float(0.3 * sin(2 * .pi * 45 * Double(i) / rate)) // LFE
            default: out[ch][i] = 0.18 * state + tone
            }
        }
    }
    return out
}

func silence(_ seconds: Double, channels: Int, rate: Double = 48000) -> [[Float]] {
    [[Float]](repeating: [Float](repeating: 0, count: Int(seconds * rate)), count: channels)
}

/// Equivalence runs at a level where neither limiter acts (see "loud" below for when it does).
func quiet(_ x: [[Float]], _ g: Float = 0.3) -> [[Float]] { x.map { $0.map { $0 * g } } }

/// Concatenates programmes in time; parts with fewer channels are padded with silence.
func concat(_ parts: [[[Float]]], channels: Int) -> [[Float]] {
    (0..<channels).map { ch in parts.flatMap { p in ch < p.count ? p[ch] : [Float](repeating: 0, count: p[0].count) } }
}
