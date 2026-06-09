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

    func scan() -> CostSnapshot {
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

        var cache = CostCache.load()
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

            let result = Self.parseFile(url: file.url, sinceKey: sinceKey, todayKey: todayKey, seenKeys: &seenMessageKeys)

            cache.files[path] = CachedFile(
                mtimeMs: file.mtimeMs,
                size: file.size,
                days: result.days)

            for day in result.days {
                totalCost += day.value.cost
                totalTokens += day.value.tokens
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
            last30DaysTokens: totalTokens)
    }

    // MARK: - File parsing

    private struct FileParseResult {
        var days: [String: DayUsage]
    }

    private static func parseFile(
        url: URL,
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

            let cost = Self.computeCost(
                model: model,
                isFast: isFast,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWrite5mTokens: cacheWrite5mTokens,
                cacheWrite1hTokens: cacheWrite1hTokens)

            var day = days[dayKey] ?? DayUsage(cost: 0, tokens: 0)
            day.cost += cost
            day.tokens += lineTokens
            days[dayKey] = day
        }

        return FileParseResult(days: days)
    }

    // MARK: - Pricing ($ per million tokens)

    private struct ModelPricing {
        let input: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
        let output: Double
    }

    private static let pricingTable: [String: ModelPricing] = [
        "claude-fable-5":         ModelPricing(input: 10,    cacheWrite5m: 12.50, cacheWrite1h: 20,    cacheRead: 1.00, output: 50),
        "claude-mythos-5":        ModelPricing(input: 10,    cacheWrite5m: 12.50, cacheWrite1h: 20,    cacheRead: 1.00, output: 50),
        "claude-opus-4-8":        ModelPricing(input: 5,     cacheWrite5m: 6.25,  cacheWrite1h: 10,    cacheRead: 0.50, output: 25),
        "claude-opus-4-8-fast":   ModelPricing(input: 10,    cacheWrite5m: 12.50, cacheWrite1h: 20,    cacheRead: 1.00, output: 50),
        "claude-opus-4-7":        ModelPricing(input: 5,     cacheWrite5m: 6.25,  cacheWrite1h: 10,    cacheRead: 0.50, output: 25),
        "claude-opus-4-7-fast":   ModelPricing(input: 30,    cacheWrite5m: 37.50, cacheWrite1h: 60,    cacheRead: 3.00, output: 150),
        "claude-opus-4-6-fast":   ModelPricing(input: 30,    cacheWrite5m: 37.50, cacheWrite1h: 60,    cacheRead: 3.00, output: 150),
        "claude-opus-4-6":        ModelPricing(input: 5,     cacheWrite5m: 6.25,  cacheWrite1h: 10,    cacheRead: 0.50, output: 25),
        "claude-opus-4-5":        ModelPricing(input: 5,     cacheWrite5m: 6.25,  cacheWrite1h: 10,    cacheRead: 0.50, output: 25),
        "claude-opus-4-1":        ModelPricing(input: 15,    cacheWrite5m: 18.75, cacheWrite1h: 30,    cacheRead: 1.50, output: 75),
        "claude-opus-4":          ModelPricing(input: 15,    cacheWrite5m: 18.75, cacheWrite1h: 30,    cacheRead: 1.50, output: 75),
        "claude-opus-3":          ModelPricing(input: 15,    cacheWrite5m: 18.75, cacheWrite1h: 30,    cacheRead: 1.50, output: 75),
        "claude-sonnet-4-6":      ModelPricing(input: 3,     cacheWrite5m: 3.75,  cacheWrite1h: 6,     cacheRead: 0.30, output: 15),
        "claude-sonnet-4-5":      ModelPricing(input: 3,     cacheWrite5m: 3.75,  cacheWrite1h: 6,     cacheRead: 0.30, output: 15),
        "claude-sonnet-4":        ModelPricing(input: 3,     cacheWrite5m: 3.75,  cacheWrite1h: 6,     cacheRead: 0.30, output: 15),
        "claude-sonnet-3-7":      ModelPricing(input: 3,     cacheWrite5m: 3.75,  cacheWrite1h: 6,     cacheRead: 0.30, output: 15),
        "claude-haiku-4-5":       ModelPricing(input: 1,     cacheWrite5m: 1.25,  cacheWrite1h: 2,     cacheRead: 0.10, output: 5),
        "claude-haiku-3-5":       ModelPricing(input: 0.80,  cacheWrite5m: 1,     cacheWrite1h: 1.60,  cacheRead: 0.08, output: 4),
        "claude-haiku-3":         ModelPricing(input: 0.25,  cacheWrite5m: 0.30,  cacheWrite1h: 0.50,  cacheRead: 0.03, output: 1.25),
    ]

    private static func computeCost(
        model: String,
        isFast: Bool,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWrite5mTokens: Int,
        cacheWrite1hTokens: Int) -> Double
    {
        let normalizedModel = Self.normalizeModel(model)
        // Fast-mode rates live under a "-fast" key; fall back to the standard rate
        // for models that have no dedicated fast-mode pricing.
        let pricingKey = isFast ? "\(normalizedModel)-fast" : normalizedModel
        guard let pricing = self.pricingTable[pricingKey] ?? self.pricingTable[normalizedModel] else { return 0 }

        let perToken = 1.0 / 1_000_000
        return Double(inputTokens) * pricing.input * perToken
            + Double(outputTokens) * pricing.output * perToken
            + Double(cacheWrite5mTokens) * pricing.cacheWrite5m * perToken
            + Double(cacheWrite1hTokens) * pricing.cacheWrite1h * perToken
            + Double(cacheReadTokens) * pricing.cacheRead * perToken
    }

    private static func normalizeModel(_ model: String) -> String {
        var name = model
        if name.hasPrefix("anthropic.") {
            name = String(name.dropFirst("anthropic.".count))
        }
        name = name.replacingOccurrences(of: "@", with: "-")

        // Strip a trailing context-window annotation like "[1m]" first, so
        // claude-opus-4-8[1m] normalizes to claude-opus-4-8 (1M context bills at standard rates).
        let suffixes = [#"\[[^\]]*\]$"#, #"-\d{8}$"#, #"-v\d+:\d+$"#]
        for pattern in suffixes {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
               let matchRange = Range(match.range, in: name)
            {
                name = String(name[name.startIndex..<matchRange.lowerBound])
            }
        }

        // claude-3-5-sonnet -> claude-sonnet-3-5 (old naming convention)
        let reorder = try? NSRegularExpression(pattern: #"^claude-(\d+(?:-\d+)?)-(\w+)$"#)
        if let match = reorder?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let versionRange = Range(match.range(at: 1), in: name),
           let familyRange = Range(match.range(at: 2), in: name)
        {
            let version = String(name[versionRange])
            let family = String(name[familyRange])
            if ["opus", "sonnet", "haiku"].contains(family) {
                name = "claude-\(family)-\(version)"
            }
        }

        return name
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
}

struct CachedFile: Codable {
    let mtimeMs: Int64
    let size: Int64
    let days: [String: DayUsage]
}

struct CostCache: Codable {
    // Bump whenever the pricing table changes so stale per-file costs are recomputed
    // instead of being served from cache at the old rates.
    static let currentPricingVersion = 2
    var pricingVersion = Self.currentPricingVersion
    var files: [String: CachedFile] = [:]

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ClaudeBar", isDirectory: true)
            .appendingPathComponent("cost-cache.json")
    }

    static func load() -> CostCache {
        guard let data = try? Data(contentsOf: self.cacheURL),
              let decoded = try? JSONDecoder().decode(CostCache.self, from: data),
              decoded.pricingVersion == Self.currentPricingVersion
        else { return CostCache() }
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
