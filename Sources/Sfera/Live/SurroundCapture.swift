import CoreAudio
import Foundation
import SpatialCore
import Synchronization

/// Reads every channel apps play into a loopback device (BlackHole 16ch): Apple Music's
/// Dolby Atmos as a 9.1.6 bed, a video player's 5.1, or plain stereo.
///
/// The loopback and the real output (your DAC/headphones) sit in one private aggregate
/// device clocked by the output, with drift compensation on the loopback, so the capture
/// ring and Sfera's output run on the same clock and never slip. The output's own inputs
/// (a headset microphone) are switched off for this IOProc.
final class SurroundCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        case noChannels

        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status):
                "Couldn't \(step) (Core Audio error \(status)). Check that Sfera is allowed under System Settings › Privacy & Security › Microphone. macOS counts BlackHole as a microphone; nothing is recorded."
            case .noChannels:
                "BlackHole didn't offer any input channels."
            }
        }
    }

    private(set) var ring = AudioRingBuffer(channels: 16)
    private(set) var sampleRate: Double = 48000
    private(set) var channelCount = 16
    private(set) var layout = SpatialDiagnostics.loopbackLayout
    private final class Counter: @unchecked Sendable { let value = Atomic<Int>(0) }
    private let counter = Counter()
    var callbacks: Int { counter.value.load(ordering: .relaxed) }

    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.sfera.surround", qos: .userInteractive)

    /// Rate both devices should run at: the loopback's (what the player chose) if the
    /// output can follow it, else the output's.
    static func pipelineRate(loopback: AudioDeviceID, output: AudioDeviceID) -> Double {
        let source = AudioDevices.nominalRate(loopback)
        if source > 0, AudioDevices.supports(rate: source, device: output) { return source }
        return AudioDevices.nominalRate(output)
    }

    func start(loopback: AudioDeviceID, output: AudioDeviceID) throws {
        stop()
        let channels = min(16, AudioDevices.channels(loopback, scope: kAudioObjectPropertyScopeInput))
        guard channels >= 2 else { throw CaptureError.noChannels }
        channelCount = channels
        layout = ChannelLayout(name: channels >= 16 ? "9.1.6" : "\(channels)ch", speakers: LoopbackLayout.speakers(count: channels))
        LoopbackLayout.install(on: loopback)

        // Same nominal rate on both, so the aggregate only corrects clock drift.
        let rate = Self.pipelineRate(loopback: loopback, output: output)
        AudioDevices.setNominalRate(rate, device: output)
        AudioDevices.setNominalRate(rate, device: loopback)
        sampleRate = rate

        guard let outputUID = AudioDevices.uid(output), let loopUID = AudioDevices.uid(loopback) else {
            throw CaptureError.coreAudio("read the device IDs", -1)
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sfera surround",
            kAudioAggregateDeviceUIDKey: "dev.sfera.surround.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
                [kAudioSubDeviceUIDKey: loopUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &device), "create the surround device")
        aggregateID = device

        // Input streams: the output device's (skipped) come first, then the loopback's.
        let skip = SystemAudioCapture.streamCount(output, scope: kAudioObjectPropertyScopeInput)
        let ring = AudioRingBuffer(channels: channels, capacity: 1 << 15, targetFrames: 2048)
        ring.maxFrames = 8192
        self.ring = ring
        let counter = self.counter
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, input, _, _, _ in
            counter.value.add(1, ordering: .relaxed)
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard buffers.count > skip else { return }
            let first = buffers[skip]
            guard let data = first.mData else { return }
            let stride = Int(max(1, first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / (stride * MemoryLayout<Float>.size)
            if stride >= channels || buffers.count - skip == 1 {
                ring.write(interleaved: data.assumingMemoryBound(to: Float.self), stride: stride, frames: frames)
            } else if stride == 1, let right = buffers[min(skip + 1, buffers.count - 1)].mData {
                // Non-interleaved streams (unusual for BlackHole): keep L/R at least.
                ring.write(left: data.assumingMemoryBound(to: Float.self), right: right.assumingMemoryBound(to: Float.self), frames: frames)
            }
        }
        do {
            try check(status, "attach to BlackHole")
            ioProcID = procID
            if skip > 0, let procID {
                SystemAudioCapture.disableInputStreams(device, procID: procID, first: skip)
            }
            try check(AudioDeviceStart(device, procID), "start reading BlackHole")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        counter.value.store(0, ordering: .relaxed)
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw CaptureError.coreAudio(step, status) }
    }
}
