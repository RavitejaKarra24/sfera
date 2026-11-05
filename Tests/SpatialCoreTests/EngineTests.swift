import Foundation
import Testing
@testable import SpatialCore

private func sine(_ frequency: Double, seconds: Double, sampleRate: Double = 48000, amplitude: Float = 0.5) -> [Float] {
    let frames = Int(seconds * sampleRate)
    return (0..<frames).map { Float(Double(amplitude) * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

private func energy(_ samples: [Float]) -> Double {
    samples.reduce(0.0) { $0 + Double($1) * Double($1) }
}

private func settings() -> RenderSettings {
    RenderSettings(limiter: LimiterSettings(), sampleRate: 48000)
}

@Test func waveRoundTripPreservesLayoutAndAudio() throws {
    let bed = ChannelLayout.named("7.1.4")!
    let frames = 4800
    var audio = PlanarAudio(silenceChannels: bed.channelCount, frames: frames, sampleRate: 48000)
    for ch in 0..<bed.channelCount {
        for i in 0..<frames { audio.channels[ch][i] = Float(sin(Double(i + ch) * 0.01)) * 0.3 }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try WaveWriter.write(audio, to: url, bitDepth: .float32, layout: bed)
    let read = try WaveReader.read(url: url)
    #expect(read.audio.channelCount == bed.channelCount)
    #expect(read.layout?.name == "7.1.4")
    #expect(read.audio.frameCount == frames)
    for ch in 0..<bed.channelCount {
        let delta = zip(read.audio.channels[ch], audio.channels[ch]).map { abs($0 - $1) }.max() ?? 0
        #expect(delta < 0.0001)
    }
}

@Test func binauralPanningFavoursIpsilateralEar() {
    for (x, expectedBias) in [(0.9, "right"), (-0.9, "left")] {
        let source = RenderSource(
            id: 1,
            name: "Object",
            kind: .object,
            audio: sine(440, seconds: 0.5),
            keyframes: [ObjectKeyframe(time: 0, position: SpatialPoint(x: x, y: 0, z: 0.15), size: 0)],
            distance: .off
        )
        let (audio, stats) = BinauralRenderer.render(sources: [source], frames: source.audio.count, settings: settings())
        #expect(stats.renderedObjects == 1)
        let left = energy(audio.channels[0])
        let right = energy(audio.channels[1])
        #expect(max(left, right) > 0)
        if expectedBias == "right" {
            #expect(right > left * 1.05)
        } else {
            #expect(left > right * 1.05)
        }
    }
}

@Test func binauralCreatesInterauralTimeDifference() {
    let source = RenderSource(
        id: 1,
        name: "Click",
        kind: .object,
        audio: { var a = [Float](repeating: 0, count: 2048); a[64] = 1; return a }(),
        keyframes: [ObjectKeyframe(time: 0, position: SpatialPoint(x: 0.95, y: 0, z: 0.1), size: 0)],
        distance: .off
    )
    let (audio, _) = BinauralRenderer.render(sources: [source], frames: 2048, settings: settings())
    let l = audio.channels[0]
    let r = audio.channels[1]
    let leftPeak = l.enumerated().max { abs($0.element) < abs($1.element) }!.offset
    let rightPeak = r.enumerated().max { abs($0.element) < abs($1.element) }!.offset
    #expect(rightPeak < leftPeak, "right ear should lead for a right-side source")
}

@Test func limiterRespectsCeiling() {
    var audio = PlanarAudio(silenceChannels: 2, frames: 4800, sampleRate: 48000)
    let loud = sine(220, seconds: 0.1, amplitude: 2.0)
    audio.channels[0] = loud
    audio.channels[1] = loud
    var config = LimiterSettings()
    config.ceilingDB = -0.3
    let (out, _) = LookaheadLimiter.process(audio, settings: config)
    #expect(out.peak() <= Float(pow(10, -0.3 / 20)) + 0.001)
}

@Test func loudnessMeasuresSinusoidCloseToItsLevel() {
    var audio = PlanarAudio(silenceChannels: 2, frames: Int(48000 * 5), sampleRate: 48000)
    let tone = sine(1000, seconds: 5, amplitude: Float(pow(10, -20.0 / 20.0)))
    audio.channels[0] = tone
    audio.channels[1] = tone
    let result = LoudnessAnalyzer.analyze(audio, layout: .stereo)
    #expect(abs(result.integrated - -20.0) < 1.5)
    #expect(result.truePeak > -21 && result.truePeak < -18)
}

@Test func importingMultichannelWavBuildsBedSources() throws {
    let bed = ChannelLayout.named("7.1.4")!
    let audio = PlanarAudio(
        sampleRate: 48000,
        channels: (0..<bed.channelCount).map { ch in sine(200 + Double(ch) * 40, seconds: 0.25) }
    )
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try WaveWriter.write(audio, to: url, bitDepth: .float32, layout: bed)
    let media = try MediaImporter.load(url: url)
    #expect(media.sources.count == bed.channelCount)
    #expect(media.kind == .multichannel)
    #expect(media.layout?.name == "7.1.4")
    #expect(media.frames == audio.frameCount)
}

@Test func limiterLeavesQuietSignalTransparent() {
    var audio = PlanarAudio(silenceChannels: 2, frames: 4800, sampleRate: 48000)
    audio.channels[0] = sine(440, seconds: 0.1, amplitude: 0.25)
    audio.channels[1] = audio.channels[0]
    let (out, reduction) = LookaheadLimiter.process(audio, settings: LimiterSettings())
    #expect(reduction == 0)
    let delta = zip(out.channels[0], audio.channels[0]).map { abs($0 - $1) }.max() ?? 0
    #expect(delta < 0.001)
}

@Test func silenceHasNoLoudness() {
    let audio = PlanarAudio(silenceChannels: 2, frames: 48000, sampleRate: 48000)
    let result = LoudnessAnalyzer.analyze(audio, layout: .stereo)
    #expect(result.integrated == -.infinity || result.integrated < -70)
    #expect(result.truePeak == -.infinity)
}

// MARK: - Stereo → spatial, binaural room, 24-bit I/O, adaptive surround

@Test func spatialDiagnosticsPass() {
    let report = SpatialDiagnostics.run(sampleRate: 48000)
    #expect(report.failures.isEmpty, "\(report.failures)")
}

@Test func twentyFourBitWaveReadsAtUnityGain() throws {
    var audio = PlanarAudio(silenceChannels: 2, frames: 4800, sampleRate: 48000)
    audio.channels[0] = sine(1000, seconds: 0.1, amplitude: 0.5)
    audio.channels[1] = sine(500, seconds: 0.1, amplitude: -0.25)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcm24-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try WaveWriter.write(audio, to: url, bitDepth: .pcm24, layout: .stereo)
    let read = try WaveReader.read(url: url)
    for ch in 0..<2 {
        let delta = zip(read.audio.channels[ch], audio.channels[ch]).map { abs($0 - $1) }.max() ?? 1
        #expect(delta < 1e-5)
    }
}

@Test func binauralOffModeIsPlainStereoPan() {
    let source = RenderSource(id: 1, name: "s", kind: .object, audio: sine(500, seconds: 0.2),
                              keyframes: [ObjectKeyframe(time: 0, position: SpatialPoint(x: 1, y: 0, z: 0), size: 0)],
                              distance: .off)
    var s = settings()
    s.limiter.enabled = false
    let (out, _) = SpatialEngine.render(sources: [source], frames: 9600, settings: s)
    // Hard right, no HRTF and no room: nothing in the left ear.
    #expect(energy(out.channels[0]) < 1e-6)
    #expect(energy(out.channels[1]) > 1)
}

@Test func upmixTurnsStereoIntoA704Bed() {
    let (left, right) = SpatialDiagnostics.testStereo(seconds: 2)
    let bed = Upmixer.upmix(left: left, right: right, sampleRate: 48000)
    #expect(bed.count == 11)
    #expect(bed.values.allSatisfy { $0.count == left.count })
    #expect(bed[.ltf] != nil && bed[.rtr] != nil && bed[.c] != nil)
    #expect(bed[.lfe] == nil)
}

@Test func adaptiveSpatializerFollowsWhatArrives() {
    let layout = SpatialDiagnostics.loopbackLayout
    let adaptive = AdaptiveSpatializer(sampleRate: 48000, inputLayout: layout, maxFrames: 512)
    let outL = UnsafeMutablePointer<Float>.allocate(capacity: 512); defer { outL.deallocate() }
    let outR = UnsafeMutablePointer<Float>.allocate(capacity: 512); defer { outR.deallocate() }
    var rng = SplitMix64(seed: 7)
    func block(active: [Speaker]) {
        for (ch, speaker) in layout.speakers.enumerated() {
            for i in 0..<512 { adaptive.inputs[ch][i] = active.contains(speaker) ? Float(rng.nextUniform() - 0.5) * 0.2 : 0 }
        }
        adaptive.process(frames: 512, outL: outL, outR: outR)
    }
    for _ in 0..<20 { block(active: [.l, .r]) }
    #expect(!adaptive.surroundActive)
    #expect(AdaptiveSpatializer.describe(activeChannels: adaptive.activeChannels, layout: layout) == "Stereo")
    for _ in 0..<20 { block(active: [.l, .r, .c, .lss, .rss]) }
    #expect(adaptive.surroundActive)
    #expect(AdaptiveSpatializer.describe(activeChannels: adaptive.activeChannels, layout: layout) == "5.1")
    block(active: [.l, .r, .ltf])
    #expect(AdaptiveSpatializer.describe(activeChannels: adaptive.activeChannels, layout: layout) == "Atmos")
}
