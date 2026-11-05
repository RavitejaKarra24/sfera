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
}
