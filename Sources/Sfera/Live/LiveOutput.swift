import AVFoundation
import CoreAudio
import Foundation
import os
import SpatialCore
import Synchronization

/// Real-time output: an AVAudioEngine source node that pulls input from a provider,
/// runs it through `LiveSpatializer`, and plays binaural stereo on the default output.
final class LiveOutput: @unchecked Sendable {
    /// Fills the spatializer's planar `inputs` with `frames` samples.
    typealias Provider = (_ inputs: [UnsafeMutablePointer<Float>], _ frames: Int) -> Void

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private(set) var spatializer: (any LiveProcessor)?
    /// The device Sfera plays to (nil = system default).
    private(set) var device: AudioDeviceID?
    private var configObserver: NSObjectProtocol?
    /// Render-thread probe of the playing item's next frame. When set, each callback that
    /// delivers a full buffer records which frame left at which host time (`clockPoint`).
    var frameClock: (@Sendable () -> Int)?

    struct ClockPoint: Sendable {
        var hostTime: UInt64 = 0
        var frame = 0
        var valid = false
    }
    private let clock = OSAllocatedUnfairLock(initialState: ClockPoint())
    private var deviceLatencySeconds: Double = 0
    /// Called on the main queue when the output device changes and the engine stopped.
    var onConfigurationChange: (() -> Void)?

    var isRunning: Bool { engine.isRunning }
    /// The device the engine is actually playing to.
    var deviceID: AudioDeviceID { engine.outputNode.auAudioUnit.deviceID }

    /// Name of the device the engine is actually playing to.
    var deviceName: String {
        engine.isInManualRenderingMode ? "offline" : AudioDevices.name(engine.outputNode.auAudioUnit.deviceID)
    }

    /// Seconds from a sample leaving the spatializer's input to reaching the ears, beyond
    /// the IO cycle itself: look-ahead plus the device and stream latency Core Audio reports
    /// (Bluetooth headphones report their large buffering here).
    var totalLatency: Double {
        guard let spatializer else { return 0 }
        return Double(spatializer.latency) / spatializer.sampleRate + deviceLatencySeconds
    }

    /// The item time (seconds) being heard at `hostTime`, from the last full render cycle.
    func audibleTime(atHostTime hostTime: UInt64) -> Double? {
        guard let spatializer else { return nil }
        let point = clock.withLock { $0 }
        guard point.valid else { return nil }
        let delta = HostClock.seconds(from: point.hostTime, to: hostTime)
        return Double(point.frame) / spatializer.sampleRate - totalLatency + delta
    }

    func resetClock() {
        clock.withLock { $0 = ClockPoint() }
    }

