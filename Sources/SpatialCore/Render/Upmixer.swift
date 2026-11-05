import Accelerate
import Foundation

/// Controls for the stereo → immersive upmix.
public struct UpmixSettings: Codable, Sendable, Hashable {
    /// 0 keeps a phantom centre on L/R; 1 steers all centre-panned direct sound to C.
    public var centerExtraction: Double = 0.75
    /// 0 keeps the front stage at ±30°; 1 lets hard-panned direct sound reach the sides (±90°).
    public var width: Double = 0.3
    /// Share of extracted ambience sent to side and rear surrounds.
    public var surround: Double = 0.75
    /// Share of extracted ambience sent to the four overhead channels.
    public var height: Double = 0.6
    /// Derive a low-passed LFE channel. Off by default: L/R/C already carry the bass.
    public var generateLFE: Bool = false

    public init() {}

    public init(centerExtraction: Double, width: Double, surround: Double, height: Double, generateLFE: Bool = false) {
        self.centerExtraction = centerExtraction
        self.width = width
        self.surround = surround
        self.height = height
        self.generateLFE = generateLFE
    }
}

/// Stereo → 7.1.4 bed upmixer.
///
/// Independent implementation of principal-component primary/ambient extraction
/// (Merimaa, Goodwin & Jot, AES 2007; Avendano & Jot, JAES 2004) in the STFT domain.
/// Per frequency bin the 2×2 L/R covariance is tracked over time. Its small eigenvalue
/// estimates the uncorrelated ambience, and its principal eigenvector gives the
/// panning direction of the correlated direct sound. The direct sound is re-panned
/// across Lss·L·C·R·Rss. The ambience is decorrelated (smooth random-phase all-pass
/// per output plus short delays) and spread over the surrounds and heights.
public enum Upmixer {
    /// Output speakers, in WAVE/SMPTE 7.1.4 order. `.lfe` is dropped unless requested.
    public static let layout = ChannelLayout.named("7.1.4")!

    /// Offline upmix: streams the whole programme through `StreamingUpmixer` and removes
    /// its latency, so offline exports and live playback are sample-identical.
    public static func upmix(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        settings: UpmixSettings = UpmixSettings()
    ) -> [Speaker: [Float]] {
        let frames = min(left.count, right.count)
        guard frames > 0 else { return [:] }
        let upmixer = StreamingUpmixer(sampleRate: sampleRate, settings: settings)
        let latency = upmixer.latency
        let total = frames + latency
        let speakers = StreamingUpmixer.speakers
        var outputs = [[Float]](repeating: [Float](repeating: 0, count: total), count: speakers.count)
        let chunk = 4096
        var inL = [Float](repeating: 0, count: chunk)
        var inR = [Float](repeating: 0, count: chunk)
        var scratch = (0..<speakers.count).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: chunk) }
        defer { scratch.forEach { $0.deallocate() } }
        var position = 0
        while position < total {
            let count = min(chunk, total - position)
            for i in 0..<count {
                let index = position + i
                inL[i] = index < frames ? left[index] : 0
                inR[i] = index < frames ? right[index] : 0
            }
            inL.withUnsafeBufferPointer { l in
                inR.withUnsafeBufferPointer { r in
                    upmixer.process(left: l.baseAddress!, right: r.baseAddress!, frames: count, outputs: &scratch)
                }
            }
            for ch in 0..<speakers.count {
                outputs[ch].withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: position).update(from: scratch[ch], count: count)
                }
            }
            position += count
        }
        var result: [Speaker: [Float]] = [:]
        for (ch, speaker) in speakers.enumerated() {
            if speaker == .lfe, !settings.generateLFE { continue }
            result[speaker] = Array(outputs[ch][latency..<total])
        }
        return result
    }
}
