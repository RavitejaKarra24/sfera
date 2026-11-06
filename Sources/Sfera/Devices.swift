import CoreAudio
import Foundation

/// Core Audio device helpers: lookup, routing, rates, volume, listeners.
enum Devices {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(_ device: AudioDeviceID) -> String { string(device, kAudioObjectPropertyName) ?? "Device \(device)" }
    static func uid(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func device(uid: String) -> AudioDeviceID? { all().first { Self.uid($0) == uid } }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func transport(_ device: AudioDeviceID) -> UInt32 { uint32(device, kAudioDevicePropertyTransportType) ?? 0 }

    static func isAlive(_ device: AudioDeviceID) -> Bool { (uint32(device, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0 }

    static func channels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    // MARK: Kinds

    /// A loopback driver (BlackHole, Loopback): what apps play into it comes back out of
    /// its input, so Sfera can read every channel. Other virtual devices are left alone.
    static func isLoopback(_ device: AudioDeviceID) -> Bool {
        guard transport(device) == kAudioDeviceTransportTypeVirtual else { return false }
        let name = name(device)
        guard name.localizedCaseInsensitiveContains("BlackHole") || name.hasPrefix("Loopback") else { return false }
        return channels(device, scope: kAudioObjectPropertyScopeInput) >= 2
            && channels(device, scope: kAudioObjectPropertyScopeOutput) >= 2
    }

    /// The best loopback for surround: the one with the most channels (BlackHole 16ch).
    static func loopback() -> AudioDeviceID? {
        all().filter(isLoopback).max {
            channels($0, scope: kAudioObjectPropertyScopeInput) < channels($1, scope: kAudioObjectPropertyScopeInput)
        }
    }

    /// Headphones, DACs, speakers.
    static func isPhysicalOutput(_ device: AudioDeviceID) -> Bool {
        let t = transport(device)
        guard t != kAudioDeviceTransportTypeVirtual, t != kAudioDeviceTransportTypeAggregate,
              t != kAudioDeviceTransportTypeUnknown else { return false }
        return channels(device, scope: kAudioObjectPropertyScopeOutput) >= 1
    }

    /// Bluetooth (and AirPlay) outputs: their clock can't drive the session.
    static func isWireless(_ device: AudioDeviceID) -> Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
         kAudioDeviceTransportTypeAirPlay].contains(transport(device))
    }

    static func physicalOutputs() -> [AudioDeviceID] { all().filter(isPhysicalOutput) }

    // MARK: Default output

    static func defaultOutput() -> AudioDeviceID? {
        guard let d = uint32(system, kAudioHardwarePropertyDefaultOutputDevice), d != kAudioObjectUnknown else { return nil }
        return d
    }

    @discardableResult
    static func setDefaultOutput(_ device: AudioDeviceID) -> Bool {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        return AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    // MARK: Rates

    static func nominalRate(_ device: AudioDeviceID) -> Double {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &rate)
        return rate
    }

    static func supports(rate: Double, device: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return false }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &ranges) == noErr else { return false }
        return ranges.contains { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 }
    }

    /// Sets the rate and waits (≤ 1 s) for the device to report it.
    @discardableResult
    static func setNominalRate(_ rate: Double, device: AudioDeviceID) -> Bool {
        if abs(nominalRate(device) - rate) < 0.5 { return true }
        guard supports(rate: rate, device: device) else { return false }
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        guard AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr else { return false }
        for _ in 0..<50 {
            if abs(nominalRate(device) - rate) < 0.5 { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return abs(nominalRate(device) - rate) < 0.5
    }

    // MARK: Volume

    static func volumeDB(_ device: AudioDeviceID) -> Double? {
        var a = address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    static func volumeScalar(_ device: AudioDeviceID) -> Float32? {
        var a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Sets the volume slider (0…1) and unmutes, on every scope that has the controls.
    /// A loopback's volume scales what it carries (BlackHole: linear in dB, 50 % = −32 dB).
    static func setVolume(_ scalar: Float32, unmute device: AudioDeviceID) {
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            var v = address(kAudioDevicePropertyVolumeScalar, scope)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &v), AudioObjectIsPropertySettable(device, &v, &settable) == noErr, settable.boolValue {
                var value = scalar
                AudioObjectSetPropertyData(device, &v, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            }
            var m = address(kAudioDevicePropertyMute, scope)
            settable = false
            if AudioObjectHasProperty(device, &m), AudioObjectIsPropertySettable(device, &m, &settable) == noErr, settable.boolValue {
                var off: UInt32 = 0
                AudioObjectSetPropertyData(device, &m, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
            }
        }
    }

    // MARK: Listeners (delivered on the main queue)

    final class Listener {
        private let object: AudioObjectID
        private var addr: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock
        init?(object: AudioObjectID, selector: AudioObjectPropertySelector, handler: @escaping @Sendable () -> Void) {
            self.object = object
            addr = Devices.address(selector)
            block = { _, _ in handler() }
            guard AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr else { return nil }
        }
        deinit { AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block) }
    }

    static func onDefaultOutputChange(_ h: @escaping @Sendable () -> Void) -> Listener? {
        Listener(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice, handler: h)
    }
    static func onDeviceListChange(_ h: @escaping @Sendable () -> Void) -> Listener? {
        Listener(object: system, selector: kAudioHardwarePropertyDevices, handler: h)
    }
    static func onRateChange(_ device: AudioDeviceID, _ h: @escaping @Sendable () -> Void) -> Listener? {
        Listener(object: device, selector: kAudioDevicePropertyNominalSampleRate, handler: h)
    }
    static func onAliveChange(_ device: AudioDeviceID, _ h: @escaping @Sendable () -> Void) -> Listener? {
        Listener(object: device, selector: kAudioDevicePropertyDeviceIsAlive, handler: h)
    }

    // MARK: Process objects

    static func processObject(pid: pid_t) -> AudioObjectID {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return object
    }
}

/// The 16-channel layout installed on the loopback, so players (Music, IINA, …) send every
/// bed channel instead of a stereo fallback: L R C LFE Ls Rs Lrs Rrs Lw Rw Ltf Rtf Ts Vhc
/// Ltr Rtr. Same labels as the Downmix app, so the two never fight over the device.
enum LoopbackLayout {
    static let labels: [AudioChannelLabel] = [
        kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
        kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
        kAudioChannelLabel_LeftWide, kAudioChannelLabel_RightWide,
        kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight,
        kAudioChannelLabel_TopCenterSurround, kAudioChannelLabel_VerticalHeightCenter,
        kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_TopBackRight,
    ]

    @discardableResult
    static func install(on device: AudioDeviceID) -> Bool {
        let count = min(labels.count, Devices.channels(device, scope: kAudioObjectPropertyScopeOutput))
        guard count >= 6 else { return false }
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        var payload = Data(count: offset + count * MemoryLayout<AudioChannelDescription>.size)
        payload.withUnsafeMutableBytes { raw in
            let layout = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            layout.pointee.mChannelBitmap = []
            layout.pointee.mNumberChannelDescriptions = UInt32(count)
            let d = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
            for i in 0..<count { d[i] = AudioChannelDescription(mChannelLabel: labels[i], mChannelFlags: [], mCoordinates: (0, 0, 0)) }
        }
        var ok = true
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            var a = Devices.address(kAudioDevicePropertyPreferredChannelLayout, scope)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue else { ok = false; continue }
            let status = payload.withUnsafeBytes { AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(payload.count), $0.baseAddress!) }
            if status != noErr { ok = false }
        }
        return ok
    }
}

/// A few lines per session about routing, in ~/Library/Logs/Sfera.log (kept under 256 KB).
/// Never written from the audio thread.
enum Log {
    private static let queue = DispatchQueue(label: "dev.sfera.log", qos: .utility)
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Sfera.log")
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 256 * 1024 {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
