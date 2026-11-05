import Accelerate
import Foundation

/// Read-only views into the engine for the bench and probes. Not used by the app's audio path.
public enum Diagnostics {
    /// Interaural time difference of a direction in seconds (far ear minus near ear).
    public static func itd(azimuth: Double, elevation: Double, sampleRate: Double = 48000, renderer: Renderer) -> Double {
        let cue = Cue(azimuth: azimuth, elevation: elevation, sampleRate: sampleRate, renderer: renderer)
        return Double(max(cue.delayL, cue.delayR)) / sampleRate
    }

    /// The room's early reflections: azimuth and interaural delay in samples.
    public static func reflectionITDs(sampleRate: Double = 48000, renderer: Renderer) -> [(azimuth: Double, samples: Int)] {
        Room(sampleRate: sampleRate).reflectionITDs(renderer: renderer)
    }

    /// Energy of each stereo-upmix output (speaker name, sum of squares) for `left`/`right`,
    /// skipping the first `skip` output samples (the upmix latency is added automatically).
    public static func upmixEnergies(left: [Float], right: [Float], sampleRate: Double = 48000,
                                     settings: UpmixSettings, renderer: Renderer, skip: Int = 0) -> [(speaker: String, energy: Double)] {
        let up = Upmixer(sampleRate: sampleRate, settings: settings)
        up.coherentSteering = renderer == .refined
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
        let refinedRoom = RefinedRoom(sampleRate: sampleRate, maxFrames: block, groups: head.groupDirections)
        refinedRoom.muteEarly = part == .late
        refinedRoom.muteLate = part == .early
        refinedRoom.configure(size: settings.size)
        refinedRoom.tune(settings)
        let groups = max(head.groupDirections.count, 1)
        let sends = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: groups)
        for g in 0..<groups { sends[g] = makeBuffer(block) }
        let active = UnsafeMutablePointer<Bool>.allocate(capacity: groups)
        active.initialize(repeating: false, count: groups)
        let feeds = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: Layout.loopback.count)
        feeds.initialize(repeating: nil, count: Layout.loopback.count)
        let x = makeBuffer(block)
        let dl = makeBuffer(block), dr = makeBuffer(block), rl = makeBuffer(block), rr = makeBuffer(block)
        let sl = makeBuffer(block), sr = makeBuffer(block)
        defer {
            for g in 0..<groups { sends[g].deallocate() }
            sends.deallocate(); active.deallocate(); feeds.deallocate()
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
                         outL: dl, outR: dr, sendL: sl, sendR: sr,
                         groupSends: renderer == .refined ? UnsafePointer(sends) : nil,
                         groupActive: renderer == .refined ? active : nil)
            if renderer == .refined {
                refinedRoom.process(groupSends: sends, groupActive: active, sendL: sl, sendR: sr, addingTo: rl, rr, frames: n)
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

    /// Magnitude (dB) of the elevation filter at `frequency` for a source at `elevation`.
    public static func elevationGain(elevation: Double, frequency: Double, renderer: Renderer, sampleRate: Double = 48000) -> Double {
        let filters: [Biquad]
        if renderer == .refined {
            let (a, b) = Cue.elevationFilters(elevation: elevation, sampleRate: sampleRate)
            filters = [a, b]
        } else {
            let gain = Cue(azimuth: 0, elevation: elevation, sampleRate: sampleRate, renderer: .classic).notchGainDB
            filters = [.peaking(8200, gainDB: gain, q: 1.3, sampleRate: sampleRate)]
        }
        return filters.reduce(0) { $0 + 20 * log10($1.magnitude(at: frequency, sampleRate: sampleRate)) }
    }

    /// The Refined room's early reflections for one speaker: per ear, delay (samples), gain and
    /// whether it arrives from above or below the ear plane.
    public static func refinedReflections(speaker: Speaker, size: RoomSize = .medium, sampleRate: Double = 48000)
        -> [(ear: Int, delay: Int, gain: Float, above: Bool, below: Bool)] {
        let head = HeadRenderer(speakers: [speaker], sampleRate: sampleRate, maxFrames: 64, renderer: .refined)
        return RefinedRoom(sampleRate: sampleRate, maxFrames: 64, groups: head.groupDirections).taps(group: 0, size: size)
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
