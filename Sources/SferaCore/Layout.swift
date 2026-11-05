import Foundation

/// The 16 bed positions Sfera renders, in loopback channel order
/// (L R C LFE Lss Rss Lrs Rrs Lw Rw Ltf Rtf Cts Cfh Ltr Rtr). The raw value is the
/// channel index on BlackHole 16ch.
public enum Speaker: Int, CaseIterable, Sendable {
    case l, r, c, lfe, lss, rss, lrs, rrs, lw, rw, ltf, rtf, cts, cfh, ltr, rtr

    /// Degrees; 0 = front, positive = right.
    public var azimuth: Double {
        switch self {
        case .c, .cts, .cfh, .lfe: 0
        case .l, .ltf: -30
        case .r, .rtf: 30
        case .lw: -60
        case .rw: 60
        case .lss: -90
        case .rss: 90
        case .lrs, .ltr: -135
        case .rrs, .rtr: 135
        }
    }

    /// Degrees above the ear plane.
    public var elevation: Double {
        switch self {
        case .ltf, .rtf, .cfh, .ltr, .rtr: 45
        case .cts: 60
        default: 0
        }
    }

    public var isLFE: Bool { self == .lfe }
    public var isHeight: Bool { elevation > 0 }
    public var bit: UInt32 { 1 << UInt32(rawValue) }
}

public enum Layout {
    /// Channel order Sfera installs on the loopback (same labels as the Downmix app).
    public static let loopback: [Speaker] = Speaker.allCases
    /// Upmix outputs, in the order `Upmixer` produces them.
    static let upmix: [Speaker] = [.l, .r, .c, .lfe, .lss, .rss, .lrs, .rrs, .ltf, .rtf, .ltr, .rtr]

    /// Short name of what an active-channel mask carries: "Atmos", "7.1", "5.1", "3.1", "Stereo".
    public static func describe(activeChannels mask: UInt32) -> String {
        func any(_ s: [Speaker]) -> Bool { s.contains { mask & $0.bit != 0 } }
        if any([.ltf, .rtf, .ltr, .rtr, .cts, .cfh]) { return "Atmos" }
        if any([.lrs, .rrs, .lw, .rw]) { return "7.1" }
        if any([.lss, .rss]) { return "5.1" }
        if any([.c, .lfe]) { return "3.1" }
        return "Stereo"
    }
}
