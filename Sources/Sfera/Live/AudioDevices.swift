import CoreAudio
import Foundation
import SpatialCore

/// Small Core Audio device helpers: lookup, routing, sample rates, channel layout.
enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
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

    static func name(_ device: AudioDeviceID) -> String {
        string(device, kAudioObjectPropertyName) ?? "Device \(device)"
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func device(uid: String) -> AudioDeviceID? {
        all().first { Self.uid($0) == uid }
    }

    static func transport(_ device: AudioDeviceID) -> UInt32 {
        var a = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value)
        return value
    }

    static func channels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: Kinds

    /// A virtual loopback driver: what apps play into it comes back out of its input, so
    /// Sfera can read every channel an app sends. BlackHole (and Loopback by Rogue Amoeba)
    /// qualify; other virtual devices (Dolby Audio Bridge, Zoom, Teams…) are left alone.
    static func isLoopback(_ device: AudioDeviceID) -> Bool {
        guard transport(device) == kAudioDeviceTransportTypeVirtual else { return false }
        let name = name(device)
        guard name.localizedCaseInsensitiveContains("BlackHole") || name.hasPrefix("Loopback") else { return false }
        return channels(device, scope: kAudioObjectPropertyScopeInput) >= 2
            && channels(device, scope: kAudioObjectPropertyScopeOutput) >= 2
    }

    /// The best loopback for surround: the one with the most channels (BlackHole 16ch).
    static func loopbackDevice() -> AudioDeviceID? {
        all().filter(isLoopback).max {
            channels($0, scope: kAudioObjectPropertyScopeInput) < channels($1, scope: kAudioObjectPropertyScopeInput)
        }
    }

    /// Headphones, DACs, speakers: real outputs Sfera can play to.
    static func isPhysicalOutput(_ device: AudioDeviceID) -> Bool {
        let t = transport(device)
        guard t != kAudioDeviceTransportTypeVirtual, t != kAudioDeviceTransportTypeAggregate,
              t != kAudioDeviceTransportTypeUnknown else { return false }
        return channels(device, scope: kAudioObjectPropertyScopeOutput) >= 1
    }

    static func physicalOutputs() -> [AudioDeviceID] { all().filter(isPhysicalOutput) }

    // MARK: Default output

    static func defaultOutput() -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    @discardableResult
    static func setDefaultOutput(_ device: AudioDeviceID) -> Bool {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        return AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    // MARK: Sample rate

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

    /// The device's master volume in dB (both scopes on BlackHole), nil if it has none.
    static func volumeDB(_ device: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Double? {
        var a = address(kAudioDevicePropertyVolumeDecibels, scope)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    static func volumeScalar(_ device: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Float32 {
        var a = address(kAudioDevicePropertyVolumeScalar, scope)
        var value: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value)
        return value
    }

    static func isMuted(_ device: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Bool {
        var a = address(kAudioDevicePropertyMute, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr && value != 0
    }

    /// Sets the volume slider (0…1) and unmutes, on every scope that has the controls.
    /// A loopback's volume scales what it carries, so it sets how loud Sfera plays on top
    /// of your headphones' own volume. (BlackHole's slider is linear in dB: 50 % = −32 dB.)
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

    // MARK: Listeners

    final class Listener {
        private let object: AudioObjectID
        private var addr: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock
        init?(object: AudioObjectID, selector: AudioObjectPropertySelector, handler: @escaping @Sendable () -> Void) {
            self.object = object
            addr = AudioDevices.address(selector)
            block = { _, _ in handler() }
            guard AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr else { return nil }
        }
        deinit { AudioObjectRemovePropertyListenerBlock(object, &addr, DispatchQueue.main, block) }
    }

    static func onDefaultOutputChange(_ handler: @escaping @Sendable () -> Void) -> Listener? {
        Listener(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice, handler: handler)
    }

    static func onRateChange(_ device: AudioDeviceID, _ handler: @escaping @Sendable () -> Void) -> Listener? {
        Listener(object: device, selector: kAudioDevicePropertyNominalSampleRate, handler: handler)
    }
}

/// The 16-channel speaker layout installed on the loopback so players (Music, IINA, …)
/// send every bed channel instead of a stereo fallback. Same labels as the Downmix app,
/// so the two never fight over the device: L R C LFE Ls Rs Lrs Rrs Lw Rw Ltf Rtf Ts Vhc
/// Ltr Rtr. (Core Audio has no convertible top-middle pair; top-centre and front-height
/// centre stand in, and Sfera renders them where those labels say.)
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

    private static let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!

    private static func data(count: Int) -> Data {
        var data = Data(count: offset + count * MemoryLayout<AudioChannelDescription>.size)
        data.withUnsafeMutableBytes { raw in
            let layout = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            layout.pointee.mChannelBitmap = []
            layout.pointee.mNumberChannelDescriptions = UInt32(count)
            let descriptions = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
            for i in 0..<count {
                descriptions[i] = AudioChannelDescription(mChannelLabel: labels[i], mChannelFlags: [], mCoordinates: (0, 0, 0))
            }
        }
        return data
    }

    /// Installs the layout on both scopes. Returns false if the device refused.
    @discardableResult
    static func install(on device: AudioDeviceID) -> Bool {
        let count = min(labels.count, AudioDevices.channels(device, scope: kAudioObjectPropertyScopeOutput))
        guard count >= 6 else { return false }
        let payload = data(count: count)
        var ok = true
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelLayout, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue else { ok = false; continue }
            let status = payload.withUnsafeBytes { AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(payload.count), $0.baseAddress!) }
            if status != noErr { ok = false }
        }
        return ok
    }

    /// Sfera speakers for the first `count` loopback channels.
    static func speakers(count: Int) -> [Speaker] {
        Array(SpatialDiagnostics.loopbackLayout.speakers.prefix(count))
    }
}
