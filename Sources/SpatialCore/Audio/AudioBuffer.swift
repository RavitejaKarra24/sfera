import Foundation

/// Deinterleaved float planar audio. All rendering happens in this form.
public struct PlanarAudio: Sendable {
    public var sampleRate: Double
    public var channels: [[Float]]

    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public init(silenceChannels count: Int, frames: Int, sampleRate: Double) {
        self.sampleRate = sampleRate
        self.channels = Array(repeating: [Float](repeating: 0, count: frames), count: count)
    }

    public var frameCount: Int { channels.first?.count ?? 0 }
    public var channelCount: Int { channels.count }
    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    public subscript(channel: Int) -> [Float] {
        get { channels[channel] }
        set { channels[channel] = newValue }
    }

    public func peak() -> Float {
        var p: Float = 0
        for ch in channels { for s in ch { p = max(p, abs(s)) } }
        return p
    }

    public func rms(channel: Int) -> Float {
        guard channel < channels.count, !channels[channel].isEmpty else { return 0 }
        var sum: Double = 0
        for s in channels[channel] { sum += Double(s) * Double(s) }
        return Float((sum / Double(channels[channel].count)).squareRoot())
    }

    /// Trim or pad every channel to `frames`.
    public func fitted(frames: Int) -> PlanarAudio {
        var out = self
        out.channels = channels.map { ch in
            if ch.count == frames { return ch }
            if ch.count > frames { return Array(ch.prefix(frames)) }
            return ch + [Float](repeating: 0, count: frames - ch.count)
        }
        return out
    }

    public func appendingSilence(frames: Int) -> PlanarAudio {
        var out = self
        out.channels = channels.map { $0 + [Float](repeating: 0, count: frames) }
        return out
    }

    public func slice(_ range: Range<Int>) -> PlanarAudio {
        var out = self
        out.channels = channels.map { Array($0[range]) }
        return out
    }

    public mutating func clampInPlace(to limit: Float) {
        for c in channels.indices {
            for i in channels[c].indices {
                channels[c][i] = min(max(channels[c][i], -limit), limit)
            }
        }
    }

    public static func mix(_ sources: [PlanarAudio], frames: Int, sampleRate: Double) -> PlanarAudio {
        var out = PlanarAudio(silenceChannels: 2, frames: frames, sampleRate: sampleRate)
        for source in sources {
            for ch in 0..<min(2, source.channelCount) {
                for i in 0..<min(frames, source.frameCount) {
                    out.channels[ch][i] += source.channels[ch][i]
                }
            }
        }
        return out
    }
}

public enum AudioMath {
    public static func dbToGain(_ db: Double) -> Float {
        if db <= -120 { return 0 }
        return Float(pow(10.0, db / 20.0))
    }

    public static func gainToDB(_ gain: Float) -> Double {
        if gain <= 0 { return -.infinity }
        return 20.0 * log10(Double(gain))
    }

    public static func formatDB(_ value: Double) -> String {
        if value <= -120 || value.isInfinite || value.isNaN { return "−∞" }
        return String(format: "%.1f", value)
    }

    public static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        min(max(v, lo), hi)
    }
}
