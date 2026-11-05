import Foundation

public enum SourceKind: Codable, Sendable, Hashable {
    case bed(Speaker)
    case object
}

public struct RenderSource: Sendable {
    public var id: Int
    public var name: String
    public var kind: SourceKind
    public var audio: [Float]
    public var keyframes: [ObjectKeyframe]
    public var gainDB: Double
    public var distance: DistanceModel
    public var size: Double
    public var group: String

    public init(
        id: Int,
        name: String,
        kind: SourceKind,
        audio: [Float],
        keyframes: [ObjectKeyframe] = [],
        gainDB: Double = 0,
        distance: DistanceModel = .mid,
        size: Double = 0,
        group: String = "Bed"
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.audio = audio
        self.keyframes = keyframes
        self.gainDB = gainDB
        self.distance = distance
        self.size = size
        self.group = group
        self.keyframes = keyframes.isEmpty ? [ObjectKeyframe(time: 0, position: .center, size: size)] : keyframes
    }

    public func position(at time: Double) -> SpatialPoint {
        guard let first = keyframes.first else { return .center }
        if time <= first.time { return first.position }
        guard let last = keyframes.last, time < last.time else { return keyframes.last!.position }
        for index in 0..<(keyframes.count - 1) {
            let a = keyframes[index]
            let b = keyframes[index + 1]
            if time >= a.time, time <= b.time {
                let span = max(b.time - a.time, 0.0001)
                return a.position.interpolated(to: b.position, t: (time - a.time) / span)
            }
        }
        return last.position
    }

    public func size(at time: Double) -> Double {
        guard let first = keyframes.first else { return size }
        if time <= first.time { return first.size }
        guard let last = keyframes.last, time < last.time else { return keyframes.last!.size }
        for index in 0..<(keyframes.count - 1) {
            let a = keyframes[index]
            let b = keyframes[index + 1]
            if time >= a.time, time <= b.time {
                let span = max(b.time - a.time, 0.0001)
                return a.size + (b.size - a.size) * (time - a.time) / span
            }
        }
        return last.size
    }

    /// Bed channels sit at their nominal monitoring position.
    public var bedPosition: SpatialPoint? {
        if case .bed(let speaker) = kind, !speaker.isLFE {
            return SpatialPoint.fromSpherical(azimuth: speaker.azimuth, elevation: speaker.elevation, radius: 1)
        }
        return nil
    }
}

public struct BassManagement: Codable, Sendable, Hashable {
    public var enabled: Bool = true
    public var crossoverHz: Double = 80
    public var lfeToStereoDB: Double = 5.5
    public init() {}
}

/// Offline binaural render settings (used to pre-render ADM masters with objects).
public struct RenderSettings: Sendable {
    public var bass: BassManagement
    public var limiter: LimiterSettings
    public var outputGainDB: Double
    public var sampleRate: Double
    /// Adds the virtual room (driven by each source's render mode).
    public var binauralRoom: Bool = true

    public init(
        bass: BassManagement = BassManagement(),
        limiter: LimiterSettings = LimiterSettings(),
        outputGainDB: Double = 0,
        sampleRate: Double = 48000
    ) {
        self.bass = bass
        self.limiter = limiter
        self.outputGainDB = outputGainDB
        self.sampleRate = sampleRate
    }
}

public struct RenderStats: Sendable {
    public init() {}

    public var frames: Int = 0
    public var peak: Float = 0
    public var limitingDB: Double = 0
    public var renderedObjects: Int = 0
    public var renderedBedChannels: Int = 0
    public var prepSeconds: Double = 0
}
