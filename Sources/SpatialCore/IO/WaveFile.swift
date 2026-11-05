import Foundation

public struct WaveFormat: Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var bitsPerSample: Int
    public var isFloat: Bool
    public var channelMask: UInt32

    public init(sampleRate: Double, channelCount: Int, bitsPerSample: Int, isFloat: Bool, channelMask: UInt32) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.isFloat = isFloat
        self.channelMask = channelMask
    }

    public var bytesPerFrame: Int { channelCount * (bitsPerSample / 8) }
    public var layout: ChannelLayout? {
        WaveChannelMask.layout(mask: channelMask, channelCount: channelCount)
    }
}

public struct WaveContents: Sendable {
    public var format: WaveFormat
    public var audio: PlanarAudio
    public var axml: String?
    public var chna: [UInt32]
    /// Parsed `chna` table: audioTrackUID → 1-based track index.
    public var chnaTracks: [String: Int] = [:]
    public var bextDescription: String?
    public var layout: ChannelLayout?
}

public enum WaveError: LocalizedError {
    case notWave
    case unsupported(String)
    case truncated
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notWave: "Not a RIFF/WAVE file."
        case .unsupported(let reason): "Unsupported WAV: \(reason)"
        case .truncated: "The WAV file is truncated."
        case .tooLarge: "The audio exceeds the session frame budget."
        }
    }
}

public enum WaveReader {
    /// Hard ceiling on decoded frames (10 minutes at 96 kHz).
    public static let maxFrames = 96_000 * 600

    public static func read(url: URL) throws -> WaveContents {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try read(data: data)
    }

    public static func read(data: Data) throws -> WaveContents {
        guard data.count >= 44 else { throw WaveError.notWave }
        guard data[0..<4].elementsEqual(Array("RIFF".utf8)) || data[0..<4].elementsEqual(Array("RF64".utf8)) else {
            throw WaveError.notWave
        }
        guard data[8..<12].elementsEqual(Array("WAVE".utf8)) else { throw WaveError.notWave }

        var offset = 12
        var fmt: WaveFormat?
        var dataRange: Range<Int>?
        var rf64DataSize: UInt64?
        var axml: String?
        var chna: [UInt32] = []
        var chnaTracks: [String: Int] = [:]
        var bext: String?

        func u16(_ at: Int) -> UInt16 {
            UInt16(data[at]) | (UInt16(data[at + 1]) << 8)
        }
        func u32(_ at: Int) -> UInt32 {
            UInt32(data[at]) | (UInt32(data[at + 1]) << 8) | (UInt32(data[at + 2]) << 16) | (UInt32(data[at + 3]) << 24)
        }

        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            var size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "ds64", body + 16 <= data.count {
                let lo = UInt64(u32(body + 8))
                let hi = UInt64(u32(body + 12))
                rf64DataSize = lo | (hi << 32)
            }
            if size == 0xFFFF_FFFF, let rf = rf64DataSize { size = Int(rf) }
            guard body <= data.count else { break }
            let available = min(size, data.count - body)

            switch id {
            case "fmt ":
                guard available >= 16 else { throw WaveError.truncated }
                var tag = u16(body)
                let channels = Int(u16(body + 2))
                let rate = Double(u32(body + 4))
                let bits = Int(u16(body + 14))
                var mask: UInt32 = 0
                if tag == 0xFFFE, available >= 40 {
                    mask = u32(body + 20)
                    tag = u16(body + 24)
                }
                let isFloat = tag == 3
                guard tag == 1 || tag == 3 else { throw WaveError.unsupported("format tag \(tag)") }
                fmt = WaveFormat(sampleRate: rate, channelCount: channels, bitsPerSample: bits, isFloat: isFloat, channelMask: mask)
            case "data":
                dataRange = body..<(body + available)
            case "axml":
                axml = String(data: data.subdata(in: body..<(body + available)), encoding: .utf8)
            case "chna":
                var i = body
                while i + 4 <= body + available {
                    chna.append(u32(i))
                    i += 4
                }
                // Records: u16 trackIndex, char[12] UID, char[14] trackRef, char[11] packRef, pad.
                var record = body + 4
                while record + 40 <= body + available {
                    let track = Int(data[record]) | (Int(data[record + 1]) << 8)
                    let uidBytes = data.subdata(in: (record + 2)..<(record + 14))
                    let uid = String(decoding: uidBytes.prefix { $0 != 0 }, as: UTF8.self)
                    if track > 0, !uid.isEmpty { chnaTracks[uid] = track }
                    record += 40
                }
            case "bext":
                if available > 602 {
                    let bytes = data.subdata(in: body..<(body + 256))
                    bext = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
            default:
                break
            }
            offset = body + size + (size % 2)
            if size > available { break }
        }

        guard let fmt else { throw WaveError.unsupported("missing fmt chunk") }
        guard let range = dataRange else { throw WaveError.unsupported("missing data chunk") }
        guard fmt.channelCount > 0, fmt.channelCount <= 128 else {
            throw WaveError.unsupported("channel count \(fmt.channelCount)")
        }

        let bytesPerSample = fmt.bitsPerSample / 8
        let frameBytes = bytesPerSample * fmt.channelCount
        guard frameBytes > 0 else { throw WaveError.unsupported("bit depth \(fmt.bitsPerSample)") }
        var frames = range.count / frameBytes
        if frames > maxFrames { throw WaveError.tooLarge }
        frames = max(frames, 0)

        var channels = Array(repeating: [Float](repeating: 0, count: frames), count: fmt.channelCount)
        // Integer PCM is normalised by its own full scale (2^(bits−1)).
        let scale: Float
        if fmt.isFloat {
            scale = 1
        } else {
            switch fmt.bitsPerSample {
            case 8: scale = 1.0 / 128.0
            case 16: scale = 1.0 / 32768.0
            case 24: scale = 1.0 / 8_388_608.0
            default: scale = 1.0 / 2_147_483_648.0
            }
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: range.lowerBound)
            for frame in 0..<frames {
                let framePtr = base.advanced(by: frame * frameBytes)
                for ch in 0..<fmt.channelCount {
                    let samplePtr = framePtr.advanced(by: ch * bytesPerSample)
                    var value: Float = 0
                    switch (fmt.isFloat, fmt.bitsPerSample) {
                    case (true, 32):
                        value = samplePtr.loadUnaligned(as: Float.self)
                    case (true, 64):
                        value = Float(samplePtr.loadUnaligned(as: Double.self))
                    case (false, 8):
                        value = Float(samplePtr.load(as: UInt8.self)) - 128
                    case (false, 16):
                        value = Float(samplePtr.loadUnaligned(as: Int16.self))
                    case (false, 24):
                        let b0 = UInt32(samplePtr.load(as: UInt8.self))
                        let b1 = UInt32(samplePtr.advanced(by: 1).load(as: UInt8.self))
                        let b2 = UInt32(samplePtr.advanced(by: 2).load(as: UInt8.self))
                        var v = Int32(b0 | (b1 << 8) | (b2 << 16))
                        if v & 0x80_0000 != 0 { v -= 0x100_0000 }
                        value = Float(v)
                    case (false, 32):
                        value = Float(samplePtr.loadUnaligned(as: Int32.self))
                    default:
                        value = 0
                    }
                    channels[ch][frame] = value * scale
                }
            }
        }

