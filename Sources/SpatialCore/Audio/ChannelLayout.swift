import Foundation

/// Canonical speaker identifiers used across the renderer.
/// Azimuth convention: 0° = front, positive = to the right, negative = to the left.
/// Elevation: 0° = listener ear plane, positive = above.
public enum Speaker: String, CaseIterable, Codable, Sendable, Hashable {
    case l, r, c, lfe, lc, rc
    case lss, rss, lrs, rrs
    case ls, rs
    case lw, rw
    case ltf, rtf, ltm, rtm, ltr, rtr
    case lfh, rfh, cts, crs
    /// Front-height centre (Core Audio "vertical height centre").
    case cfh

    public var label: String {
        switch self {
        case .l: "L"; case .r: "R"; case .c: "C"; case .lfe: "LFE"
        case .lc: "Lc"; case .rc: "Rc"
        case .lss: "Lss"; case .rss: "Rss"; case .lrs: "Lrs"; case .rrs: "Rrs"
        case .ls: "Ls"; case .rs: "Rs"
        case .lw: "Lw"; case .rw: "Rw"
        case .ltf: "Ltf"; case .rtf: "Rtf"
        case .ltm: "Ltm"; case .rtm: "Rtm"
        case .ltr: "Ltr"; case .rtr: "Rtr"
        case .lfh: "Lfh"; case .rfh: "Rfh"
        case .cts: "Cts"; case .crs: "Crs"; case .cfh: "Cfh"
        }
    }

    public var isLFE: Bool { self == .lfe }

    /// Nominal monitoring geometry for Atmos home-theatre layouts (degrees).
    public var azimuth: Double {
        switch self {
        case .c, .cts, .crs, .cfh: 0
        case .l, .lc, .ltf, .lfh: -30
        case .r, .rc, .rtf, .rfh: 30
        case .lw: -60; case .rw: 60
        case .lss, .ltm: -90; case .rss, .rtm: 90
        case .ls: -110; case .rs: 110
        case .lrs, .ltr: -135; case .rrs, .rtr: 135
        case .lfe: Double.nan
        }
    }

    public var elevation: Double {
        switch self {
        case .ltf, .rtf, .lfh, .rfh, .cfh: 45
        case .ltm, .rtm: 55
        case .ltr, .rtr: 45
        case .cts: 60
        case .crs: 20
        default: 0
        }
    }
}

public struct ChannelLayout: Codable, Sendable, Hashable {
    public var name: String
    public var speakers: [Speaker]

    public init(name: String, speakers: [Speaker]) {
        self.name = name
        self.speakers = speakers
    }

    public var channelCount: Int { speakers.count }
    public var hasLFE: Bool { speakers.contains(.lfe) }
    public var isBinaural: Bool { speakers == [.l, .r] && name.uppercased().contains("BIN") }

    public func index(of speaker: Speaker) -> Int? { speakers.firstIndex(of: speaker) }

    public static let stereo = ChannelLayout(name: "2.0", speakers: [.l, .r])
    public static let mono = ChannelLayout(name: "1.0", speakers: [.c])

    public static let all: [ChannelLayout] = [
        .init(name: "2.0", speakers: [.l, .r]),
        .init(name: "2.1", speakers: [.l, .r, .lfe]),
        .init(name: "3.0", speakers: [.l, .r, .c]),
        .init(name: "5.0", speakers: [.l, .r, .c, .ls, .rs]),
        .init(name: "5.1", speakers: [.l, .r, .c, .lfe, .ls, .rs]),
        .init(name: "5.1.2", speakers: [.l, .r, .c, .lfe, .ls, .rs, .ltf, .rtf]),
        .init(name: "5.1.4", speakers: [.l, .r, .c, .lfe, .ls, .rs, .ltf, .rtf, .ltr, .rtr]),
        .init(name: "7.0", speakers: [.l, .r, .c, .lss, .rss, .lrs, .rrs]),
        .init(name: "7.1", speakers: [.l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs]),
        .init(name: "7.1.2", speakers: [.l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs, .ltm, .rtm]),
        .init(name: "7.1.4", speakers: [.l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs, .ltf, .rtf, .ltr, .rtr]),
        .init(name: "9.1.4", speakers: [.l, .r, .c, .lfe, .lw, .rw, .lss, .rss, .lrs, .rrs, .ltf, .rtf, .ltr, .rtr]),
        .init(name: "9.1.6", speakers: [.l, .r, .c, .lfe, .lw, .rw, .lss, .rss, .lrs, .rrs, .ltf, .rtf, .ltm, .rtm, .ltr, .rtr]),
        .init(name: "BIN", speakers: [.l, .r]),
    ]

