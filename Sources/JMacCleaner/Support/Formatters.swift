import Foundation

enum Formatters {
    static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        if mb >= 100 {
            return String(format: "%.0f MB", mb)
        }
        if mb >= 10 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.2f MB", mb)
    }

    static func cpu(_ percent: Double) -> String {
        String(format: "%.1f%%", min(999, percent))
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }
}
