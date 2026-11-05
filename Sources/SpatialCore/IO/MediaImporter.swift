import AVFoundation
import AudioToolbox
import Foundation

public enum ImportKind: String, Sendable {
    case adm = "ADM BWF"
    case multichannel = "Multichannel PCM"
    case compressed = "Compressed"
    case demo = "Demo"
}

public struct ImportedMedia: Sendable {
    public var sources: [RenderSource]
    public var layout: ChannelLayout?
    public var sampleRate: Double
    public var frames: Int
    public var title: String
    public var kind: ImportKind
    public var notes: [String]

    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    public init(sources: [RenderSource], layout: ChannelLayout?, sampleRate: Double, frames: Int,
                title: String, kind: ImportKind, notes: [String]) {
        self.sources = sources
        self.layout = layout
        self.sampleRate = sampleRate
        self.frames = frames
        self.title = title
        self.kind = kind
        self.notes = notes
    }
}

public enum MediaError: LocalizedError {
    case unsupported(String)
    case noDecoder(String)
    case empty
    case atmosMaster

    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): "Unsupported media: \(detail)"
        case .noDecoder(let tool): "No decoder available. Install \(tool) or import a multichannel WAV."
        case .empty: "The file contained no audio."
        case .atmosMaster:
            "Dolby .atmos master sets use a proprietary container. Open them in your licensed Renderer and export an ADM BWF or 2.0 re-render, then import that here."
        }
    }
}

