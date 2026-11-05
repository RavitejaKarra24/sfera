import Foundation

/// BS.1770-4 loudness analysis with true-peak estimation.
public struct LoudnessResult: Sendable {
    public init() {}
    public var integrated: Double = -.infinity
    public var shortTermMax: Double = -.infinity
    public var momentaryMax: Double = -.infinity
    public var range: Double = 0
    public var truePeak: Double = -.infinity
    public var shortTermSeries: [Double] = []
    public var timeline: [Double] = []

    public static let silent = LoudnessResult()
}

public enum LoudnessAnalyzer {
    /// K-weighting: high shelf (+4 dB at 1.68 kHz) then a 38 Hz high-pass.
    static func kWeighting(sampleRate: Double) -> (Biquad, Biquad) {
        if abs(sampleRate - 48000) < 1 {
            var shelf = Biquad()
            shelf.b0 = 1.53512485958697
            shelf.b1 = -2.69169618940638
            shelf.b2 = 1.19839281085285
            shelf.a1 = -1.69065929318241
            shelf.a2 = 0.73248077421585
            var highpass = Biquad()
            highpass.b0 = 1
            highpass.b1 = -2
            highpass.b2 = 1
            highpass.a1 = -1.99004745483398
            highpass.a2 = 0.99007225036621
            return (shelf, highpass)
        }
        return (
            Biquad.highShelf(frequency: 1681.974450955533, gainDB: 3.999843853973347, sampleRate: sampleRate, q: 0.7071752369554196),
            Biquad.highPass(frequency: 38.13547087602444, sampleRate: sampleRate, q: 0.5003270373238773)
        )
    }

    private static func channelWeight(_ speaker: Speaker) -> Double {
        speaker.elevation > 5 || [.lss, .rss, .lrs, .rrs, .ls, .rs].contains(speaker) ? 1.41 : 1.0
    }

    public static func analyze(_ audio: PlanarAudio, layout: ChannelLayout?) -> LoudnessResult {
        let sr = audio.sampleRate
        let frames = audio.frameCount
        guard frames > 0, audio.channelCount > 0 else { return .silent }

        let framesPerBlock = Int(0.4 * sr)
        let (shelf, highpass) = kWeighting(sampleRate: sr)
        let channelCount = audio.channelCount
        let weights: [Double] = (0..<channelCount).map { index in
            guard let layout, index < layout.speakers.count else { return index == 3 ? 0.0 : 1.0 }
            let speaker = layout.speakers[index]
            return speaker.isLFE ? 0.0 : channelWeight(speaker)
        }

        var energy = [Double](repeating: 0, count: frames / max(framesPerBlock, 1) + 1)
        var sampleEnergy = [Double](repeating: 0, count: frames)

        for ch in 0..<channelCount {
            var stage1 = shelf
            var stage2 = highpass
            let s = audio.channels[ch]
            let w = weights[ch]
            for i in 0..<frames {
                let a = stage1.process(s[i])
                let y = stage2.process(a)
                sampleEnergy[i] += w * Double(y) * Double(y)
            }
        }
        var accum: Double = 0
        var blockIndex = 0
        for i in 0..<frames {
            accum += sampleEnergy[i]
            if (i + 1) % framesPerBlock == 0 {
                energy[blockIndex] = accum / Double(framesPerBlock)
                accum = 0
                blockIndex += 1
            }
        }

        // Overlapping 400 ms blocks at 75% overlap, as in BS.1770.
        var result = LoudnessResult()
        var shortTerm: [Double] = []
        var momentary: [Double] = []
        _ = energy
        let hop = max(1, framesPerBlock / 4)
        var start = 0
        while start + framesPerBlock <= frames {
            let blockEnergy = (start..<(start + framesPerBlock)).reduce(0.0) { $0 + sampleEnergy[$1] } / Double(framesPerBlock)
            let loudness = -0.691 + 10 * log10(max(blockEnergy, 1e-12))
            if loudness > -70 { momentary.append(loudness) }
            let shortFrames = Int(3.0 * sr)
            if start + shortFrames <= frames {
                let stEnergy = (start..<(start + shortFrames)).reduce(0.0) { $0 + sampleEnergy[$1] } / Double(shortFrames)
                let st = -0.691 + 10 * log10(max(stEnergy, 1e-12))
                shortTerm.append(st)
            }
            start += hop
        }

        var gated = momentary
        if let maxMomentary = momentary.max() { result.momentaryMax = maxMomentary }
        if let maxShort = shortTerm.max() { result.shortTermMax = maxShort }
        if !gated.isEmpty {
            let absolute = gated.filter { $0 > -70 }
            if !absolute.isEmpty {
                let relativeThreshold = absolute.reduce(0, +) / Double(absolute.count) - 10
                gated = absolute.filter { $0 > relativeThreshold }
            } else {
                gated = []
            }
        }
        if !gated.isEmpty {
            let meanEnergy = gated.map { pow(10, ($0 + 0.691) / 10) }.reduce(0, +) / Double(gated.count)
            result.integrated = -0.691 + 10 * log10(max(meanEnergy, 1e-12))
        }

        let aboveThreshold = shortTerm.filter { $0 > -70 && $0 > (result.integrated - 20) }
        if aboveThreshold.count > 1 {
            let sorted = aboveThreshold.sorted()
            let low = sorted[Int(Double(sorted.count - 1) * 0.10)]
            let high = sorted[Int(Double(sorted.count - 1) * 0.95)]
            result.range = high - low
        }
        result.shortTermSeries = shortTerm

        // Per-second timeline for the analysis graph.
        var perSecond: [Double] = []
        var second = 0
        while second < Int(Double(frames) / sr) {
            let range = (second * Int(sr))..<min(frames, (second + 1) * Int(sr))
            let e = (range).reduce(0.0) { $0 + sampleEnergy[$1] } / Double(max(range.count, 1))
            perSecond.append(-0.691 + 10 * log10(max(e, 1e-12)))
            second += 1
        }
        result.timeline = perSecond
        result.truePeak = truePeak(audio)
        return result
    }

