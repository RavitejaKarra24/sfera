import Foundation
import Synchronization

/// Single-producer / single-consumer planar float ring buffer. The capture IOProc writes,
/// the output render callback reads; neither side locks or allocates.
///
/// The reader primes to `targetFrames` before starting, re-primes after an underrun, and
/// skips ahead if the backlog grows past `maxFrames` (keeps live latency bounded).
final class AudioRingBuffer: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    private let mask: Int
    private let data: [UnsafeMutablePointer<Float>]
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    private let underruns = Atomic<Int>(0)
    private var primed = false   // reader-only
    var targetFrames: Int
    var maxFrames: Int

    init(channels: Int, capacity: Int = 1 << 16, targetFrames: Int = 2048) {
        self.channels = channels
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        mask = size - 1
        data = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: size)
            p.initialize(repeating: 0, count: size)
            return p
        }
        self.targetFrames = targetFrames
        maxFrames = targetFrames * 4
    }

    deinit { data.forEach { $0.deallocate() } }

    var available: Int { written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring) }
    var droppedFrames: Int { dropped.load(ordering: .relaxed) }
    var underrunCount: Int { underruns.load(ordering: .relaxed) }

    // MARK: Producer

    /// Frames the producer can write without dropping.
    var freeSpace: Int { capacity - (written.load(ordering: .relaxed) - consumed.load(ordering: .acquiring)) }

    /// Writes interleaved float frames (`stride` floats per frame; channel c at offset c).
    func write(interleaved source: UnsafePointer<Float>, stride: Int, frames: Int) {
        let w = written.load(ordering: .relaxed)
        let r = consumed.load(ordering: .acquiring)
        let count = min(frames, capacity - (w - r))
        if count < frames { dropped.add(frames - count, ordering: .relaxed) }
        for ch in 0..<channels {
            let src = min(ch, stride - 1)
            let dst = data[ch]
            for i in 0..<count { dst[(w + i) & mask] = source[i * stride + src] }
        }
        written.store(w + count, ordering: .releasing)
    }

    /// Writes a planar stereo pair (pass the same pointer twice for mono).
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let w = written.load(ordering: .relaxed)
        let r = consumed.load(ordering: .acquiring)
        let count = min(frames, capacity - (w - r))
        if count < frames { dropped.add(frames - count, ordering: .relaxed) }
        for ch in 0..<channels {
            let src = ch == 0 ? left : right
            let dst = data[ch]
            for i in 0..<count { dst[(w + i) & mask] = src[i] }
        }
        written.store(w + count, ordering: .releasing)
    }

    // MARK: Consumer

    /// Fills `frames` samples per channel; returns how many were real audio (rest is silence).
    @discardableResult
    func read(into outputs: [UnsafeMutablePointer<Float>], frames: Int) -> Int {
        let w = written.load(ordering: .acquiring)
        var r = consumed.load(ordering: .relaxed)
        var avail = w - r
        if !primed {
            if avail < targetFrames {
                silence(outputs, from: 0, frames: frames)
                return 0
            }
            primed = true
        }
        if avail > maxFrames {
            r = w - targetFrames
            avail = targetFrames
        }
        let count = min(frames, avail)
        for ch in 0..<min(channels, outputs.count) {
            let src = data[ch], dst = outputs[ch]
            for i in 0..<count { dst[i] = src[(r + i) & mask] }
        }
        if count < frames {
            silence(outputs, from: count, frames: frames)
            underruns.add(1, ordering: .relaxed)
            primed = false
        }
        consumed.store(r + count, ordering: .releasing)
        return count
    }

    /// Consumer side: throws away everything written so far (used after a seek).
    func discardAll() {
        consumed.store(written.load(ordering: .acquiring), ordering: .releasing)
        primed = false
    }

    private func silence(_ outputs: [UnsafeMutablePointer<Float>], from start: Int, frames: Int) {
        for out in outputs { for i in start..<frames { out[i] = 0 } }
    }
}
