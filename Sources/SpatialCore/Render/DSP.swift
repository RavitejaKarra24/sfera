import Foundation

// MARK: - Biquad

public struct Biquad: Sendable {
    public var b0: Float = 1, b1: Float = 0, b2: Float = 0
    public var a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    public init() {}

    public init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    public mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    /// Takes `design`'s coefficients but keeps this filter's state, so a filter can be
    /// retuned while running without a discontinuity.
    public mutating func setCoefficients(_ design: Biquad) {
        b0 = design.b0; b1 = design.b1; b2 = design.b2
        a1 = design.a1; a2 = design.a2
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    // Standard RBJ cookbook designs.

    public static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let sqrtA = A.squareRoot()
        let b0 = A * ((A + 1) + (A - 1) * cw + 2 * sqrtA * alpha)
        let b1 = -2 * A * ((A - 1) + (A + 1) * cw)
        let b2 = A * ((A + 1) + (A - 1) * cw - 2 * sqrtA * alpha)
        let a0 = (A + 1) - (A - 1) * cw + 2 * sqrtA * alpha
        let a1 = 2 * ((A - 1) - (A + 1) * cw)
        let a2 = (A + 1) - (A - 1) * cw - 2 * sqrtA * alpha
        return Biquad(b0: Float(b0), b1: Float(b1), b2: Float(b2), a0: Float(a0), a1: Float(a1), a2: Float(a2))
    }

    public static func highPass(frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let w0 = 2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let b0 = (1 + cw) / 2
        let b1 = -(1 + cw)
        let b2 = (1 + cw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cw
        let a2 = 1 - alpha
        return Biquad(b0: Float(b0), b1: Float(b1), b2: Float(b2), a0: Float(a0), a1: Float(a1), a2: Float(a2))
    }

    public static func lowPass(frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let w0 = 2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let b0 = (1 - cw) / 2
        let b1 = 1 - cw
        let b2 = (1 - cw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cw
        let a2 = 1 - alpha
        return Biquad(b0: Float(b0), b1: Float(b1), b2: Float(b2), a0: Float(a0), a1: Float(a1), a2: Float(a2))
    }

    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let b0 = 1 + alpha * A
        let b1 = -2 * cw
        let b2 = 1 - alpha * A
        let a0 = 1 + alpha / A
        let a1 = -2 * cw
        let a2 = 1 - alpha / A
        return Biquad(b0: Float(b0), b1: Float(b1), b2: Float(b2), a0: Float(a0), a1: Float(a1), a2: Float(a2))
    }

    /// Second-order all-pass used to build the 90° surround shift for Lt/Rt.
    public static func allPass90(sampleRate: Double) -> Biquad {
        let f = 350.0
        let w0 = 2 * .pi * f / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * 0.707)
        let a0 = 1 + alpha
        return Biquad(b0: Float((1 - alpha) / a0), b1: Float(-2 * cw / a0), b2: Float(1),
                      a0: Float(1), a1: Float(-2 * cw / a0), a2: Float((1 - alpha) / a0))
    }
}

// MARK: - One-pole low pass (used for head shadow and LFE management)

public struct OnePole: Sendable {
    public var coefficient: Float = 1
    private var state: Float = 0
    public init() {}

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        state += coefficient * (x - state)
        return state
    }

    public mutating func setCutoff(_ frequency: Double, sampleRate: Double) {
        let f = min(max(frequency, 10), sampleRate * 0.49)
        coefficient = Float(1 - exp(-2 * Double.pi * f / sampleRate))
    }

    public mutating func reset() { state = 0 }
}

// MARK: - Fractional delay line

public struct FractionalDelay: Sendable {
    private var buffer: [Float]
    private var writeIndex = 0
    public let maxDelaySamples: Int

    public init(maxDelaySamples: Int = 64) {
        self.maxDelaySamples = max(maxDelaySamples, 2)
        buffer = [Float](repeating: 0, count: self.maxDelaySamples + 1)
    }

