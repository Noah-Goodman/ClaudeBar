import CryptoKit
import Foundation
import os

/// Per-million-token rates for one model across the five billed tiers.
struct ModelPricing: Codable, Sendable {
    let input: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double
    let output: Double
}

/// Every model ClaudeBar can price, keyed by normalized model name.
struct PricingTable: Sendable, Codable {
    let rates: [String: ModelPricing]
    let fetchedAt: Date
    /// Identifies this exact set of rates. `CostCache` keys its memoized per-day
    /// costs on it, so a change upstream invalidates the cache on its own.
    let version: String

    init(rates: [String: ModelPricing], fetchedAt: Date) {
        self.rates = rates
        self.fetchedAt = fetchedAt
        self.version = Self.contentHash(for: rates)
    }

    /// Rates for a raw model string as it appears in a log line, or nil when the
    /// model is unknown. Callers must treat nil as unpriced, never as free.
    func pricing(for model: String, isFast: Bool) -> ModelPricing? {
        let name = Self.normalizeModelName(model)
        // Models with no fast-mode premium bill at their standard rate.
        if isFast, let fast = Self.fastPricing[name] { return fast }
        return self.rates[name]
    }

    // MARK: - Fast mode

    /// The LiteLLM feed carries no fast-mode rates — it only flags which models
    /// support the speed setting — so these are the one set of rates ClaudeBar
    /// still states itself. Everything else comes from the feed.
    private static let fastPricing: [String: ModelPricing] = [
        "claude-opus-4-8": ModelPricing(input: 10, cacheWrite5m: 12.50, cacheWrite1h: 20, cacheRead: 1.00, output: 50),
        "claude-opus-4-7": ModelPricing(input: 30, cacheWrite5m: 37.50, cacheWrite1h: 60, cacheRead: 3.00, output: 150),
        "claude-opus-4-6": ModelPricing(input: 30, cacheWrite5m: 37.50, cacheWrite1h: 60, cacheRead: 3.00, output: 150),
    ]

    // MARK: - Naming

