import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import SferaCore
import Synchronization

/// One listening session: a private aggregate device clocked by your headphones/DAC,
/// plus the source (BlackHole, or a process tap on every other app). A single IOProc
/// reads the source, spatialises it and writes the result straight to the headphones.
/// No second thread, no ring buffer, no AVAudioEngine.
final class Session: @unchecked Sendable {
    enum Source: Equatable {
        /// BlackHole: every channel apps play (Atmos as a 9.1.6 bed, 5.1, stereo).
        case loopback(AudioDeviceID)
        /// Process tap: stereo mix of every app except Sfera (no BlackHole needed).
        case tap
    }

    enum Failure: LocalizedError {
        case coreAudio(String, OSStatus)
        case noChannels

        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status): "Couldn't \(step) (Core Audio error \(status))."
            case .noChannels: "The source offered no input channels."
            }
        }
    }

    /// Everything the IOProc touches, owned by the IOProc block.
    private final class Engine: @unchecked Sendable {
        let spatializer: Spatializer
        let channels: Int
        /// First aggregate input stream that belongs to the source.
        let inputStream: Int
        /// Aggregate output streams that belong to the headphones.
        let outputStreams: Int
        let callbacks = Atomic<Int>(0)
        let outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>
        var probe: ProbeRecorder?

        init(spatializer: Spatializer, channels: Int, inputStream: Int, outputStreams: Int) {
            self.spatializer = spatializer
            self.channels = channels
            self.inputStream = inputStream
            self.outputStreams = outputStreams
            outL = .allocate(capacity: spatializer.maxFrames)
            outR = .allocate(capacity: spatializer.maxFrames)
        }

        deinit { outL.deallocate(); outR.deallocate() }

        func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
            callbacks.add(1, ordering: .relaxed)
            var one: Float = 1
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outs = UnsafeMutableAudioBufferListPointer(output)
            guard outs.count > 0, let first = outs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let outStride = Int(max(1, outs[0].mNumberChannels))
            let total = Int(outs[0].mDataByteSize) / (outStride * MemoryLayout<Float>.size)

            // Source buffer: usually one interleaved stream.
            var src: UnsafeMutablePointer<Float>?
            var srcStride = 1, srcFrames = 0
            if ins.count > inputStream, let data = ins[inputStream].mData {
                src = data.assumingMemoryBound(to: Float.self)
                srcStride = Int(max(1, ins[inputStream].mNumberChannels))
                srcFrames = Int(ins[inputStream].mDataByteSize) / (srcStride * MemoryLayout<Float>.size)
            }
            // A second non-interleaved stream carries R when the source is planar.
            var planarRight: UnsafeMutablePointer<Float>?
            if srcStride == 1, ins.count > inputStream + 1 {
                planarRight = ins[inputStream + 1].mData?.assumingMemoryBound(to: Float.self)
            }

            let sp = spatializer
            var done = 0
            while done < total {
                let n = min(total - done, sp.maxFrames)
                for ch in 0..<channels {
                    let dst = sp.inputs[ch]
                    if let src, done + n <= srcFrames {
                        if ch < srcStride {
                            vDSP_vsmul(src + (done * srcStride + ch), srcStride, &one, dst, 1, vDSP_Length(n))
                        } else if ch == 1, let planarRight {
                            dst.update(from: planarRight + done, count: n)
                        } else if ch == 1 {
                            dst.update(from: sp.inputs[0], count: n)     // mono → both sides
                        } else {
                            vDSP_vclr(dst, 1, vDSP_Length(n))
                        }
                    } else {
                        vDSP_vclr(dst, 1, vDSP_Length(n))
                    }
                }
                probe?.record(sp.inputs, frames: n)
                sp.process(frames: n, outL: outL, outR: outR)

                // Headphones: L/R into the first stream (interleaved), or two planar streams.
                let base = first + done * outStride
                if outStride >= 2 {
                    if outStride > 2 { vDSP_vclr(base, 1, vDSP_Length(n * outStride)) }
                    vDSP_vsmul(outL, 1, &one, base, outStride, vDSP_Length(n))
                    vDSP_vsmul(outR, 1, &one, base + 1, outStride, vDSP_Length(n))
                } else if outputStreams >= 2, let right = outs[1].mData?.assumingMemoryBound(to: Float.self) {
                    base.update(from: outL, count: n)
                    (right + done).update(from: outR, count: n)
                } else {
                    var half: Float = 0.5
                    vDSP_vasm(outL, 1, outR, 1, &half, base, 1, vDSP_Length(n))
                }
                done += n
            }
            // Never echo anything back into the loopback.
            if outs.count > outputStreams {
                for i in outputStreams..<outs.count { if let d = outs[i].mData { memset(d, 0, Int(outs[i].mDataByteSize)) } }
            }
        }
    }

    let source: Source
    let output: AudioDeviceID
    let sampleRate: Double
    let channels: Int
    var spatializer: Spatializer { engine.spatializer }
    var callbacks: Int { engine.callbacks.load(ordering: .relaxed) }

    private let engine: Engine
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.sfera.io", qos: .userInteractive)

    /// Builds the device and starts playing. Throws if any step fails (nothing is left behind).
    init(source: Source, output: AudioDeviceID, settings: LiveSettings, probe: ProbeRecorder? = nil) throws {
        self.source = source
        self.output = output
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        guard let outputUID = Devices.uid(output) else { throw Failure.coreAudio("read the output device", -1) }
        var channels = 2
        var tap = AudioObjectID(kAudioObjectUnknown)

        switch source {
        case .loopback(let loop):
            channels = min(Layout.loopback.count, Devices.channels(loop, scope: kAudioObjectPropertyScopeInput))
            guard channels >= 2, let loopUID = Devices.uid(loop) else { throw Failure.noChannels }
            LoopbackLayout.install(on: loop)
            // Same nominal rate on both, so the aggregate only corrects clock drift. Follow
            // the player's rate when the headphones can.
            let wanted = Devices.nominalRate(loop)
            let rate = wanted > 0 && Devices.supports(rate: wanted, device: output) ? wanted : Devices.nominalRate(output)
            Devices.setNominalRate(rate, device: output)
            Devices.setNominalRate(rate, device: loop)
            aggregate[kAudioAggregateDeviceNameKey] = "Sfera"
            aggregate[kAudioAggregateDeviceUIDKey] = "dev.sfera.session.\(UUID().uuidString)"
            // Who clocks the session. A wired DAC does (its output is never resampled) and
            // BlackHole follows it. A Bluetooth headphone's clock is too unsteady for that:
            // after a few seconds the aggregate's read position in BlackHole slides off the
            // part the player writes and Sfera reads silence (seen with WH-1000XM5). There
            // BlackHole clocks it and the headphones follow; the stream is re-encoded anyway.
            let loopbackClocks = Devices.isWireless(output)
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = loopbackClocks ? loopUID : outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: loopbackClocks ? 1 : 0],
                [kAudioSubDeviceUIDKey: loopUID, kAudioSubDeviceDriftCompensationKey: loopbackClocks ? 0 : 1],
            ]

        case .tap:
            let own = Devices.processObject(pid: getpid())
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
            description.name = "Sfera"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            let status = AudioHardwareCreateProcessTap(description, &tap)
            guard status == noErr else { throw Failure.coreAudio("create the audio tap", status) }
            aggregate[kAudioAggregateDeviceNameKey] = "Sfera"
            aggregate[kAudioAggregateDeviceUIDKey] = "dev.sfera.session.\(UUID().uuidString)"
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
            aggregate[kAudioAggregateDeviceTapAutoStartKey] = true
            aggregate[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]]
        }

        var device = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard created == noErr else {
            if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
            throw Failure.coreAudio("create Sfera's audio device", created)
        }
        self.channels = channels
        sampleRate = Devices.nominalRate(device) > 0 ? Devices.nominalRate(device) : Devices.nominalRate(output)
        tapID = tap
        aggregateID = device

        // The headphones' own inputs (a headset mic) come first; they stay closed.
        let skipIn = Devices.streamCount(output, scope: kAudioObjectPropertyScopeInput)
        let ownOut = max(1, Devices.streamCount(output, scope: kAudioObjectPropertyScopeOutput))
        let spatializer = Spatializer(sampleRate: sampleRate, channels: channels, settings: settings, maxFrames: 4096)
        engine = Engine(spatializer: spatializer, channels: channels, inputStream: skipIn, outputStreams: ownOut)
        engine.probe = probe

        let engine = self.engine
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, output, _ in
            engine.render(input: input, output: output)
        }
        do {
            guard status == noErr, let proc else { throw Failure.coreAudio("attach to the audio device", status) }
            procID = proc
            Self.setStreamUsage(device, proc: proc, scope: kAudioObjectPropertyScopeInput) { $0 >= skipIn }
            Self.setStreamUsage(device, proc: proc, scope: kAudioObjectPropertyScopeOutput) { $0 < ownOut }
            let started = AudioDeviceStart(device, proc)
            guard started == noErr else { throw Failure.coreAudio("start playing", started) }
        } catch {
            teardown()
            throw error
        }
    }

    deinit { teardown() }

    func update(_ settings: LiveSettings) { engine.spatializer.update(settings) }

    func stop() { teardown() }

    private func teardown() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Switches streams on or off for this IOProc only (kAudioDevicePropertyIOProcStreamUsage),
    /// so unused hardware inputs never start and nothing is written to the loopback.
    private static func setStreamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID,
                                       scope: AudioObjectPropertyScope, on: (Int) -> Bool) {
        let total = Devices.streamCount(device, scope: scope)
        guard total > 0, (0..<total).contains(where: { !on($0) }) else { return }
        var address = Devices.address(kAudioDevicePropertyIOProcStreamUsage, scope)
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + max(0, total - 1) * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(total)
        let flags = raw.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!)
            .assumingMemoryBound(to: UInt32.self)
        for i in 0..<total { flags[i] = on(i) ? 1 : 0 }
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), raw)
    }
}

/// Records the first seconds of a session's input (probes only).
final class ProbeRecorder: @unchecked Sendable {
    let channels: Int, capacity: Int
    let data: [UnsafeMutablePointer<Float>]
    private let position = Atomic<Int>(0)

    init(channels: Int, frames: Int) {
        self.channels = channels
        capacity = frames
        data = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(repeating: 0, count: frames)
            return p
        }
    }

    deinit { data.forEach { $0.deallocate() } }

    var frames: Int { position.load(ordering: .acquiring) }

    func record(_ inputs: [UnsafeMutablePointer<Float>], frames n: Int) {
        let at = position.load(ordering: .relaxed)
        let count = min(n, capacity - at)
        guard count > 0 else { return }
        for ch in 0..<min(channels, inputs.count) { (data[ch] + at).update(from: inputs[ch], count: count) }
        position.store(at + count, ordering: .releasing)
    }
}
