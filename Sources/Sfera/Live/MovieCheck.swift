import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SpatialCore

/// Self-check for the movie path: writes a real 5.1 AAC + H.264 .mp4 with noise in the
/// centre channel only, streams it back through `StreamingFile`, and checks channel
/// mapping, seeking, end of file and the 5.1 → binaural render.
enum MovieCheck {
    static func run() -> (metrics: [String: Double], failures: [String]) {
        var metrics: [String: Double] = [:]
        var failures: [String] = []
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sfera-movie-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 48000.0, seconds = 3.0
        do {
            try writeMovie(to: url, sampleRate: rate, seconds: seconds)
        } catch {
            return ([:], ["movie: couldn't write the 5.1 test movie: \(error.localizedDescription)"])
        }

        let item: StreamingFile
        do {
            item = try blocking { try await StreamingFile.open(url: url) }
        } catch {
            return ([:], ["movie: StreamingFile.open failed: \(error.localizedDescription)"])
        }
        defer { item.close() }
        metrics["movieChannels"] = Double(item.channelCount)
        metrics["movieDuration"] = item.duration
        if item.videoAsset == nil { failures.append("movie: video track not detected") }
        if Set(item.layout.speakers) != Set(ChannelLayout.named("5.1")?.speakers ?? []) {
            failures.append("movie: 5.1 track mapped to \(item.layout.name) [\(item.layout.speakers.map(\.label).joined(separator: " "))]")
        }
        guard let centre = item.layout.speakers.firstIndex(of: .c) else {
            failures.append("movie: no centre channel")
            return (metrics, failures)
        }

        let block = 1024
        let buffers = (0..<item.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        defer { buffers.forEach { $0.deallocate() } }
        var energy = [Double](repeating: 0, count: item.channelCount)

        // Play 1 s (pulling like the render thread), measure where the tone lands.
        Thread.sleep(forTimeInterval: 0.3)
        item.setPlaying(true)
        var pulled = 0
        for _ in 0..<Int(rate / Double(block)) {
            item.read(into: buffers, frames: block)
            for ch in 0..<item.channelCount { for i in 0..<block { energy[ch] += Double(buffers[ch][i] * buffers[ch][i]) } }
            pulled += block
        }
        let others = energy.enumerated().filter { $0.offset != centre }.map(\.element).max() ?? 0
        let isolation = 10 * log10(max(energy[centre], 1e-12) / max(others, 1e-12))
        metrics["movieCentreIsolation_dB"] = isolation
        if isolation < 30 { failures.append(String(format: "movie: centre signal only %.1f dB above other channels (channel order wrong?)", isolation)) }
        if abs(item.currentFrame - pulled) > 1 { failures.append("movie: position \(item.currentFrame) after pulling \(pulled)") }

        // 5.1 → binaural: centre must image in the middle.
        let spatializer = LiveSpatializer(sampleRate: rate, inputLayout: item.layout, maxFrames: block)
        let outL = UnsafeMutablePointer<Float>.allocate(capacity: block), outR = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { outL.deallocate(); outR.deallocate() }
        item.seek(to: 0)
        var eL = 0.0, eR = 0.0
        var spins = 0
        while item.currentFrame < Int(rate * 0.8), spins < 2000 {
            item.read(into: spatializer.inputs, frames: block)
            spatializer.process(frames: block, outL: outL, outR: outR)
            for i in 0..<block { eL += Double(outL[i] * outL[i]); eR += Double(outR[i] * outR[i]) }
            spins += 1
            if item.currentFrame == 0 { Thread.sleep(forTimeInterval: 0.002) }
        }
        let balance = 10 * log10(max(eL, 1e-12) / max(eR, 1e-12))
        metrics["movieBinauralBalance_dB"] = balance
        if eL < 1e-3 { failures.append("movie: binaural render is silent") }
        if abs(balance) > 1 { failures.append(String(format: "movie: centre images %.2f dB off-centre", balance)) }

        // Seek to 2.0 s: stale audio is flushed, playback resumes exactly there.
        let target = Int(rate * 2)
        item.seek(to: target)
        var resumed = false
        spins = 0
        while spins < 3000 {
            item.read(into: buffers, frames: block)
            if item.currentFrame > target { resumed = true; break }
            spins += 1
            Thread.sleep(forTimeInterval: 0.001)
        }
        // After the flush the reader waits for a refill, so the first audible block
        // starts exactly at the target.
        metrics["movieSeekResumedAt"] = Double(item.currentFrame - block)
        if !resumed { failures.append("movie: seek never resumed") }
        else if item.currentFrame - block != target { failures.append("movie: resumed at \(item.currentFrame - block), asked \(target)") }
        var peak: Float = 0
        for i in 0..<block { peak = max(peak, abs(buffers[centre][i])) }
        if peak < 0.05 { failures.append("movie: silence after seek") }

        // End of file.
        spins = 0
        while !item.didFinish, spins < 4000 {
            item.read(into: buffers, frames: block)
            spins += 1
            if spins % 50 == 0 { Thread.sleep(forTimeInterval: 0.001) }
        }
        if !item.didFinish { failures.append("movie: never reported end of file") }
        metrics["movieEndFrame"] = Double(item.currentFrame)
        return (metrics, failures)
    }

    // MARK: Fixture

    /// 5.1 AAC (noise in C only) plus a 64×64 H.264 picture at 10 fps.
    static func writeMovie(to url: URL, sampleRate: Double, seconds: Double) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A   // L R C LFE Ls Rs
        // The encoder stores AAC order (C L R Ls Rs LFE); the source buffers stay in
        // L R C LFE Ls Rs, so the decode path has to undo a real reorder.
        var aacLayout = AudioChannelLayout()
        aacLayout.mChannelLayoutTag = kAudioChannelLayoutTag_AAC_5_1
        let layoutData = Data(bytes: &aacLayout, count: MemoryLayout<AudioChannelLayout>.size)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 6,
            AVChannelLayoutKey: layoutData,
            AVEncoderBitRateKey: 384_000,
        ])
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        guard writer.canAdd(audioInput), writer.canAdd(videoInput) else { throw MediaError.unsupported("writer inputs") }
        writer.add(audioInput)
        writer.add(videoInput)
        guard writer.startWriting() else { throw writer.error ?? MediaError.unsupported("startWriting") }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 24, mFramesPerPacket: 1, mBytesPerFrame: 24,
            mChannelsPerFrame: 6, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                       layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        guard let format else { throw MediaError.unsupported("audio format description") }

        let totalFrames = Int(sampleRate * seconds)
        let chunk = 4096
        let group = DispatchGroup()
        let audioQueue = DispatchQueue(label: "movie.audio"), videoQueue = DispatchQueue(label: "movie.video")
        let state = FixtureState()

        group.enter()
        audioInput.requestMediaDataWhenReady(on: audioQueue) {
            while audioInput.isReadyForMoreMediaData {
                if state.audioFrame >= totalFrames {
                    audioInput.markAsFinished(); group.leave(); return
                }
                let n = min(chunk, totalFrames - state.audioFrame)
                var samples = [Float](repeating: 0, count: n * 6)
                for i in 0..<n {
                    // Broadband noise (a pure tone interferes with the room's L/R reflections).
                    state.noise = state.noise &* 6364136223846793005 &+ 1442695040888963407
                    let white = Float(Int64(bitPattern: state.noise) >> 40) / Float(1 << 23)
                    samples[i * 6 + 2] = 0.2 * white
                }
                guard let buffer = sampleBuffer(samples, frames: n, start: state.audioFrame, rate: sampleRate, format: format),
                      audioInput.append(buffer) else {
                    audioInput.markAsFinished(); group.leave(); return
                }
                state.audioFrame += n
            }
        }

        group.enter()
        let frames = Int(seconds * 10)
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if state.videoFrame >= frames {
                    videoInput.markAsFinished(); group.leave(); return
                }
                var pixel: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) }
                guard let pixel else { videoInput.markAsFinished(); group.leave(); return }
                CVPixelBufferLockBaseAddress(pixel, [])
                if let base = CVPixelBufferGetBaseAddress(pixel) {
                    memset(base, Int32(state.videoFrame * 8 % 255), CVPixelBufferGetDataSize(pixel))
                }
                CVPixelBufferUnlockBaseAddress(pixel, [])
                adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(state.videoFrame), timescale: 10))
                state.videoFrame += 1
            }
        }

        guard group.wait(timeout: .now() + 20) == .success else { throw MediaError.unsupported("writer timed out") }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? MediaError.unsupported("writer status \(writer.status.rawValue)") }
    }

    private final class FixtureState: @unchecked Sendable {
        var audioFrame = 0
        var videoFrame = 0
        var noise: UInt64 = 0x5EED
    }

    private static func sampleBuffer(_ samples: [Float], frames: Int, start: Int, rate: Double,
                                     format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &buffer
        )
        return buffer
    }

    /// Runs async work from synchronous self-check code (never on the main actor).
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
