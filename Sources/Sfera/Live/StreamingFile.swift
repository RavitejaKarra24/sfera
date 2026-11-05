import AVFoundation
import CoreMedia
import Foundation
import SpatialCore
import Synchronization

/// Something the live output can play: an in-memory file or a file streamed from disk.
/// `read` runs on the render thread; everything else is called from the main thread.
protocol PlaybackItem: AnyObject, Sendable {
    var sampleRate: Double { get }
    var layout: ChannelLayout { get }
    var title: String { get }
    var detail: String { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var didFinish: Bool { get }
    /// Frames handed to the spatializer so far (not yet including output latency).
    var currentFrame: Int { get }
    /// The movie, when the file has a picture to show alongside the audio.
    var videoAsset: AVURLAsset? { get }
    func setPlaying(_ value: Bool)
    func seek(to frame: Int)
    func read(into outputs: [UnsafeMutablePointer<Float>], frames count: Int)
    func close()
}

extension FilePlayback: PlaybackItem {
    var videoAsset: AVURLAsset? { nil }
    func close() {}
}

/// Streams the audio track of any AVFoundation-readable file (movies included) from disk:
/// a background thread decodes with `AVAssetReader` into a ring buffer, the render thread
/// drains it. A two-hour 5.1 film never sits in memory.
///
/// Seeking is a handshake so neither side locks: the main thread bumps `seekGen`; the
/// decoder stops writing and acknowledges; the render thread flushes the ring and
/// acknowledges; the decoder restarts at the new position.
final class StreamingFile: PlaybackItem, @unchecked Sendable {
    let sampleRate: Double
    let layout: ChannelLayout
    let title: String
    let detail: String
    let duration: Double
    let videoAsset: AVURLAsset?
    let channelCount: Int

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let ring: AudioRingBuffer
    private let playing = Atomic<Bool>(false)
    private let finished = Atomic<Bool>(false)
    private let endOfStream = Atomic<Bool>(false)
    private let stopped = Atomic<Bool>(false)
    private let seekGen = Atomic<Int>(0)
    private let decoderGen = Atomic<Int>(0)
    private let flushedGen = Atomic<Int>(0)
    private let requestedFrame = Atomic<Int>(0)
    private let renderFrame = Atomic<Int>(0)
    private let decodeError = Atomic<Bool>(false)
    private var thread: Thread?
    /// Render-thread only: wait for the decoder to refill after a start or seek, so the
    /// first callbacks don't underrun (a click).
    private var priming = true
    private static let primeFrames = 4096

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "qt"]

    private init(asset: AVURLAsset, track: AVAssetTrack, sampleRate: Double, speakers: [Speaker],
                 duration: Double, hasVideo: Bool, title: String, detail: String) {
        self.asset = asset
        self.track = track
        self.sampleRate = sampleRate
        channelCount = speakers.count
        layout = Self.layout(for: speakers)
        self.duration = duration
        videoAsset = hasVideo ? asset : nil
        self.title = title
        self.detail = detail
        ring = AudioRingBuffer(channels: speakers.count, capacity: 1 << 17, targetFrames: 0)
        ring.maxFrames = .max
    }

    /// The decoder thread keeps the file alive until `close()`.

