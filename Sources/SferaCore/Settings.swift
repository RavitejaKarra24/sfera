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
/// - `refined`: Classic's image (same head cues and upmix; the bench holds its interaural
///   coherence at or below Classic's) with fixes (surround onsets at full level, an LFE
///   balance that doesn't move with the room, a limiter that recovers fully) and its own
///   room (`RefinedRoom`: Classic's reflections by room size, a smoother tail with
///   frequency-dependent decay and bass), shaped by `RoomSettings`.
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

/// Size of the Refined renderer's virtual room (its reflection delays and tail lines).
public enum RoomSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small, medium, large

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// The Refined renderer's room (Classic ignores it). Near/Mid/Far still set how much of it
/// you hear; these shape the room itself.
public struct RoomSettings: Codable, Sendable, Hashable {
    public var size: RoomSize = .medium
    /// Reverberation time at 1 kHz (s). Bass decays about 1.2× longer, 8 kHz about half.
    public var decay: Double = 0.45
    /// Early-reflection level (dB re the calibrated default).
    public var early: Double = 0
    /// Late-tail level (dB re the calibrated default).
    public var late: Double = 0
    /// The tail's high-pass: 0 = 160 Hz (Classic), 1 = 40 Hz. Reflections stay above 160 Hz.
    public var bass: Double = 0.25

    public static let decayRange = 0.25...1.2
    public static let levelRange = -12.0...6.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = (try? c.decodeIfPresent(RoomSize.self, forKey: .size)) ?? .medium
        decay = try c.decodeIfPresent(Double.self, forKey: .decay) ?? 0.45
        early = try c.decodeIfPresent(Double.self, forKey: .early) ?? 0
        late = try c.decodeIfPresent(Double.self, forKey: .late) ?? 0
        bass = try c.decodeIfPresent(Double.self, forKey: .bass) ?? 0.25
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
    /// The Refined renderer's room.
    public var room = RoomSettings()
    public var outputGainDB: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spatial = try c.decodeIfPresent(Bool.self, forKey: .spatial) ?? true
        upmix = try c.decodeIfPresent(UpmixSettings.self, forKey: .upmix) ?? UpmixSettings()
        renderMode = (try? c.decodeIfPresent(RoomMode.self, forKey: .renderMode)) ?? .mid
        renderer = (try? c.decodeIfPresent(Renderer.self, forKey: .renderer)) ?? .classic
        room = (try? c.decodeIfPresent(RoomSettings.self, forKey: .room)) ?? RoomSettings()
        outputGainDB = try c.decodeIfPresent(Double.self, forKey: .outputGainDB) ?? 0
    }
}

@inline(__always)
func dbToGain(_ db: Double) -> Float {
    db <= -120 ? 0 : Float(pow(10.0, db / 20.0))
}
