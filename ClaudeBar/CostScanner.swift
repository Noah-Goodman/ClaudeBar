import Foundation

struct ScanProgress: Sendable {
    let scannedFiles: Int
    let totalFiles: Int
    let isComplete: Bool

    var fraction: Double {
        guard self.totalFiles > 0 else { return 0 }
        return Double(self.scannedFiles) / Double(self.totalFiles)
    }
}

final class CostScanner: Sendable {
    static let shared = CostScanner()

    private let progressContinuation: AsyncStream<ScanProgress>.Continuation
    let progressStream: AsyncStream<ScanProgress>

    private init() {
        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream()
        self.progressStream = stream
        self.progressContinuation = continuation
    }

    private func reportProgress(scanned: Int, total: Int, isComplete: Bool) {
        self.progressContinuation.yield(ScanProgress(scannedFiles: scanned, totalFiles: total, isComplete: isComplete))
    }

    /// Walks the Claude Code logs and totals cost for today and the last 30 days.
    /// Rates come from `pricing`; models it doesn't cover land in the snapshot's
    /// `unpricedModels` with their tokens counted but no cost attributed.
    func scan(pricing: PricingTable) -> CostSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".config/claude/projects"),
            home.appendingPathComponent(".claude/projects"),
        ]

        let now = Date()
        let calendar = Calendar.current
        let todayKey = Self.dayKey(from: now)
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let sinceKey = Self.dayKey(from: thirtyDaysAgo)

        var cache = CostCache.load(version: CostCache.version(pricing: pricing))
        var allFiles: [(url: URL, size: Int64, mtimeMs: Int64)] = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                guard let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                else { continue }
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                if size <= 0 { continue }
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                allFiles.append((url: url, size: size, mtimeMs: Int64(mtime * 1000)))
            }
        }

        let totalFiles = allFiles.count
        self.reportProgress(scanned: 0, total: totalFiles, isComplete: false)

        var todayCost: Double = 0
        var todayTokens: Int = 0
        var totalCost: Double = 0
        var totalTokens: Int = 0
        var seenMessageKeys: Set<String> = []
        var touchedPaths: Set<String> = []
        var unpricedModels: Set<String> = []

        for (index, file) in allFiles.enumerated() {
            let path = file.url.path
            touchedPaths.insert(path)

            if let cached = cache.files[path],
               cached.mtimeMs == file.mtimeMs,
               cached.size == file.size
            {
                for day in cached.days {
                    guard day.key >= sinceKey else { continue }
                    totalCost += day.value.cost
                    totalTokens += day.value.tokens
                    unpricedModels.formUnion(day.value.unpricedModels)
                    if day.key == todayKey {
                        todayCost += day.value.cost
                        todayTokens += day.value.tokens
                    }
                }
                if (index + 1) % 200 == 0 || index == totalFiles - 1 {
                    self.reportProgress(scanned: index + 1, total: totalFiles, isComplete: false)
                }
                continue
            }

            let result = Self.parseFile(
                url: file.url,
                pricing: pricing,
                sinceKey: sinceKey,
                todayKey: todayKey,
                seenKeys: &seenMessageKeys)

            cache.files[path] = CachedFile(
                mtimeMs: file.mtimeMs,
                size: file.size,
                days: result.days)

            for day in result.days {
                totalCost += day.value.cost
                totalTokens += day.value.tokens
                unpricedModels.formUnion(day.value.unpricedModels)
                if day.key == todayKey {
                    todayCost += day.value.cost
                    todayTokens += day.value.tokens
                }
            }

            if (index + 1) % 50 == 0 || index == totalFiles - 1 {
                self.reportProgress(scanned: index + 1, total: totalFiles, isComplete: false)
                cache.save()
            }
        }

        for path in cache.files.keys where !touchedPaths.contains(path) {
            cache.files.removeValue(forKey: path)
        }

        cache.save()
        self.reportProgress(scanned: totalFiles, total: totalFiles, isComplete: true)

        return CostSnapshot(
            todayCostUSD: todayCost,
            todayTokens: todayTokens,
            last30DaysCostUSD: totalCost,
            last30DaysTokens: totalTokens,
            unpricedModels: unpricedModels.sorted())
    }

    // MARK: - File parsing

    private struct FileParseResult {
        var days: [String: DayUsage]
    }

    private static func parseFile(
        url: URL,
        pricing: PricingTable,
        sinceKey: String,
        todayKey: String,
        seenKeys: inout Set<String>) -> FileParseResult
    {
        var days: [String: DayUsage] = [:]

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8)
        else { return FileParseResult(days: days) }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\": \"assistant\"") else { continue }
            guard line.contains("\"usage\"") else { continue }

            guard let lineData = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "assistant"
            else { continue }

            guard let timestamp = obj["timestamp"] as? String else { continue }
            guard let dayKey = Self.dayKeyFromTimestamp(timestamp) else { continue }
            guard dayKey >= sinceKey else { continue }

            guard let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            // Assistant messages Claude Code writes itself (error notices and the
            // like) carry this in place of a model. Nothing reached the API.
            if model == "<synthetic>" { continue }

            let messageId = message["id"] as? String
            let requestId = obj["requestId"] as? String
            if let messageId, let requestId {
                let key = "\(messageId):\(requestId)"
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)
            }

            let inputTokens = Self.intValue(usage["input_tokens"])
            let outputTokens = Self.intValue(usage["output_tokens"])
            let cacheReadTokens = Self.intValue(usage["cache_read_input_tokens"])
            let cacheCreateTokens = Self.intValue(usage["cache_creation_input_tokens"])
            // Cache creation splits into 5-minute (1.25x) and 1-hour (2x) TTLs at different rates.
            // Tokens not explicitly tagged 1-hour (incl. older logs lacking the breakdown) bill at the 5m rate.
            let cacheWrite1hTokens = Self.intValue((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
            let cacheWrite5mTokens = max(0, cacheCreateTokens - cacheWrite1hTokens)
            let lineTokens = inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens
            if lineTokens == 0 { continue }

            // Fast mode is recorded on usage.speed, not in the model string.
            let isFast = (usage["speed"] as? String) == "fast"

            var day = days[dayKey] ?? DayUsage(cost: 0, tokens: 0, unpricedModels: [])
            day.tokens += lineTokens

            if let modelPricing = pricing.pricing(for: model, isFast: isFast) {
                day.cost += Self.computeCost(
                    pricing: modelPricing,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheWrite5mTokens: cacheWrite5mTokens,
                    cacheWrite1hTokens: cacheWrite1hTokens)
            } else {
                // Count the tokens but attribute no cost, and name the model so the
                // UI can say the total is short rather than passing it off as whole.
                let name = PricingTable.normalizeModelName(model)
                if !day.unpricedModels.contains(name) {
                    day.unpricedModels.append(name)
                }
            }

            days[dayKey] = day
        }

        return FileParseResult(days: days)
    }

    // MARK: - Pricing

    private static func computeCost(
        pricing: ModelPricing,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWrite5mTokens: Int,
        cacheWrite1hTokens: Int) -> Double
    {
        let perToken = 1.0 / 1_000_000
        return Double(inputTokens) * pricing.input * perToken
            + Double(outputTokens) * pricing.output * perToken
            + Double(cacheWrite5mTokens) * pricing.cacheWrite5m * perToken
            + Double(cacheWrite1hTokens) * pricing.cacheWrite1h * perToken
            + Double(cacheReadTokens) * pricing.cacheRead * perToken
    }

    // MARK: - Helpers

    private static func dayKeyFromTimestamp(_ timestamp: String) -> String? {
        guard timestamp.count >= 10 else { return nil }
        let prefix = String(timestamp.prefix(10))
        if prefix.contains("-") && prefix.count == 10 {
            return prefix
        }
        return nil
    }

    private static func dayKey(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }
}

