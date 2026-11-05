import Foundation

/// How much virtual room surrounds the binaural image.
public enum RoomMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, near, mid, far

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Dry"
        case .near: "Near"
        case .mid: "Mid"
        case .far: "Far"
        }
    }

    /// Level of the direct (HRTF) path.
    var directDB: Double {
        switch self {
        case .off: 0
        case .near: -1.5
        case .mid: -3
        case .far: -6
        }
    }

    /// Level sent into the virtual room. `.off` is plain stereo panning (no HRTF, no room).
    var sendDB: Double {
        switch self {
        case .off: -.infinity
        case .near: -17
        case .mid: -11
        case .far: -6
        }
    }

    /// Spatial-path makeup so Spatial and Original play at equal BS.1770 loudness
    /// (measured on partly correlated pink noise through the default upmix).
    var makeupDB: Double {
        switch self {
        case .off: 0.4
        case .near: 0.9
        case .mid: 2.3
        case .far: 4.9
        }
    }
}

/// Which renderer turns speaker feeds into headphone sound.
///
/// - `classic`: Sfera 1.0 exactly (the bench holds it bit-identical to commit d18a518).
/// - `refined`: the same room and voicing with geometry and mixing fixes: rear and height
///   ITD/shadow from the true interaural angle, a back-wall reflection with no ITD,
///   level-preserving centre steering, surround onsets at full level, an LFE balance that
///   doesn't move with the room, and a limiter that recovers fully.
public enum Renderer: String, Codable, CaseIterable, Sendable, Identifiable {
    case classic, refined

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .classic: "Classic"
        case .refined: "Refined"
        }
    }
}

/// Stereo → 7.1.4 upmix controls.
public struct UpmixSettings: Codable, Sendable, Hashable {
    /// 0 keeps a phantom centre on L/R; 1 steers all centre-panned direct sound to C.
    public var centerExtraction: Double = 0.75
    /// 0 keeps the front stage at ±30°; 1 lets hard-panned sound reach the sides (±90°).
    public var width: Double = 0.3
    /// Share of extracted ambience sent to the side and rear surrounds.
    public var surround: Double = 0.75
    /// Share of extracted ambience sent to the four height channels.
    public var height: Double = 0.6
    /// Derive a low-passed LFE channel (off: L/R/C already carry the bass).
    public var generateLFE: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        centerExtraction = try c.decodeIfPresent(Double.self, forKey: .centerExtraction) ?? 0.75
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.3
        surround = try c.decodeIfPresent(Double.self, forKey: .surround) ?? 0.75
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.6
        generateLFE = try c.decodeIfPresent(Bool.self, forKey: .generateLFE) ?? false
    }
}

/// Everything the listener can change. Same JSON shape as Sfera 0.9, so saved
/// preferences carry over.
public struct LiveSettings: Codable, Sendable, Hashable {
    /// true = spatial; false = the original signal (loudness-matched A/B).
    public var spatial = true
    public var upmix = UpmixSettings()
    public var renderMode: RoomMode = .mid
    /// Settings saved before the renderer existed load as `classic`, so nothing changes by itself.
    public var renderer: Renderer = .classic
    public var outputGainDB: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spatial = try c.decodeIfPresent(Bool.self, forKey: .spatial) ?? true
        upmix = try c.decodeIfPresent(UpmixSettings.self, forKey: .upmix) ?? UpmixSettings()
        renderMode = (try? c.decodeIfPresent(RoomMode.self, forKey: .renderMode)) ?? .mid
        renderer = (try? c.decodeIfPresent(Renderer.self, forKey: .renderer)) ?? .classic
        outputGainDB = try c.decodeIfPresent(Double.self, forKey: .outputGainDB) ?? 0
    }
}

@inline(__always)
func dbToGain(_ db: Double) -> Float {
    db <= -120 ? 0 : Float(pow(10.0, db / 20.0))
}