        let layout = fmt.layout
        return WaveContents(
            format: fmt,
            audio: PlanarAudio(sampleRate: fmt.sampleRate, channels: channels),
            axml: axml,
            chna: chna,
            chnaTracks: chnaTracks,
            bextDescription: bext,
            layout: layout
        )
    }
}

public enum WaveWriter {
    public enum BitDepth: Int, Sendable {
        case pcm24 = 24
        case float32 = 32
    }

    /// Writes an interleaved WAVE_FORMAT_EXTENSIBLE file with a channel mask.
    public static func write(
        _ audio: PlanarAudio,
        to url: URL,
        bitDepth: BitDepth = .pcm24,
        layout: ChannelLayout? = nil
    ) throws {
        let channels = audio.channelCount
        let frames = audio.frameCount
        let bytesPerSample = bitDepth.rawValue / 8
        let blockAlign = channels * bytesPerSample
        let dataBytes = frames * blockAlign
        let mask = layout.map { WaveChannelMask.mask(for: $0) } ?? 0
        let isFloat = bitDepth == .float32

        var body = Data()
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
        func appendTag(_ s: String) { body.append(contentsOf: Array(s.utf8)) }

        appendTag("RIFF")
        appendU32(0)   // patched below
        appendTag("WAVE")

        appendTag("fmt ")
        appendU32(40)
        appendU16(0xFFFE)
        appendU16(UInt16(channels))
        appendU32(UInt32(audio.sampleRate))
        appendU32(UInt32(audio.sampleRate) * UInt32(blockAlign))
        appendU16(UInt16(blockAlign))
        appendU16(UInt16(bitDepth.rawValue))
        appendU16(22)
        appendU16(UInt16(bitDepth.rawValue))
        appendU32(mask)
        appendU32(isFloat ? 3 : 1)
        body.append(contentsOf: [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])

        appendTag("data")
        appendU32(UInt32(dataBytes))

        let start = body.count
        body.append(Data(count: dataBytes))
        body.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.advanced(by: start)
            for frame in 0..<frames {
                let framePtr = base.advanced(by: frame * blockAlign)
                for ch in 0..<channels {
                    let sample = audio.channels[ch][frame]
                    let ptr = framePtr.advanced(by: ch * bytesPerSample)
                    switch bitDepth {
                    case .float32:
                        ptr.storeBytes(of: sample, as: Float.self)
                    case .pcm24:
                        let clamped = min(max(sample, -1), 1)
                        let v = Int32(clamped * 8_388_607)
                        ptr.storeBytes(of: UInt8(truncatingIfNeeded: v), as: UInt8.self)
                        ptr.advanced(by: 1).storeBytes(of: UInt8(truncatingIfNeeded: v >> 8), as: UInt8.self)
                        ptr.advanced(by: 2).storeBytes(of: UInt8(truncatingIfNeeded: v >> 16), as: UInt8.self)
                    }
                }
            }
        }

        // RIFF size covers everything after the 8-byte header, including pad bytes.
        let riffSize = UInt32(truncatingIfNeeded: body.count - 8).littleEndian
        withUnsafeBytes(of: riffSize) { body.replaceSubrange(4..<8, with: $0) }
        try body.write(to: url, options: .atomic)
    }
}
