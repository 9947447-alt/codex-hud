import Foundation

public enum TaskTokenFormatter {
    public static func string(_ count: Int) -> String {
        guard count >= 0 else { return "— tok" }
        if count < 1_000 { return "\(count) tok" }
        let divisor: Double
        let suffix: String
        if count >= 1_000_000 {
            divisor = 1_000_000
            suffix = "M"
        } else {
            divisor = 1_000
            suffix = "K"
        }
        let value = Double(count) / divisor
        var formatted = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while formatted.last == "0" { formatted.removeLast() }
        if formatted.last == "." { formatted.removeLast() }
        return "\(formatted)\(suffix) tok"
    }
}