// MARK: - Cache types

struct DayUsage: Codable, Sendable {
    var cost: Double
    var tokens: Int
    /// Models seen this day that the pricing table had no rates for. Their tokens
    /// are in `tokens`; their cost is not in `cost`. Recorded per day so the cached
    /// result reports them only while the day stays inside the 30-day window.
    var unpricedModels: [String]
}

struct CachedFile: Codable {
    let mtimeMs: Int64
    let size: Int64
    let days: [String: DayUsage]
}

struct CostCache: Codable {
    /// Bump when the shape of what's cached changes, so an old file is discarded
    /// rather than decoded into the new types.
    private static let schemaVersion = 3

    /// Identifies the rates the cached costs were computed at. Rates arriving over
    /// the network means this can't be a constant we remember to bump: it is
    /// derived from the pricing itself, so any change invalidates the cache.
    static func version(pricing: PricingTable) -> String {
        "\(Self.schemaVersion):\(pricing.version)"
    }

    var version: String
    var files: [String: CachedFile] = [:]

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ClaudeBar", isDirectory: true)
            .appendingPathComponent("cost-cache.json")
    }

    static func load(version: String) -> CostCache {
        guard let data = try? Data(contentsOf: self.cacheURL),
              let decoded = try? JSONDecoder().decode(CostCache.self, from: data),
              decoded.version == version
        else { return CostCache(version: version) }
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