    /// Opens `url` and starts decoding (paused). Picks the audio track with the most
    /// channels, so a film's 5.1 mix wins over a stereo commentary track.
    static func open(url: URL) async throws -> StreamingFile {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard !audio.isEmpty else { throw MediaError.unsupported("no audio track macOS can decode") }
        var best: (track: AVAssetTrack, channels: Int, rate: Double, layout: AVAudioChannelLayout?)?
        for track in audio {
            let descriptions = try await track.load(.formatDescriptions)
            guard let description = descriptions.first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
            let channels = Int(asbd.mChannelsPerFrame)
            var layoutSize = 0
            var layout: AVAudioChannelLayout?
            if let acl = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize) {
                layout = AVAudioChannelLayout(layout: acl)
            }
            if best == nil || channels > best!.channels {
                best = (track, channels, asbd.mSampleRate, layout)
            }
        }
        guard let best, best.channels > 0, best.rate > 0 else { throw MediaError.unsupported("unreadable audio format") }
        guard best.channels <= 16 else { throw MediaError.unsupported("\(best.channels)-channel audio") }
        let speakers = MediaImporter.resolveSpeakers(layout: best.layout, channelCount: best.channels)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let hasVideo = !video.isEmpty && videoExtensions.contains(url.pathExtension.lowercased())
        let format = layout(for: speakers)
        let kind = speakers.count <= 2 ? (speakers.count == 1 ? "Mono" : "Stereo") : format.name
        let detail = "\(kind) · \(Int(best.rate / 1000)) kHz\(hasVideo ? " · video" : "")"
        let file = StreamingFile(
            asset: asset, track: best.track, sampleRate: best.rate, speakers: speakers,
            duration: duration.isFinite ? duration : 0, hasVideo: hasVideo,
            title: url.deletingPathExtension().lastPathComponent, detail: detail
        )
        file.startDecoder()
        return file
    }

    /// Display name from the known layouts (order-independent), keeping the stream's channel order.
    static func layout(for speakers: [Speaker]) -> ChannelLayout {
        let set = Set(speakers)
        let name = ChannelLayout.all.first { Set($0.speakers) == set && $0.name != "BIN" }?.name
            ?? speakers.map(\.label).joined(separator: "+")
        return ChannelLayout(name: name, speakers: speakers)
    }

    // MARK: Main thread

    var isPlaying: Bool { playing.load(ordering: .relaxed) }
    var didFinish: Bool { finished.load(ordering: .relaxed) }
    var currentFrame: Int { renderFrame.load(ordering: .relaxed) }
    var failed: Bool { decodeError.load(ordering: .relaxed) }

    func setPlaying(_ value: Bool) {
        if value { finished.store(false, ordering: .relaxed) }
        playing.store(value, ordering: .relaxed)
    }

    func seek(to frame: Int) {
        let maxFrame = max(0, Int(duration * sampleRate) - 1)
        requestedFrame.store(min(max(0, frame), maxFrame), ordering: .relaxed)
        finished.store(false, ordering: .relaxed)
        renderFrame.store(min(max(0, frame), maxFrame), ordering: .relaxed)
        seekGen.add(1, ordering: .releasing)
    }

    func close() {
        stopped.store(true, ordering: .releasing)
        playing.store(false, ordering: .relaxed)
    }

    // MARK: Render thread

    func read(into outputs: [UnsafeMutablePointer<Float>], frames count: Int) {
        let gen = seekGen.load(ordering: .acquiring)
        if gen != flushedGen.load(ordering: .relaxed) {
            silence(outputs, from: 0, count: count)
            // The decoder has stopped writing for this seek: drop stale audio.
            if decoderGen.load(ordering: .acquiring) == gen {
                ring.discardAll()
                renderFrame.store(requestedFrame.load(ordering: .relaxed), ordering: .relaxed)
                priming = true
                flushedGen.store(gen, ordering: .releasing)
            }
            return
        }
        guard playing.load(ordering: .relaxed) else {
            silence(outputs, from: 0, count: count)
            return
        }
        if priming {
            if ring.available >= Self.primeFrames || endOfStream.load(ordering: .acquiring) {
                priming = false
            } else {
                silence(outputs, from: 0, count: count)
                return
            }
        }
        let available = min(count, ring.available)
        if available > 0 { ring.read(into: outputs, frames: available) }
        silence(outputs, from: available, count: count)
        renderFrame.add(available, ordering: .relaxed)
        if available < count, endOfStream.load(ordering: .acquiring), ring.available == 0 {
            playing.store(false, ordering: .relaxed)
            finished.store(true, ordering: .relaxed)
        }
    }

    private func silence(_ outputs: [UnsafeMutablePointer<Float>], from start: Int, count: Int) {
        guard start < count else { return }
        for out in outputs { (out + start).update(repeating: 0, count: count - start) }
    }

    // MARK: Decoder thread

    private func startDecoder() {
        let thread = Thread { [weak self] in self?.decodeLoop() }
        thread.name = "dev.sfera.decode"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    private func decodeLoop() {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        var gen = 0
        var startFrame = 0
        while !stopped.load(ordering: .acquiring) {
            endOfStream.store(false, ordering: .releasing)
            let interrupted = decode(from: startFrame, gen: gen, settings: settings)
            if stopped.load(ordering: .acquiring) { break }
            if !interrupted {
                // Reached the end: idle until a seek or close.
                endOfStream.store(true, ordering: .releasing)
                while !stopped.load(ordering: .acquiring), seekGen.load(ordering: .acquiring) == gen {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if stopped.load(ordering: .acquiring) { break }
            }
            // Seek: acknowledge, wait for the render thread to flush, restart there.
            gen = seekGen.load(ordering: .acquiring)
            endOfStream.store(false, ordering: .releasing)
            decoderGen.store(gen, ordering: .releasing)
            while !stopped.load(ordering: .acquiring), flushedGen.load(ordering: .acquiring) != gen {
                if seekGen.load(ordering: .acquiring) != gen {
                    gen = seekGen.load(ordering: .acquiring)
                    decoderGen.store(gen, ordering: .releasing)
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            startFrame = requestedFrame.load(ordering: .relaxed)
        }
    }

    /// Decodes from `startFrame` into the ring. Returns true if a seek or close interrupted it.
    private func decode(from startFrame: Int, gen: Int, settings: [String: Any]) -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else {
            decodeError.store(true, ordering: .relaxed)
            return false
        }
        let timescale = CMTimeScale(sampleRate.rounded())
        // Start a little early so codec priming is settled by the requested frame.
        let preroll = startFrame > 0 ? min(startFrame, Int(sampleRate * 0.1)) : 0
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(startFrame - preroll), timescale: timescale),
                                       duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { decodeError.store(true, ordering: .relaxed); return false }
        reader.add(output)
        guard reader.startReading() else { decodeError.store(true, ordering: .relaxed); return false }
        defer { reader.cancelReading() }


        while true {
            if stopped.load(ordering: .acquiring) || seekGen.load(ordering: .acquiring) != gen { return true }
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed { decodeError.store(true, ordering: .relaxed) }
                return false
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let firstFrame = pts.isValid ? Int((pts.seconds * sampleRate).rounded()) : startFrame
            let skip = max(0, min(frames, startFrame - firstFrame))
            guard skip < frames else { continue }

            var blockBuffer: CMBlockBuffer?
            var list = AudioBufferList()
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, bufferListSizeNeededOut: nil, bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer
            )
            guard status == noErr, let data = list.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = max(1, Int(list.mBuffers.mNumberChannels))
            var offset = skip
            while offset < frames {
                let chunk = min(frames - offset, 8192)
                // Wait for room; keep checking for seeks while the listener is paused.
                while ring.freeSpace < chunk {
                    if stopped.load(ordering: .acquiring) || seekGen.load(ordering: .acquiring) != gen { return true }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                ring.write(interleaved: data + offset * stride, stride: stride, frames: chunk)
                offset += chunk
            }
        }
    }
}