    @inline(__always)
    public mutating func process(_ x: Float, delay: Float) -> Float {
        buffer[writeIndex] = x
        let d = min(max(delay, 0), Float(maxDelaySamples - 1))
        let readPos = Float(writeIndex) - d
        var wrapped = readPos < 0 ? readPos + Float(buffer.count) : readPos
        if wrapped >= Float(buffer.count) { wrapped -= Float(buffer.count) }
        if wrapped < 0 { wrapped += Float(buffer.count) }
        let i0 = min(max(Int(wrapped), 0), buffer.count - 1)
        let frac = wrapped - Float(i0)
        let i1 = (i0 + 1) % buffer.count
        writeIndex = (writeIndex + 1) % buffer.count
        return buffer[i0] * (1 - frac) + buffer[i1] * frac
    }

    public mutating func reset() {
        buffer = [Float](repeating: 0, count: buffer.count)
        writeIndex = 0
    }
}

// MARK: - Look-ahead limiter

public struct LimiterSettings: Codable, Sendable, Hashable {
    public var enabled: Bool = true
    public var ceilingDB: Double = -0.3
    public var thresholdDB: Double = -1.5
    public var lookaheadMS: Double = 2.0
    public var releaseMS: Double = 160

    public init() {}
}

public enum LookaheadLimiter {
    /// Feed-forward look-ahead peak limiter. Gain is derived from the peak maximum
    /// of the upcoming window, so transients are caught before they reach the ceiling.
    public static func process(_ input: PlanarAudio, settings: LimiterSettings) -> (audio: PlanarAudio, maxReductionDB: Double) {
        guard settings.enabled, input.channelCount > 0, input.frameCount > 0 else { return (input, 0) }
        let sr = input.sampleRate
        let lookahead = max(2, Int(settings.lookaheadMS / 1000 * sr))
        let frames = input.frameCount
        let threshold = Float(pow(10, settings.thresholdDB / 20))
        let ceiling = Float(pow(10, settings.ceilingDB / 20))
        let attackCoef = Float(1 - exp(-1.0 / (0.0004 * sr)))
        let releaseCoef = Float(1 - exp(-1.0 / (settings.releaseMS / 1000 * sr)))

        var peak = [Float](repeating: 0, count: frames)
        for ch in 0..<input.channelCount {
            let s = input.channels[ch]
            for i in 0..<frames {
                let a = abs(s[i])
                if a > peak[i] { peak[i] = a }
            }
        }

        // Monotonic deque sliding maximum over [i, i + lookahead].
        var required = [Float](repeating: 1, count: frames)
        var deque: [Int] = []
        deque.reserveCapacity(lookahead * 2)
        var head = 0
        var next = 0
        for i in 0..<frames {
            let upper = min(frames - 1, i + lookahead)
            while next <= upper {
                while deque.count > head, peak[deque[deque.count - 1]] <= peak[next] { deque.removeLast() }
                deque.append(next)
                next += 1
            }
            while deque[head] < i { head += 1 }
            let maxPeak = peak[deque[head]]
            required[i] = maxPeak > threshold ? threshold / maxPeak : 1
        }

        var output = input
        var gain: Float = 1
        var minGain: Float = 1
        for i in 0..<frames {
            let target = required[i]
            if target < gain {
                gain += (target - gain) * attackCoef
                if gain > target { gain = target }
            } else {
                gain = target + (gain - target) * (1 - releaseCoef)
            }
            if gain < minGain { minGain = gain }
            for ch in 0..<output.channelCount {
                output.channels[ch][i] = min(max(output.channels[ch][i] * gain, -ceiling), ceiling)
            }
        }
        let reduction = minGain < 0.999 ? 20 * log10(Double(max(minGain, 0.0001))) : 0
        return (output, reduction)
    }
}

/// SplitMix64: small deterministic generator (decorrelation phases, test signals).
public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
