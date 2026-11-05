import Foundation

/// Energy ratio in dB; exact silence is −400. NaN stays NaN so it can never pass a limit.
func db(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    return x > 0 ? 10 * log10(x) : -400
}

/// Largest absolute sample in dBFS (−400 for silence, NaN if any sample is not finite).
func peakDB(_ a: Render, _ range: Range<Int>? = nil) -> Double {
    let range = range ?? 0..<a.l.count
    var worst: Float = 0
    for i in range {
        let x = a.l[i], y = a.r[i]
        if !x.isFinite || !y.isFinite { return .nan }
        worst = max(worst, abs(x), abs(y))
    }
    return worst > 0 ? 20 * log10(Double(worst)) : -400
}

func allFinite(_ a: Render) -> Bool {
    a.l.allSatisfy(\.isFinite) && a.r.allSatisfy(\.isFinite)
}

struct Difference {
    /// Difference energy relative to the reference's energy (dB). NaN if either render has a
    /// non-finite sample anywhere.
    var rel: Double
    /// Worst single-sample difference (dBFS).
    var peak: Double
    /// Both renders are bit-identical over the range.
    var identical: Bool
}

/// `a` is the reference.
func compare(_ a: Render, _ b: Render, _ range: Range<Int>) -> Difference {
    guard allFinite(a), allFinite(b) else { return Difference(rel: .nan, peak: .nan, identical: false) }
    var sig = 0.0, err = 0.0, worst: Float = 0
    for i in range {
        for (x, y) in [(a.l[i], b.l[i]), (a.r[i], b.r[i])] {
            sig += Double(x) * Double(x)
            let d = x - y
            err += Double(d) * Double(d)
            worst = max(worst, abs(d))
        }
    }
    return Difference(rel: db(err / max(sig, 1e-30)), peak: worst > 0 ? 20 * log10(Double(worst)) : -400, identical: worst == 0)
}

func seconds(_ a: Double, _ b: Double, rate: Double = 48000) -> Range<Int> { Int(a * rate)..<Int(b * rate) }

var failures: [String] = []

private func mark(_ ok: Bool, _ name: String) -> String {
    if !ok { failures.append(name) }
    return ok ? "✓" : "✗"
}

/// Passes when the difference is at or below `limit` dB re signal. NaN never passes.
func check(_ name: String, _ d: Difference, limit: Double) {
    let ok = d.rel <= limit
    let detail: String
    if d.rel.isNaN {
        detail = "non-finite output"
    } else if d.identical {
        detail = "bit-identical"
    } else {
        detail = String(format: "diff %7.1f dB re signal, worst sample %7.1f dBFS", d.rel, d.peak)
    }
    print("  \(mark(ok, name)) \(name.padding(toLength: 52, withPad: " ", startingAt: 0)) \(detail)")
}

/// A plain assertion with a measured value.
func expect(_ name: String, _ ok: Bool, _ detail: String) {
    print("  \(mark(ok, name)) \(name.padding(toLength: 52, withPad: " ", startingAt: 0)) \(detail)")
}

var knownIssues: [String] = []

/// A defect the engine is known to have: reported, not failed. When it starts passing the
/// bench says so, so the check can be promoted to a normal `check`.
func knownIssue(_ name: String, _ d: Difference, limit: Double, note: String) {
    let fixed = d.rel <= limit
    let detail = d.rel.isNaN ? "non-finite output"
        : String(format: "diff %7.1f dB re signal (%@)", d.rel, (fixed ? "now passes: promote to check" : note) as NSString)
    if !fixed { knownIssues.append(name) }
    print("  \(fixed ? "✓" : "⚠") \(name.padding(toLength: 52, withPad: " ", startingAt: 0)) \(detail)")
}