    /// 4× oversampled true-peak estimate using a polyphase windowed-sinc interpolator.
    /// Interpolation is evaluated only around local maxima, which keeps a 10-minute
    /// multichannel file tractable without changing the measurement.
    public static func truePeak(_ audio: PlanarAudio) -> Double {
        let taps = 33
        let phases = 4
        var maxSample: Float = 0
        for ch in 0..<audio.channelCount {
            for v in audio.channels[ch] { maxSample = max(maxSample, abs(v)) }
        }
        guard maxSample > 0 else { return -.infinity }
        let floorLevel = maxSample * 0.35
        for ch in 0..<audio.channelCount {
            let s = audio.channels[ch]
            let n = s.count
            guard n > taps else { continue }
            for i in 0..<n {
                let magnitude = abs(s[i])
                guard magnitude > floorLevel else { continue }
                // Only interpolate candidates that are a local maximum.
                let prev = i > 0 ? abs(s[i - 1]) : 0
                let next = i + 1 < n ? abs(s[i + 1]) : 0
                guard magnitude >= prev, magnitude >= next else { continue }
                for phase in 1..<phases {
                    let frac = Double(phase) / Double(phases)
                    var acc = 0.0
                    for k in 0..<taps {
                        let idx = i - taps / 2 + k
                        guard idx >= 0, idx < n else { continue }
                        let t = Double(k - taps / 2) - frac
                        let sinc = t == 0 ? 1.0 : sin(.pi * t) / (.pi * t)
                        let window = 0.54 + 0.46 * cos(.pi * t / Double(taps / 2))
                        let coeff = sinc * (abs(t) < Double(taps / 2) ? window : 0)
                        acc += Double(s[idx]) * coeff
                    }
                    maxSample = max(maxSample, Float(abs(acc)))
                }
            }
        }
        return 20 * log10(Double(maxSample))
    }
}

/// Lightweight real-time level metering state for the UI.
public final class LevelMeterState {
    public struct Snapshot: Sendable {
        public init() {}
        public var rmsDB: [Double] = []
        public var peakDB: [Double] = []
        public var heldPeakDB: [Double] = []
        public var integratedDB: Double = -.infinity
        public var shortTermDB: Double = -.infinity
        public var truePeakDB: Double = -.infinity
        public var clip: Bool = false
    }

    private var sumSquares: [Double]
    private var frames: Int = 0
    private var held: [Double]
    private var energy: Double = 0
    private var energyFrames: Int = 0
    private var window: [(Double, Double)] = []
    public private(set) var snapshot = Snapshot()

    public init(channelCount: Int) {
        sumSquares = Array(repeating: 0, count: channelCount)
        held = Array(repeating: -.infinity, count: channelCount)
        snapshot.rmsDB = Array(repeating: -.infinity, count: channelCount)
        snapshot.peakDB = Array(repeating: -.infinity, count: channelCount)
        snapshot.heldPeakDB = Array(repeating: -.infinity, count: channelCount)
    }

    public func reset() {
        sumSquares = Array(repeating: 0, count: sumSquares.count)
        held = Array(repeating: -.infinity, count: held.count)
        energy = 0
        energyFrames = 0
        window.removeAll()
        snapshot = Snapshot()
        snapshot.rmsDB = Array(repeating: -.infinity, count: sumSquares.count)
        snapshot.peakDB = Array(repeating: -.infinity, count: sumSquares.count)
        snapshot.heldPeakDB = Array(repeating: -.infinity, count: sumSquares.count)
    }

    public func process(_ channels: [[Float]], frames: Int) {
        guard frames > 0 else { return }
        var peak: [Double] = Array(repeating: 0, count: sumSquares.count)
        for ch in 0..<min(channels.count, sumSquares.count) {
            var ss = 0.0
            var pk = 0.0
            for i in 0..<min(frames, channels[ch].count) {
                let v = Double(channels[ch][i])
                ss += v * v
                pk = max(pk, abs(v))
            }
            sumSquares[ch] = ss / Double(frames)
            peak[ch] = pk
            let db = pk > 0 ? 20 * log10(pk) : -.infinity
            held[ch] = max(held[ch], db)
        }
        let rmsDB = sumSquares.map { $0 > 0 ? 10 * log10($0) : -.infinity }
        snapshot.rmsDB = rmsDB
        snapshot.peakDB = peak.map { $0 > 0 ? 20 * log10($0) : -.infinity }
        snapshot.heldPeakDB = held
        snapshot.clip = peak.contains { $0 >= 0.999 }

        let blockEnergy = sumSquares.reduce(0, +) / Double(max(sumSquares.count, 1))
        energy += blockEnergy * Double(frames)
        energyFrames += frames
        snapshot.integratedDB = energyFrames > 0 && energy > 0 ? -0.691 + 10 * log10(energy / Double(energyFrames)) : -.infinity
        window.append((blockEnergy, Double(frames)))
        while window.reduce(0, { $0 + $1.1 }) > 3 * 48000 {
            window.removeFirst()
        }
        let windowEnergy = window.reduce(0.0) { $0 + $1.0 * $1.1 } / max(window.reduce(0) { $0 + $1.1 }, 1)
        snapshot.shortTermDB = windowEnergy > 0 ? -0.691 + 10 * log10(windowEnergy) : -.infinity
        snapshot.truePeakDB = held.max() ?? -.infinity
    }
}