    /// Builds the chain for `layout` at `sampleRate` and starts playback.
    /// `adaptive`: the input may be stereo or a surround bed (loopback) — switch per content.
    /// `device`: play to this device instead of the system default.
    func start(sampleRate: Double, layout: ChannelLayout, settings: LiveSettings, adaptive: Bool = false,
               device: AudioDeviceID? = nil, provider: @escaping Provider) throws {
        stop()
        let spatializer: any LiveProcessor = adaptive && layout.channelCount > 2
            ? AdaptiveSpatializer(sampleRate: sampleRate, inputLayout: layout, settings: settings, maxFrames: 4096)
            : LiveSpatializer(sampleRate: sampleRate, inputLayout: layout, settings: settings, maxFrames: 4096)
        self.spatializer = spatializer
        self.device = device
        // The engine is reused: point it back at the default output when no device is given.
        if !engine.isInManualRenderingMode, let target = device ?? AudioDevices.defaultOutput(),
           engine.outputNode.auAudioUnit.deviceID != target {
            try engine.outputNode.auAudioUnit.setDeviceID(target)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw MediaError.unsupported("output format \(sampleRate) Hz")
        }
        let inputs = spatializer.inputs
        let maxFrames = spatializer.maxFrames
        let frameClock = self.frameClock
        let clock = self.clock
        resetClock()
        let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let total = Int(frameCount)
            let before = frameClock?() ?? 0
            var done = 0
            while done < total {
                let count = min(total - done, maxFrames)
                provider(inputs, count)
                spatializer.process(frames: count, outL: left.advanced(by: done), outR: right.advanced(by: done))
                done += count
            }
            // Only a cycle that played `total` real frames pins the clock (not priming/pause).
            if let frameClock, frameClock() - before == total,
               timestamp.pointee.mFlags.contains(.hostTimeValid) {
                let point = ClockPoint(hostTime: timestamp.pointee.mHostTime, frame: before, valid: true)
                clock.withLockIfAvailable { $0 = point }
            }
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        try engine.start()
        deviceLatencySeconds = engine.isInManualRenderingMode ? 0 : Self.outputLatency(of: engine.outputNode.auAudioUnit.deviceID)
        engine.mainMixerNode.outputVolume = 1

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigurationChange?() }
    }

    func update(_ settings: LiveSettings) {
        spatializer?.update(settings)
    }

    /// Device + first output stream latency in seconds (what follows the IO timestamp).
    static func outputLatency(of device: AudioDeviceID) -> Double {
        func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32 {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
        }
        guard device != kAudioObjectUnknown else { return 0 }
        var rate: Float64 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return 0 }
        var frames = read(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput)
        // First output stream's own latency.
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        size = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let first = streams.first {
                frames += read(first, kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal)
            }
        }
        return Double(frames) / rate
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.stop()
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        sourceNode = nil
        spatializer = nil
        resetClock()
    }

    /// Headless verification: pulls `frames` through the same graph in offline manual
    /// rendering mode (no device needed) and returns the engine's output.
    func renderOffline(sampleRate: Double, layout: ChannelLayout, settings: LiveSettings, frames: Int, provider: @escaping Provider) throws -> PlanarAudio {
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw MediaError.unsupported("format")
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        defer { engine.disableManualRenderingMode() }
        try start(sampleRate: sampleRate, layout: layout, settings: settings, provider: provider)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            throw MediaError.unsupported("buffer")
        }
        var out = PlanarAudio(silenceChannels: 2, frames: frames, sampleRate: sampleRate)
        var position = 0
        while position < frames {
            let count = AVAudioFrameCount(min(4096, frames - position))
            let status = try engine.renderOffline(count, to: buffer)
            guard status == .success, let data = buffer.floatChannelData else { break }
            for ch in 0..<2 {
                for i in 0..<Int(buffer.frameLength) { out.channels[ch][position + i] = data[ch][i] }
            }
            position += Int(buffer.frameLength)
        }
        stop()
        return out
    }
}

/// A decoded local file, played from memory by the render thread. Seek and pause are
/// lock-free from the main thread.
final class FilePlayback: @unchecked Sendable {
    let channels: [[Float]]
    let frames: Int
    let sampleRate: Double
    let layout: ChannelLayout
    let title: String
    let detail: String
    private let position = Atomic<Int>(0)
    private let playing = Atomic<Bool>(false)
    private let finished = Atomic<Bool>(false)

    init(channels: [[Float]], sampleRate: Double, layout: ChannelLayout, title: String, detail: String) {
        self.channels = channels
        frames = channels.first?.count ?? 0
        self.sampleRate = sampleRate
        self.layout = layout
        self.title = title
        self.detail = detail
    }

    var isPlaying: Bool { playing.load(ordering: .relaxed) }
    var didFinish: Bool { finished.load(ordering: .relaxed) }
    var currentFrame: Int { position.load(ordering: .relaxed) }
    var duration: Double { Double(frames) / sampleRate }

    func setPlaying(_ value: Bool) {
        if value { finished.store(false, ordering: .relaxed) }
        playing.store(value, ordering: .relaxed)
    }

    func seek(to frame: Int) {
        position.store(min(max(0, frame), frames), ordering: .relaxed)
        finished.store(false, ordering: .relaxed)
    }

    /// Render-thread pull.
    func read(into outputs: [UnsafeMutablePointer<Float>], frames count: Int) {
        let start = position.load(ordering: .relaxed)
        let live = playing.load(ordering: .relaxed)
        let available = live ? max(0, min(count, frames - start)) : 0
        for (ch, out) in outputs.enumerated() {
            if available > 0 {
                channels[min(ch, channels.count - 1)].withUnsafeBufferPointer { src in
                    out.update(from: src.baseAddress!.advanced(by: start), count: available)
                }
            }
            for i in available..<count { out[i] = 0 }
        }
        if live {
            position.store(start + available, ordering: .relaxed)
            if start + available >= frames {
                playing.store(false, ordering: .relaxed)
                finished.store(true, ordering: .relaxed)
            }
        }
    }
}

/// mach host time ↔ seconds.
enum HostClock {
    private static let ratio: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    static var now: UInt64 { mach_absolute_time() }

    /// Signed seconds from `a` to `b`.
    static func seconds(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? Double(b - a) * ratio : -Double(a - b) * ratio
    }

    static func adding(_ seconds: Double, to host: UInt64) -> UInt64 {
        let ticks = seconds / ratio
        return ticks >= 0 ? host &+ UInt64(ticks) : host &- UInt64(-ticks)
    }
}
