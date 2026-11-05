import Foundation

/// What `LiveOutput` drives on the render thread.
public protocol LiveProcessor: AnyObject {
    var sampleRate: Double { get }
    var maxFrames: Int { get }
    /// Planar input buffers the provider fills (`maxFrames` each).
    var inputs: [UnsafeMutablePointer<Float>] { get }
    /// Input → output delay in samples.
    var latency: Int { get }
    var inputPeak: Float { get }
    var outputPeakL: Float { get }
    var outputPeakR: Float { get }
    var limiterReductionDB: Float { get }
    func update(_ settings: LiveSettings)
    func process(frames: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>)
}

extension LiveSpatializer: LiveProcessor {}

/// For a multichannel loopback input (BlackHole) whose content changes with the track:
/// a stereo song arrives on channels 1–2 only, an Atmos track or a 5.1 film fills the bed.
///
/// Runs the stereo upmix path and the bed path side by side, time-aligned, and crossfades
/// to whichever matches what is arriving. Surround is held for `holdSeconds` after the
/// last non-L/R signal so quiet passages in a surround mix don't flip to the upmix.
public final class AdaptiveSpatializer: LiveProcessor {
    public let sampleRate: Double
    public let maxFrames: Int
    public let inputLayout: ChannelLayout
    public let inputs: [UnsafeMutablePointer<Float>]
    public let latency: Int

    public var inputPeak: Float { bed.inputPeak }
    public private(set) var outputPeakL: Float = 0
    public private(set) var outputPeakR: Float = 0
    public var limiterReductionDB: Float { min(stereo.limiterReductionDB, bed.limiterReductionDB) }

    /// True while the bed path is selected (non-L/R channels carry signal).
    public var surroundActive: Bool { surround }
    /// Bit i set while input channel i carried signal within the hold window.
    public var activeChannels: UInt32 { activeMask }

    public static let threshold: Float = 1e-4          // −80 dBFS
    public static let holdSeconds = 3.0

    private let stereo: LiveSpatializer
    private let bed: LiveSpatializer
    private let bedDelay: Int
    private let delayL: UnsafeMutablePointer<Float>, delayR: UnsafeMutablePointer<Float>
    private let delayMask: Int
    private var delayWrite = 0
    private let scratch: [UnsafeMutablePointer<Float>]   // stereoL, stereoR, bedL, bedR
    private var weight: Float = 0
    private let fadeCoef: Float
    private var surround = false
    private var activeMask: UInt32 = 0
    private var lastActive: [Int]
    private var clock = 0
    private let holdFrames: Int

    public init(sampleRate: Double, inputLayout: ChannelLayout, settings: LiveSettings = LiveSettings(), maxFrames: Int = 4096) {
        precondition(inputLayout.channelCount > 2 && inputLayout.channelCount <= 32)
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        self.inputLayout = inputLayout
        bed = LiveSpatializer(sampleRate: sampleRate, inputLayout: inputLayout, settings: settings, maxFrames: maxFrames)
        stereo = LiveSpatializer(sampleRate: sampleRate, inputLayout: .stereo, settings: settings, maxFrames: maxFrames)
        inputs = bed.inputs
        latency = max(stereo.latency, bed.latency)
        bedDelay = latency - bed.latency
        var size = 1
        while size < bedDelay + maxFrames + 1 { size <<= 1 }
        delayMask = size - 1
        delayL = .allocate(capacity: size); delayL.initialize(repeating: 0, count: size)
        delayR = .allocate(capacity: size); delayR.initialize(repeating: 0, count: size)
        scratch = (0..<4).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            p.initialize(repeating: 0, count: maxFrames)
            return p
        }
        fadeCoef = Float(1 - exp(-1 / (0.05 * sampleRate)))
        holdFrames = Int(Self.holdSeconds * sampleRate)
        lastActive = Array(repeating: -Int(Self.holdSeconds * sampleRate) - 1, count: inputLayout.channelCount)
    }

    deinit {
        delayL.deallocate(); delayR.deallocate()
        scratch.forEach { $0.deallocate() }
    }

    public func update(_ settings: LiveSettings) {
        stereo.update(settings)
        bed.update(settings)
    }

    public func process(frames: Int, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        let frames = min(frames, maxFrames)
        // What is arriving on each channel.
        var mask: UInt32 = 0
        for ch in 0..<inputs.count {
            let x = inputs[ch]
            var peak: Float = 0
            for i in 0..<frames { peak = max(peak, abs(x[i])) }
            if peak > Self.threshold { lastActive[ch] = clock }
            if clock - lastActive[ch] <= holdFrames { mask |= 1 << UInt32(ch) }
        }
        activeMask = mask
        surround = mask & ~UInt32(0b11) != 0
        clock += frames

        stereo.inputs[0].update(from: inputs[0], count: frames)
        stereo.inputs[1].update(from: inputs[1], count: frames)
        let sL = scratch[0], sR = scratch[1], bL = scratch[2], bR = scratch[3]
        stereo.process(frames: frames, outL: sL, outR: sR)
        bed.process(frames: frames, outL: bL, outR: bR)

        let target: Float = surround ? 1 : 0
        var w = delayWrite
        var pl: Float = 0, pr: Float = 0
        for i in 0..<frames {
            // Delay the bed path so both paths line up.
            delayL[w] = bL[i]; delayR[w] = bR[i]
            let dl = delayL[(w - bedDelay) & delayMask], dr = delayR[(w - bedDelay) & delayMask]
            w = (w + 1) & delayMask
            weight += (target - weight) * fadeCoef
            let l = sL[i] * (1 - weight) + dl * weight
            let r = sR[i] * (1 - weight) + dr * weight
            outL[i] = l; outR[i] = r
            pl = max(pl, abs(l)); pr = max(pr, abs(r))
        }
        delayWrite = w
        outputPeakL = pl
        outputPeakR = pr
    }

    /// Short description of the incoming format from `activeChannels`, for a
    /// 9.1.6 loopback bed (L R C LFE Ls Rs Lrs Rrs Lw Rw Ltf Rtf Ts Cfh Ltr Rtr).
    public static func describe(activeChannels mask: UInt32, layout: ChannelLayout) -> String {
        func active(_ speakers: [Speaker]) -> Bool {
            speakers.contains { s in layout.index(of: s).map { mask & (1 << UInt32($0)) != 0 } ?? false }
        }
        if active([.ltf, .rtf, .ltm, .rtm, .ltr, .rtr, .cts, .cfh]) { return "Atmos" }
        if active([.lrs, .rrs, .lw, .rw]) { return "7.1" }
        if active([.lss, .rss, .ls, .rs]) { return "5.1" }
        if active([.c, .lfe]) { return "3.1" }
        return "Stereo"
    }
}