public enum MediaImporter {
    public static func load(url: URL) throws -> ImportedMedia {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "atmos":
            throw MediaError.atmosMaster
        case "wav", "rf64", "bwf", "wave":
            return try loadWave(url: url)
        case "m4a", "mp3", "aac", "flac", "aif", "aiff", "aifc", "caf", "alac", "m4b", "mp4", "mov", "m4v", "ec3", "eac3", "ac3":
            // Apple's decoders first (no ffmpeg needed for normal music files); ffmpeg as fallback.
            if let media = try? loadWithAVFoundation(url: url) { return media }
            return try loadCompressed(url: url)
        case "mkv", "mxf", "ts":
            return try loadCompressed(url: url)
        default:
            if let media = try? loadWave(url: url) { return media }
            return try loadCompressed(url: url)
        }
    }

    public static func loadWave(url: URL) throws -> ImportedMedia {
        let contents = try WaveReader.read(url: url)
        guard contents.audio.frameCount > 0 else { throw MediaError.empty }
        var notes: [String] = []

        if let axml = contents.axml, let document = try? ADMParser.parse(string: axml) {
            let tracks = ADMParser.tracks(in: document, chna: contents.chnaTracks)
            var sources: [RenderSource] = []
            for (offset, track) in tracks.enumerated() {
                let channelIndex = min(track.channelIndex, contents.audio.channelCount - 1)
                guard channelIndex >= 0 else { continue }
                let audio = contents.audio.channels[channelIndex]
                let kind: SourceKind
                if track.isBed, let speaker = track.speaker {
                    kind = .bed(speaker)
                } else {
                    kind = .object
                }
                sources.append(RenderSource(
                    id: offset + 1,
                    name: track.objectName,
                    kind: kind,
                    audio: audio,
                    keyframes: track.keyframes,
                    gainDB: 0,
                    distance: .mid,
                    size: track.keyframes.first?.size ?? 0,
                    group: track.group
                ))
            }
            if !sources.isEmpty {
                notes.append("ADM: \(document.objects.count) audio objects, \(tracks.filter(\.isBed).count) bed channels")
                if let name = document.programmeName, !name.isEmpty { notes.append("Programme: \(name)") }
                let bedLayout = ChannelLayout(name: "ADM", speakers: sources.compactMap { source -> Speaker? in
                    if case .bed(let speaker) = source.kind { return speaker }
                    return nil
                })
                return ImportedMedia(
                    sources: sources,
                    layout: bedLayout.speakers.isEmpty ? nil : bedLayout,
                    sampleRate: contents.audio.sampleRate,
                    frames: contents.audio.frameCount,
                    title: url.deletingPathExtension().lastPathComponent,
                    kind: .adm,
                    notes: notes
                )
            }
            notes.append("ADM document contained no resolvable objects; fell back to channel layout.")
        }

        let layout = contents.layout ?? WaveChannelMask.inferLayout(channelCount: contents.audio.channelCount)
        guard layout != nil || contents.audio.channelCount > 0 else { throw MediaError.unsupported("unknown channel layout") }
        let speakers = layout?.speakers ?? defaultSpeakers(count: contents.audio.channelCount)
        var sources: [RenderSource] = []
        for (index, speaker) in speakers.enumerated() where index < contents.audio.channelCount {
            sources.append(RenderSource(
                id: index + 1,
                name: speaker.label,
                kind: .bed(speaker),
                audio: contents.audio.channels[index],
                keyframes: [ObjectKeyframe(time: 0, position: bedPoint(speaker), size: 0)],
                group: "Bed"
            ))
        }
        notes.append("\(contents.audio.channelCount) channels · \(layout?.name ?? "custom") · \(Int(contents.audio.sampleRate)) Hz")
        return ImportedMedia(
            sources: sources,
            layout: layout,
            sampleRate: contents.audio.sampleRate,
            frames: contents.audio.frameCount,
            title: url.deletingPathExtension().lastPathComponent,
            kind: .multichannel,
            notes: notes
        )
    }

    private static func bedPoint(_ speaker: Speaker) -> SpatialPoint {
        SpatialPoint.fromSpherical(azimuth: speaker.azimuth, elevation: speaker.elevation, radius: 1)
    }

    private static func defaultSpeakers(count: Int) -> [Speaker] {
        let order: [Speaker] = [.l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs, .ltf, .rtf, .ltm, .rtm, .ltr, .rtr, .lw, .rw]
        return Array(order.prefix(max(1, min(count, order.count))))
    }

    // MARK: AVFoundation decoding

    /// Decodes any format Core Audio supports (AAC, ALAC, MP3, FLAC, AIFF, CAF, and on
    /// macOS also AC-3/E-AC-3) to planar float, mapping the file's channel labels to speakers.
    public static func loadWithAVFoundation(url: URL) throws -> ImportedMedia {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let frames = Int(file.length)
        guard frames > 0, channels > 0 else { throw MediaError.empty }
        guard frames < Int(format.sampleRate * 60 * 90) else { throw MediaError.unsupported("longer than 90 minutes") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw MediaError.unsupported("could not allocate decode buffer")
        }
        try file.read(into: buffer)
        let decoded = Int(buffer.frameLength)
        guard decoded > 0, let data = buffer.floatChannelData else { throw MediaError.empty }

        let speakers = speakers(for: format.channelLayout, channelCount: channels)
            ?? WaveChannelMask.inferLayout(channelCount: channels)?.speakers
            ?? defaultSpeakers(count: channels)
        var sources: [RenderSource] = []
        for (index, speaker) in speakers.enumerated() where index < channels {
            sources.append(RenderSource(
                id: index + 1,
                name: speaker.label,
                kind: .bed(speaker),
                audio: Array(UnsafeBufferPointer(start: data[index], count: decoded)),
                keyframes: [ObjectKeyframe(time: 0, position: bedPoint(speaker), size: 0)],
                group: "Bed"
            ))
        }
        let layout = ChannelLayout.all.first { $0.speakers == speakers } ?? ChannelLayout(name: speakers.map(\.label).joined(separator: "+"), speakers: speakers)
        return ImportedMedia(
            sources: sources,
            layout: layout,
            sampleRate: format.sampleRate,
            frames: decoded,
            title: url.deletingPathExtension().lastPathComponent,
            kind: channels <= 2 ? .multichannel : .compressed,
            notes: ["\(channels) channels · \(layout.name) · \(Int(format.sampleRate)) Hz · decoded by Core Audio"]
        )
    }

    /// Speakers for a decoded stream, in channel order: from the layout tags when they are
    /// all known, else the conventional order for that channel count.
    public static func resolveSpeakers(layout: AVAudioChannelLayout?, channelCount: Int) -> [Speaker] {
        speakers(for: layout, channelCount: channelCount)
            ?? WaveChannelMask.inferLayout(channelCount: channelCount)?.speakers
            ?? defaultSpeakers(count: channelCount)
    }

    /// Maps a Core Audio channel layout to speakers, or nil if any channel is unknown.
    public static func speakers(for layout: AVAudioChannelLayout?, channelCount: Int) -> [Speaker]? {
        if channelCount == 1 { return [.c] }
        if channelCount == 2 { return [.l, .r] }
        guard let layout else { return nil }
        var labels: [AudioChannelLabel] = []
        let acl = layout.layout.pointee
        if acl.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
            labels = channelLabels(layout.layout)
        } else {
            var tag = acl.mChannelLayoutTag
            var size: UInt32 = 0
            guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &size) == noErr, size > 0 else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout<AudioChannelLayoutTag>.size), &tag, &size, raw) == noErr else { return nil }
            labels = channelLabels(UnsafePointer(raw.assumingMemoryBound(to: AudioChannelLayout.self)))
        }
        guard labels.count == channelCount else { return nil }
        // "Surround" means side when the layout also has rear surrounds (7.1), else rear-ish (5.1).
        let hasRear = labels.contains(kAudioChannelLabel_RearSurroundLeft) || labels.contains(kAudioChannelLabel_LeftBackSurround)
        var result: [Speaker] = []
        for label in labels {
            let speaker: Speaker?
            switch label {
            case kAudioChannelLabel_Left: speaker = .l
            case kAudioChannelLabel_Right: speaker = .r
            case kAudioChannelLabel_Center: speaker = .c
            case kAudioChannelLabel_LFEScreen: speaker = .lfe
            case kAudioChannelLabel_LeftSurround: speaker = hasRear ? .lss : .ls
            case kAudioChannelLabel_RightSurround: speaker = hasRear ? .rss : .rs
            case kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_LeftSideSurround: speaker = .lss
            case kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RightSideSurround: speaker = .rss
            case kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftBackSurround: speaker = .lrs
            case kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightBackSurround: speaker = .rrs
            case kAudioChannelLabel_LeftCenter: speaker = .lc
            case kAudioChannelLabel_RightCenter: speaker = .rc
            case kAudioChannelLabel_LeftWide: speaker = .lw
            case kAudioChannelLabel_RightWide: speaker = .rw
            case kAudioChannelLabel_VerticalHeightLeft: speaker = .ltf
            case kAudioChannelLabel_VerticalHeightRight: speaker = .rtf
            case kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_LeftTopSurround: speaker = .ltm
            case kAudioChannelLabel_RightTopMiddle, kAudioChannelLabel_RightTopSurround: speaker = .rtm
            case kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_LeftTopRear: speaker = .ltr
            case kAudioChannelLabel_TopBackRight, kAudioChannelLabel_RightTopRear: speaker = .rtr
            case kAudioChannelLabel_TopCenterSurround: speaker = .cts
            case kAudioChannelLabel_VerticalHeightCenter: speaker = .cfh
            default: speaker = nil
            }
            guard let speaker, !result.contains(speaker) else { return nil }
            result.append(speaker)
        }
        return result
    }

    /// Reads the variable-length `mChannelDescriptions` array of an AudioChannelLayout.
    private static func channelLabels(_ layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        guard count > 0, let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return [] }
        let base = UnsafeRawPointer(layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { base[$0].mChannelLabel }
    }

    // MARK: Compressed decoding

    public static func findFFmpeg() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func loadCompressed(url: URL) throws -> ImportedMedia {
        guard let ffmpeg = findFFmpeg() else { throw MediaError.noDecoder("ffmpeg") }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfera-decode-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-v", "error", "-y",
            "-i", url.path,
            "-map", "0:a:0",
            "-t", "600",
            "-c:a", "pcm_f32le",
            "-rf64", "always",
            "-f", "wav",
            temp.path,
        ]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MediaError.unsupported(message.isEmpty ? "decode failed" : message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var media = try loadWave(url: temp)
        media.title = url.deletingPathExtension().lastPathComponent
        media.kind = .compressed
        media.notes.insert("Decoded with ffmpeg to \(media.layout?.name ?? "\(media.sources.count) ch") PCM", at: 0)
        return media
    }
}
