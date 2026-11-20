import Foundation

enum TimeFormat {
    /// "3:07", "1:02:45", or with `precise` a tenth of a second: "3:07.4".
    static func clock(_ seconds: Double, precise: Bool = false) -> String {
        let clamped = max(0, seconds)
        let whole = precise ? Int(clamped) : Int(clamped.rounded())
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = whole % 60
        let base = h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
        if precise {
            let tenth = Int(clamped * 10) % 10
            return base + ".\(tenth)"
        }
        return base
    }
}
