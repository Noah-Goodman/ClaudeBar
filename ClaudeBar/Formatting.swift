import Foundation

enum Formatting {
    static func timeAgo(from date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "<1m ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.0fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    static func formatCost(_ cost: Double) -> String {
        if cost >= 10_000 {
            return String(format: "$%.0f", cost)
        }
        return String(format: "$%.2f", cost)
    }
}
