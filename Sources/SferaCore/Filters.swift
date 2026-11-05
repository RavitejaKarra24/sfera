import Foundation

/// Allocates a zeroed float buffer (freed by its owner's deinit).
@inline(__always)
func makeBuffer(_ count: Int, _ value: Float = 0) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
    p.initialize(repeating: value, count: max(count, 1))
    return p
}

@inline(__always)
func nextPowerOfTwo(atLeast n: Int) -> Int {
    var size = 1
    while size < n { size <<= 1 }
    return size
}

/// Direct-form-I biquad. Hot loops copy it into a local, run, and store it back,
/// so the per-sample path has no property access or exclusivity checks.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init() {}

    /// Normalised by a0 in single precision (the coefficients are designed in double).
    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        let a0 = Float(a0)
        self.b0 = Float(b0) / a0
        self.b1 = Float(b1) / a0
        self.b2 = Float(b2) / a0
        self.a1 = Float(a1) / a0
        self.a2 = Float(a2) / a0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    mutating func run(_ p: UnsafeMutablePointer<Float>, _ frames: Int) {
        var f = self
        for i in 0..<frames { p[i] = f.process(p[i]) }
        self = f
    }

    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    /// Magnitude response at `frequency` (for the bench).
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func mag(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w), im = -(c1 * sin(w) + c2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        return mag(Double(b0), Double(b1), Double(b2)) / mag(1, Double(a1), Double(a2))
    }

    // RBJ cookbook designs.

    static func lowPass(_ frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let w0 = 2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * q), cw = cos(w0)
        return Biquad(b0: (1 - cw) / 2, b1: 1 - cw, b2: (1 - cw) / 2, a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }

    static func highPass(_ frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let w0 = 2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * q), cw = cos(w0)
        return Biquad(b0: (1 + cw) / 2, b1: -(1 + cw), b2: (1 + cw) / 2, a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }

    static func peaking(_ frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * q), cw = cos(w0)
        return Biquad(b0: 1 + alpha * A, b1: -2 * cw, b2: 1 - alpha * A, a0: 1 + alpha / A, a1: -2 * cw, a2: 1 - alpha / A)
    }
}

/// One-pole low-pass coefficient: y += c·(x − y).
func onePoleCoefficient(_ frequency: Double, sampleRate: Double) -> Float {
    let f = min(max(frequency, 10), sampleRate * 0.49)
    return Float(1 - exp(-2 * Double.pi * f / sampleRate))
}

/// SplitMix64: small deterministic generator (decorrelation phases).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUniform() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

/// First-order shelf (bilinear): `low` sets the gain below `frequency`, otherwise above it.
struct Shelf {
    var b0: Float = 1, b1: Float = 0, a1: Float = 0
    var x1: Float = 0, y1: Float = 0

    init() {}

    init(low: Bool, frequency: Double, gain: Double, sampleRate: Double) {
        let k = tan(.pi * min(frequency, sampleRate * 0.49) / sampleRate)
        let a0 = 1 + k
        if low {          // (s + G·ωc) / (s + ωc)
            b0 = Float((1 + gain * k) / a0); b1 = Float((gain * k - 1) / a0)
        } else {          // (G·s + ωc) / (s + ωc)
            b0 = Float((gain + k) / a0); b1 = Float((k - gain) / a0)
        }
        a1 = Float((k - 1) / a0)
    }

    /// Magnitude response at `frequency`.
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func mag(_ c0: Double, _ c1: Double) -> Double {
            let re = c0 + c1 * cos(w), im = -c1 * sin(w)
            return (re * re + im * im).squareRoot()
        }
        return mag(Double(b0), Double(b1)) / mag(1, Double(a1))
    }

    /// New coefficients, same state.
    mutating func take(_ other: Shelf) { b0 = other.b0; b1 = other.b1; a1 = other.a1 }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 - a1 * y1
        x1 = x; y1 = y
        return y
    }

    mutating func reset() { x1 = 0; y1 = 0 }
}