    /// Collapses the provider prefixes, date stamps and context annotations that
    /// wrap the same model in logs and in the feed down to one lookup key.
    static func normalizeModelName(_ model: String) -> String {
        var name = model
        if name.hasPrefix("anthropic.") {
            name = String(name.dropFirst("anthropic.".count))
        }
        if let separator = name.lastIndex(of: "/") {
            name = String(name[name.index(after: separator)...])
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

    // MARK: - Versioning

    private static func contentHash(for rates: [String: ModelPricing]) -> String {
        var lines = rates.map { Self.canonicalLine(name: $0.key, pricing: $0.value) }
        lines.append(contentsOf: Self.fastPricing.map {
            Self.canonicalLine(name: "\($0.key)-fast", pricing: $0.value)
        })
        lines.sort()

        var hasher = SHA256()
        for line in lines { hasher.update(data: Data(line.utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private static func canonicalLine(name: String, pricing: ModelPricing) -> String {
        // %.10g so a rate hashes the same however its literal was written.
        String(
            format: "%@|%.10g|%.10g|%.10g|%.10g|%.10g",
            name, pricing.input, pricing.cacheWrite5m, pricing.cacheWrite1h,
            pricing.cacheRead, pricing.output)
    }
}

/// Downloads the LiteLLM pricing feed, distills it to the Anthropic rates, and
/// keeps the result on disk. ClaudeBar ships no base rates of its own, so this is
/// the only thing standing between a log line and a cost.
actor PricingStore {
    static let shared = PricingStore()

    private static let logger = Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "pricing")

    private static let feedURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    /// How long a stored table is served before we look for a newer one.
    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// Floor between fetch attempts once we hold a table, so a model the feed
    /// simply doesn't list can't drive a refetch on every scan.
    private static let backoffWithTable: TimeInterval = 60 * 60
    /// Tighter floor while we hold nothing, so a machine that starts up offline
    /// begins reporting costs soon after it reaches the network.
    private static let backoffWithoutTable: TimeInterval = 5 * 60

    private var table: PricingTable?
    private var lastFetchAttempt: Date?
    private var didLoadFromDisk = false

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    /// The best table available: the stored one until it ages out, then a fresh
    /// fetch. Nil only when nothing has ever been fetched successfully.
    func current() async -> PricingTable? {
        self.loadFromDiskIfNeeded()
        if let table = self.table, Date().timeIntervalSince(table.fetchedAt) < Self.refreshInterval {
            return table
        }
        return await self.fetch() ?? self.table
    }

    /// Re-fetch after a scan met a model the table couldn't price — the feed may
    /// have gained it since. Subject to the same backoff, so repeated scans over
    /// a genuinely unlisted model cost one request an hour at most.
    func refetchForUnknownModel() async -> PricingTable? {
        self.loadFromDiskIfNeeded()
        return await self.fetch() ?? self.table
    }

    private func fetch() async -> PricingTable? {
        if let lastFetchAttempt = self.lastFetchAttempt {
            let backoff = self.table == nil ? Self.backoffWithoutTable : Self.backoffWithTable
            guard Date().timeIntervalSince(lastFetchAttempt) >= backoff else { return nil }
        }
        self.lastFetchAttempt = Date()

        do {
            let (data, response) = try await Self.session.data(from: Self.feedURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else {
                Self.logger.error("Pricing feed returned HTTP \(statusCode, privacy: .public)")
                return nil
            }

            let feed = try JSONDecoder().decode([String: FeedEntry].self, from: data)
            let rates = Self.distill(feed)
            guard !rates.isEmpty else {
                Self.logger.error("Pricing feed carried no usable Anthropic rates")
                return nil
            }

            let table = PricingTable(rates: rates, fetchedAt: Date())
            self.table = table
            Self.store(table)
            Self.logger.info("Loaded rates for \(rates.count, privacy: .public) models (version \(table.version, privacy: .public))")
            return table
        } catch {
            Self.logger.error("Pricing feed fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Feed

    /// The fields of a feed entry ClaudeBar bills on. Every one is optional and
    /// individually tolerant: the feed covers ~3000 models from many providers,
    /// and one malformed entry must not cost us the whole table.
    private struct FeedEntry: Decodable {
        let provider: String?
        let inputCostPerToken: Double?
        let outputCostPerToken: Double?
        let cacheWrite5mCostPerToken: Double?
        let cacheWrite1hCostPerToken: Double?
        let cacheReadCostPerToken: Double?

        private enum CodingKeys: String, CodingKey {
            case provider = "litellm_provider"
            case inputCostPerToken = "input_cost_per_token"
            case outputCostPerToken = "output_cost_per_token"
            case cacheWrite5mCostPerToken = "cache_creation_input_token_cost"
            case cacheWrite1hCostPerToken = "cache_creation_input_token_cost_above_1hr"
            case cacheReadCostPerToken = "cache_read_input_token_cost"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.provider = try? container.decodeIfPresent(String.self, forKey: .provider)
            self.inputCostPerToken = try? container.decodeIfPresent(Double.self, forKey: .inputCostPerToken)
            self.outputCostPerToken = try? container.decodeIfPresent(Double.self, forKey: .outputCostPerToken)
            self.cacheWrite5mCostPerToken = try? container.decodeIfPresent(Double.self, forKey: .cacheWrite5mCostPerToken)
            self.cacheWrite1hCostPerToken = try? container.decodeIfPresent(Double.self, forKey: .cacheWrite1hCostPerToken)
            self.cacheReadCostPerToken = try? container.decodeIfPresent(Double.self, forKey: .cacheReadCostPerToken)
        }
    }

    private static func distill(_ feed: [String: FeedEntry]) -> [String: ModelPricing] {
        let perMillion = 1_000_000.0
        var rates: [String: ModelPricing] = [:]

        for key in feed.keys.sorted() {
            guard let entry = feed[key], entry.provider == "anthropic" else { continue }
            guard let input = entry.inputCostPerToken, let output = entry.outputCostPerToken else { continue }

            let name = PricingTable.normalizeModelName(key)
            guard name.hasPrefix("claude-") else { continue }
            // Dated and undated keys collapse onto the same name at the same rates;
            // iterating sorted keys makes which one lands deterministic.
            guard rates[name] == nil else { continue }

            // Anthropic bills cache writes at 1.25x (5m) and 2x (1h) the input rate,
            // and cache reads at 0.1x. The feed states them outright; the ratios only
            // fill in for the few older models that omit a tier.
            rates[name] = ModelPricing(
                input: input * perMillion,
                cacheWrite5m: (entry.cacheWrite5mCostPerToken ?? input * 1.25) * perMillion,
                cacheWrite1h: (entry.cacheWrite1hCostPerToken ?? input * 2) * perMillion,
                cacheRead: (entry.cacheReadCostPerToken ?? input * 0.1) * perMillion,
                output: output * perMillion)
        }

        return rates
    }

    // MARK: - Disk

    /// Application Support rather than Caches: without a stored table ClaudeBar
    /// cannot price anything at all, so it should survive a cache purge.
    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ClaudeBar", isDirectory: true)
            .appendingPathComponent("pricing.json")
    }

    private func loadFromDiskIfNeeded() {
        guard !self.didLoadFromDisk else { return }
        self.didLoadFromDisk = true
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode(PricingTable.self, from: data)
        else { return }
        self.table = decoded
    }

    private static func store(_ table: PricingTable) {
        let url = self.storeURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(table).write(to: url, options: .atomic)
        } catch {
            self.logger.error("Failed to store pricing table: \(String(describing: error), privacy: .public)")
        }
    }
}
