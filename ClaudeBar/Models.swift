import Foundation

struct UsageMetric: Sendable, Codable {
    let label: String
    let usedPercent: Int
    let resetDescription: String?
    let spentDescription: String?
    let isUnlimited: Bool
}

struct CostSnapshot: Sendable, Codable {
    let todayCostUSD: Double
    let todayTokens: Int
    let last30DaysCostUSD: Double
    let last30DaysTokens: Int
}

struct UsageSnapshot: Sendable {
    let session: UsageMetric?
    let weekly: UsageMetric?
    let sonnet: UsageMetric?
    let extraUsage: UsageMetric?
    let cost: CostSnapshot?
    let scanProgress: ScanProgress?
    let updatedAt: Date
}

struct CachedUsage: Codable {
    let session: UsageMetric?
    let weekly: UsageMetric?
    let sonnet: UsageMetric?
    let extraUsage: UsageMetric?
    let cost: CostSnapshot?
    let fetchedAt: Date

    private static let refreshInterval: TimeInterval = 15 * 60

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ClaudeBar", isDirectory: true)
            .appendingPathComponent("usage-cache.json")
    }

    var isStale: Bool {
        Date().timeIntervalSince(self.fetchedAt) > Self.refreshInterval
    }

    func toSnapshot(scanProgress: ScanProgress? = nil) -> UsageSnapshot {
        UsageSnapshot(
            session: self.session, weekly: self.weekly, sonnet: self.sonnet,
            extraUsage: self.extraUsage,
            cost: self.cost, scanProgress: scanProgress, updatedAt: self.fetchedAt)
    }

    static func load() -> CachedUsage? {
        guard let data = try? Data(contentsOf: self.cacheURL),
              let decoded = try? JSONDecoder().decode(CachedUsage.self, from: data)
        else { return nil }
        return decoded
    }

    func save() {
        let url = Self.cacheURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
