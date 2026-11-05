import Accelerate
import Foundation

/// Read-only views into the engine for the bench and probes. Not used by the app's audio path.
public enum Diagnostics {
    /// Interaural time difference of a direction in seconds (far ear minus near ear; both renderers).
    public static func itd(azimuth: Double, elevation: Double, sampleRate: Double = 48000) -> Double {
        let cue = Cue(azimuth: azimuth, elevation: elevation, sampleRate: sampleRate)
        return Double(max(cue.delayL, cue.delayR)) / sampleRate
    }

    /// The room's early reflections: azimuth and interaural delay in samples.
    public static func reflectionITDs(sampleRate: Double = 48000, renderer: Renderer) -> [(azimuth: Double, samples: Int)] {
        Room(sampleRate: sampleRate).reflectionITDs(renderer: renderer)
    }

    /// Energy of each stereo-upmix output (speaker name, sum of squares) for `left`/`right`,
    /// skipping the first `skip` output samples (the upmix latency is added automatically).
    /// Both renderers share the upmix.
    public static func upmixEnergies(left: [Float], right: [Float], sampleRate: Double = 48000,
                                     settings: UpmixSettings, skip: Int = 0) -> [(speaker: String, energy: Double)] {
        let up = Upmixer(sampleRate: sampleRate, settings: settings)
        let block = 512
        let outs = (0..<Upmixer.outputCount).map { _ in makeBuffer(block) }
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: outs.count)
        defer { outs.forEach { $0.deallocate() }; table.deallocate() }
        for (j, p) in outs.enumerated() { table[j] = p }
        var energy = [Double](repeating: 0, count: outs.count)
        let start = up.latency + skip
        var pos = 0
        let frames = min(left.count, right.count)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                while pos < frames {
                    let n = min(block, frames - pos)
                    up.process(left: l.baseAddress! + pos, right: r.baseAddress! + pos, frames: n, outputs: table)
                    for j in 0..<outs.count {
                        for i in 0..<n where pos + i >= start { energy[j] += Double(outs[j][i]) * Double(outs[j][i]) }
                    }
                    pos += n
                }
            }
        }
        return zip(Layout.upmix, energy).map { ("\($0.0)".uppercased(), $0.1) }
    }

    // MARK: - Room

    public enum RoomPart: Sendable { case all, early, late }

    /// Impulse on one speaker through the head renderer and room at `mode`'s levels.
    /// Returns the direct path and the room alone, each per ear.
    public static func roomResponse(speaker: Speaker, renderer: Renderer, mode: RoomMode = .far,
                                    room settings: RoomSettings = RoomSettings(), part: RoomPart = .all,
                                    sampleRate: Double = 48000, seconds: Double = 2) -> (direct: [[Float]], room: [[Float]]) {
        let block = 512
        let total = Int(seconds * sampleRate)
        let head = HeadRenderer(speakers: [speaker], sampleRate: sampleRate, maxFrames: block, renderer: renderer)
        let classicRoom = Room(sampleRate: sampleRate)
        let refinedRoom = RefinedRoom(sampleRate: sampleRate)
        refinedRoom.muteEarly = part == .late
        refinedRoom.muteLate = part == .early
        refinedRoom.configure(size: settings.size)
        refinedRoom.tune(settings)
        let feeds = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: Layout.loopback.count)
        feeds.initialize(repeating: nil, count: Layout.loopback.count)
        let x = makeBuffer(block)
        let dl = makeBuffer(block), dr = makeBuffer(block), rl = makeBuffer(block), rr = makeBuffer(block)
        let sl = makeBuffer(block), sr = makeBuffer(block)
        defer {
            feeds.deallocate()
            for p in [x, dl, dr, rl, rr, sl, sr] { p.deallocate() }
        }
        var direct: [[Float]] = [[], []], room: [[Float]] = [[], []]
        let directGain = dbToGain(mode.directDB), send = mode == .off ? 0 : dbToGain(mode.sendDB)
        var pos = 0
        while pos < total {
            let n = min(block, total - pos)
            vDSP_vclr(x, 1, vDSP_Length(n))
            if pos == 0 { x[0] = 1 }
            feeds[speaker.rawValue] = x
            for p in [dl, dr, rl, rr, sl, sr] { vDSP_vclr(p, 1, vDSP_Length(n)) }
            head.process(feeds: feeds, frames: n, direct: directGain, send: send, dry: mode == .off,
                         outL: dl, outR: dr, sendL: sl, sendR: sr)
            if renderer == .refined {
                refinedRoom.process(sendL: sl, sendR: sr, lfe: nil, addingTo: rl, rr, frames: n)
            } else {
                classicRoom.process(sendL: sl, sendR: sr, addingTo: rl, rr, frames: n, renderer: .classic)
            }
            direct[0] += UnsafeBufferPointer(start: dl, count: n); direct[1] += UnsafeBufferPointer(start: dr, count: n)
            room[0] += UnsafeBufferPointer(start: rl, count: n); room[1] += UnsafeBufferPointer(start: rr, count: n)
            pos += n
        }
        return (direct, room)
    }

    /// Reverberation time (T30, s) of the room's tail for an impulse on C, in octave bands
    /// around `bands` (Hz): Schroeder backward integration, line fit from −5 to −35 dB.
    public static func decayTimes(renderer: Renderer, room settings: RoomSettings = RoomSettings(),
                                  bands: [Double], sampleRate: Double = 48000) -> [Double] {
        let ir = roomResponse(speaker: .c, renderer: renderer, room: settings, part: .late, sampleRate: sampleRate, seconds: 3).room
        return bands.map { f in
            // Octave band-pass (RBJ constant 0 dB peak), run twice for steeper skirts.
            let w0 = 2 * Double.pi * f / sampleRate, q = 1.414
            let alpha = sin(w0) / (2 * q)
            let bp = Biquad(b0: alpha, b1: 0, b2: -alpha, a0: 1 + alpha, a1: -2 * cos(w0), a2: 1 - alpha)
            var energy = [Double](repeating: 0, count: ir[0].count)
            for ear in 0..<2 {
                var a = bp, b = bp
                for i in 0..<ir[ear].count {
                    let y = Double(b.process(a.process(ir[ear][i])))
                    energy[i] += y * y
                }
            }
            var tail = energy
            for i in stride(from: tail.count - 2, through: 0, by: -1) { tail[i] += tail[i + 1] }
            let top = tail[0]
            guard top > 0 else { return .nan }
            func time(at dB: Double) -> Double {
                let level = top * pow(10, dB / 10)
                return Double(tail.firstIndex { $0 < level } ?? tail.count) / sampleRate
            }
            return 60 * (time(at: -35) - time(at: -5)) / 30
        }
    }

    /// The Refined room's early reflections in a room size: near-ear delay in ms, in order.
    public static func refinedReflectionDelays(size: RoomSize, sampleRate: Double = 48000) -> [Double] {
        RefinedRoom(sampleRate: sampleRate).reflectionDelays(size: size).map { Double($0.near) / sampleRate * 1000 }
    }

    /// Energy of a binaural response in the octave band around `center` (Hz).
    public static func bandEnergy(_ x: [[Float]], center: Double, sampleRate: Double = 48000) -> Double {
        let w0 = 2 * Double.pi * center / sampleRate, q = 1.414
        let alpha = sin(w0) / (2 * q)
        let bp = Biquad(b0: alpha, b1: 0, b2: -alpha, a0: 1 + alpha, a1: -2 * cos(w0), a2: 1 - alpha)
        var e = 0.0
        for ch in x {
            var a = bp, b = bp
            for v in ch { let y = Double(b.process(a.process(v))); e += y * y }
        }
        return e
    }
}