    public static func named(_ name: String) -> ChannelLayout? {
        let target = name.uppercased()
        if target == "BIN" || target == "BINAURAL" { return ChannelLayout(name: "BIN", speakers: [.l, .r]) }
        if target == "PHYSICAL" { return all.first { $0.name == "9.1.6" } }
        return all.first { $0.name.uppercased() == target }
    }

    /// The documented default Atmos bed: 7.1.2 on inputs 1–10.
    public static let defaultBed = ChannelLayout(name: "7.1.2", speakers: [.l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs, .lts, .rts])

    /// Bed widths offered by the input configuration panel.
    public static let bedWidths: [ChannelLayout] = [
        .init(name: "2.0", speakers: [.l, .r]),
        .init(name: "3.0", speakers: [.l, .r, .c]),
        .init(name: "5.0", speakers: [.l, .r, .c, .ls, .rs]),
        .init(name: "5.1", speakers: [.l, .r, .c, .lfe, .ls, .rs]),
        .init(name: "7.0", speakers: [.l, .r, .c, .lss, .rss, .lrs, .rrs]),
        .init(name: "7.1", speakers: [.l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs]),
        .init(name: "7.0.2", speakers: [.l, .r, .c, .lss, .rss, .lrs, .rrs, .ltm, .rtm]),
        .init(name: "7.1.2", speakers: [.l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs, .ltm, .rtm]),
    ]
}

/// 7.1.2 bed channel 9/10 identifiers used by the documented default input order.
extension Speaker {
    static let lts: Speaker = .ltm
    static let rts: Speaker = .rtm
}

/// WAVE channel-mask bit assignment for a speaker layout.
public enum WaveChannelMask {
    public static let bits: [Speaker: UInt32] = [
        .l: 0x1, .r: 0x2, .c: 0x4, .lfe: 0x8,
        .ls: 0x10, .rs: 0x20, .lc: 0x40, .rc: 0x80,
        .lss: 0x200, .rss: 0x400, .lrs: 0x800, .rrs: 0x1000,
        .ltf: 0x4000, .rtf: 0x8000, .ltm: 0x10000, .rtm: 0x20000,
        .ltr: 0x80000, .rtr: 0x100000,
    ]

    public static func mask(for layout: ChannelLayout) -> UInt32 {
        layout.speakers.reduce(UInt32(0)) { $0 | (bits[$1] ?? 0) }
    }

    /// Best-effort layout inference for an N-channel, non-extensible WAV.
    public static func inferLayout(channelCount: Int) -> ChannelLayout? {
        switch channelCount {
        case 1: return .mono
        case 2: return .stereo
        case 6: return ChannelLayout.named("5.1")
        case 8: return ChannelLayout.named("7.1")
        case 10: return ChannelLayout.named("7.1.2")
        case 12: return ChannelLayout.named("7.1.4")
        case 16: return ChannelLayout.named("9.1.6")
        default: return nil
        }
    }

    /// Decode a WAVE `dwChannelMask` into an ordered layout, falling back to inference.
    public static func layout(mask: UInt32, channelCount: Int) -> ChannelLayout? {
        if mask == 0 { return inferLayout(channelCount: channelCount) }
        let ordered: [Speaker] = [
            .l, .r, .c, .lfe, .ls, .rs, .lc, .rc, .lss, .rss, .lrs, .rrs,
            .ltf, .rtf, .ltm, .rtm, .ltr, .rtr,
        ]
        var speakers: [Speaker] = []
        for speaker in ordered {
            if mask & (bits[speaker] ?? 0) != 0 { speakers.append(speaker) }
        }
        guard speakers.count == channelCount else { return inferLayout(channelCount: channelCount) }
        let name = ChannelLayout.all.first { $0.speakers == speakers }?.name
            ?? speakers.map(\.label).joined(separator: "+")
        return ChannelLayout(name: name, speakers: speakers)
    }
}
