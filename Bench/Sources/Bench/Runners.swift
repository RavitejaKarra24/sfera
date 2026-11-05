import ClassicCore
import Foundation
import LegacyCore
import SferaCore

// Three engines run on identical input:
// - SferaCore:   the engine as it is in the working tree.
// - ClassicCore: Sfera 1.0 frozen at the commit in run.sh (the reference "Classic" sound,
//                including the Far the listener prefers). Extracted from git, never edited.
// - LegacyCore:  Sfera 0.9, for the historical equivalence report.

struct Render {
    var l: [Float]
    var r: [Float]
    /// CPU time spent inside `process`.
    var seconds: Double
}

typealias Runner = (_ input: [[Float]]) -> Render

/// How the host slices the stream into callbacks.
struct Blocks {
    let name: String
    let maxFrames: Int
    private let sizes: [Int]

    /// Every callback the same size (the usual Core Audio case).
    static func fixed(_ n: Int) -> Blocks { Blocks(name: "\(n)-frame blocks", maxFrames: n, sizes: [n]) }

    /// Deterministic irregular sizes in 1…maxFrames, including single samples.
    static func irregular(max: Int, seed: UInt64 = 42) -> Blocks {
        var rng = Rng(s: seed)
        var sizes = [1, 2, 3, max, 1, max - 1]
        for _ in 0..<500 {
            let u = (rng.next() + 1) / 2                      // 0…1
            sizes.append(Swift.max(1, Swift.min(max, Int(u * Float(max)) + 1)))
        }
        return Blocks(name: "irregular blocks ≤ \(max)", maxFrames: max, sizes: sizes)
    }

    func size(_ k: Int) -> Int { sizes[k % sizes.count] }
}

/// Feeds `input` through a processor block by block. Channels the input lacks are silent.
func run(inputs: [UnsafeMutablePointer<Float>], blocks: Blocks, input: [[Float]],
         process: (Int, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void) -> Render {
    let frames = input[0].count
    var outL = [Float](repeating: 0, count: frames), outR = outL
    let tl = UnsafeMutablePointer<Float>.allocate(capacity: blocks.maxFrames)
    let tr = UnsafeMutablePointer<Float>.allocate(capacity: blocks.maxFrames)
    defer { tl.deallocate(); tr.deallocate() }
    var elapsed = 0.0
    var pos = 0, k = 0
    while pos < frames {
        let count = min(blocks.size(k), frames - pos)
        k += 1
        for (ch, p) in inputs.enumerated() {
            if ch < input.count {
                input[ch].withUnsafeBufferPointer { src in p.update(from: src.baseAddress!.advanced(by: pos), count: count) }
            } else {
                p.update(repeating: 0, count: count)
            }
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        process(count, tl, tr)
        elapsed += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        for i in 0..<count { outL[pos + i] = tl[i]; outR[pos + i] = tr[i] }
        pos += count
    }
    return Render(l: outL, r: outR, seconds: elapsed)
}

typealias Change = (frame: Int, settings: SferaCore.LiveSettings)

// MARK: - Current engine

func rewrite(channels: Int, settings: SferaCore.LiveSettings, rate: Double = 48000, blocks: Blocks = .fixed(512),
             change: Change? = nil, changes: [Change] = []) -> Runner {
    let all = (change.map { [$0] } ?? []) + changes
    return { input in
        let p = SferaCore.Spatializer(sampleRate: rate, channels: channels, settings: settings, maxFrames: blocks.maxFrames)
        var done = 0
        return run(inputs: p.inputs, blocks: blocks, input: input) { n, l, r in
            for c in all where done <= c.frame && done + n > c.frame { p.update(c.settings) }
            p.process(frames: n, outL: l, outR: r)
            done += n
        }
    }
}

// MARK: - Classic reference (frozen 1.0)

/// Same JSON shape in both engines; unknown future fields are ignored by Classic.
func classicSettings(_ s: SferaCore.LiveSettings) -> ClassicCore.LiveSettings {
    let data = try! JSONEncoder().encode(s)
    return try! JSONDecoder().decode(ClassicCore.LiveSettings.self, from: data)
}

func classic(channels: Int, settings: SferaCore.LiveSettings, rate: Double = 48000, blocks: Blocks = .fixed(512),
             change: Change? = nil, changes: [Change] = []) -> Runner {
    let all = (change.map { [$0] } ?? []) + changes
    return { input in
        let p = ClassicCore.Spatializer(sampleRate: rate, channels: channels, settings: classicSettings(settings),
                                        maxFrames: blocks.maxFrames)
        var done = 0
        return run(inputs: p.inputs, blocks: blocks, input: input) { n, l, r in
            for c in all where done <= c.frame && done + n > c.frame { p.update(classicSettings(c.settings)) }
            p.process(frames: n, outL: l, outR: r)
            done += n
        }
    }
}

// MARK: - Sfera 0.9

func legacySettings(_ s: SferaCore.LiveSettings) -> LegacyCore.LiveSettings {
    var l = LegacyCore.LiveSettings()
    l.spatial = s.spatial
    l.upmix = LegacyCore.UpmixSettings(centerExtraction: s.upmix.centerExtraction, width: s.upmix.width,
                                       surround: s.upmix.surround, height: s.upmix.height, generateLFE: s.upmix.generateLFE)
    l.renderMode = LegacyCore.DistanceModel(rawValue: s.renderMode.rawValue)!
    l.outputGainDB = s.outputGainDB
    return l
}

func legacy(channels: Int, settings: SferaCore.LiveSettings, change: Change? = nil) -> Runner {
    { input in
        let ls = legacySettings(settings)
        let block = Blocks.fixed(512)
        let p: any LiveProcessor = channels > 2
            ? AdaptiveSpatializer(sampleRate: 48000, inputLayout: SpatialDiagnostics.loopbackLayout, settings: ls, maxFrames: block.maxFrames)
            : LiveSpatializer(sampleRate: 48000, inputLayout: .stereo, settings: ls, maxFrames: block.maxFrames)
        var done = 0
        return run(inputs: p.inputs, blocks: block, input: input) { n, l, r in
            if let change, done <= change.frame, done + n > change.frame { p.update(legacySettings(change.settings)) }
            p.process(frames: n, outL: l, outR: r)
            done += n
        }
    }
}

/// Sfera 0.9's surround chain alone (no adaptive crossfade), delayed to the adaptive latency.
func legacyBedOnly(settings: SferaCore.LiveSettings) -> Runner {
    { input in
        let block = Blocks.fixed(512)
        let p = LiveSpatializer(sampleRate: 48000, inputLayout: SpatialDiagnostics.loopbackLayout,
                                settings: legacySettings(settings), maxFrames: block.maxFrames)
        var out = run(inputs: p.inputs, blocks: block, input: input) { n, l, r in p.process(frames: n, outL: l, outR: r) }
        let d = 2048
        out.l = [Float](repeating: 0, count: d) + out.l.dropLast(d)
        out.r = [Float](repeating: 0, count: d) + out.r.dropLast(d)
        return out
    }
}
