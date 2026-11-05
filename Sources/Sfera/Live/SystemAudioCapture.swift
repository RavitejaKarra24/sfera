import AudioToolbox
import CoreAudio
import Foundation

/// Captures every app's stereo output (except Sfera's) with a Core Audio process tap.
/// Used when no loopback device (BlackHole) is installed.
///
/// The tap mutes the apps while Sfera reads them (`mutedWhenTapped`), so you hear only
/// the spatialised version; stopping (or quitting Sfera) restores normal playback.
/// The tap feeds a private, tap-only aggregate device whose IOProc pushes stereo into an
/// `AudioRingBuffer`. Your headphones are deliberately *not* part of the aggregate, so
/// a Bluetooth headset's microphone is never opened.
final class SystemAudioCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status):
                "Couldn't \(step) (Core Audio error \(status)). If this keeps happening, allow Sfera under System Settings › Privacy & Security › Screen & System Audio Recording."
            case .unsupportedFormat(let detail):
                "Unsupported capture format: \(detail)"
            }
        }
    }

    let ring = AudioRingBuffer(channels: 2)
    private(set) var sampleRate: Double = 48000
    private(set) var isRunning = false
    /// Number of IOProc callbacks so far (the UI uses it to tell "no permission/no audio" apart).
    private(set) var callbacks = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.sfera.capture", qos: .userInteractive)

    /// `clockFromOutput`: also add the default output device to the aggregate as its clock
    /// source. Its own input streams (e.g. a headset mic) are switched off for our IOProc.
    func start(clockFromOutput: Bool = false) throws {
        stop()
        let own = Self.processObject(pid: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
        description.name = "Sfera live"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the audio tap")
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read the tap format")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            stop()
            throw CaptureError.unsupportedFormat("\(format.mFormatID) / \(format.mBitsPerChannel)-bit")
        }
        sampleRate = format.mSampleRate
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sfera live capture",
            kAudioAggregateDeviceUIDKey: "dev.sfera.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var clockInputStreams = 0
        if clockFromOutput, let output = Self.defaultOutputDevice(), let uid = Self.deviceUID(output) {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = uid
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
            clockInputStreams = Self.streamCount(output, scope: kAudioObjectPropertyScopeInput)
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the capture device")
        } catch {
            stop()
            throw error
        }
        aggregateID = device

        let ring = self.ring
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.callbacks += 1
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard buffers.count > 0 else { return }
            if interleaved || buffers.count == 1 {
                let buffer = buffers[0]
                guard let data = buffer.mData else { return }
                let stride = Int(max(1, buffer.mNumberChannels))
                let frames = Int(buffer.mDataByteSize) / (stride * MemoryLayout<Float>.size)
                ring.write(interleaved: data.assumingMemoryBound(to: Float.self), stride: stride, frames: frames)
            } else {
                let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                let first = buffers[0].mData!.assumingMemoryBound(to: Float.self)
                let second = buffers.count > 1 ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : first
                ring.write(left: first, right: second, frames: frames)
            }
        }
        do {
            try check(status, "attach to the capture device")
            ioProcID = procID
            if clockInputStreams > 0, let procID {
                // Only the tap's stream is used: keep the clock device's microphone closed.
                Self.disableInputStreams(aggregateID, procID: procID, first: clockInputStreams)
            }
            try check(AudioDeviceStart(aggregateID, procID), "start capturing")
        } catch {
            stop()
            throw error
        }
        isRunning = true
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
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
        callbacks = 0
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw CaptureError.coreAudio(step, status) }
    }

    // MARK: Devices

    static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Turns off the first `first` input streams of `device` for one IOProc
    /// (kAudioDevicePropertyIOProcStreamUsage), so unused hardware inputs never start.
    static func disableInputStreams(_ device: AudioObjectID, procID: AudioDeviceIOProcID, first: Int) {
        let total = streamCount(device, scope: kAudioObjectPropertyScopeInput)
        guard total > first else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                                 mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + max(0, total - 1) * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(total)
        let flags = raw.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).assumingMemoryBound(to: UInt32.self)
        for i in 0..<total { flags[i] = i < first ? 0 : 1 }
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), raw)
    }

    // MARK: Process lookup

    static func processObject(pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return object
    }
}
