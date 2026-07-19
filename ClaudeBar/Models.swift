import Foundation

struct UsageMetric: Sendable, Codable {
    let label: String
    let usedPercent: Int
    let resetsAt: Date?
    let spentDescription: String?
    let isUnlimited: Bool
}

struct CostSnapshot: Sendable, Codable {
    let todayCostUSD: Double
    let todayTokens: Int
    let last30DaysCostUSD: Double
    let last30DaysTokens: Int
}

/// One managed Anthropic account. `id` is the account UUID from the OAuth profile.
struct Account: Sendable, Codable, Identifiable {
    let id: String
    var email: String
    var organizationName: String?
    /// Verbatim JSON of the `oauthAccount` object from ~/.claude.json, captured when
    /// this account was last live; written back on switch so the CLI sees consistent
    /// account metadata.
    var oauthAccountRaw: Data?
    var displayOrder: Int
    var needsRelogin: Bool
}

/// Persisted roster (Application Support/ClaudeBar/accounts.json).
struct AccountsState: Sendable, Codable {
    var accounts: [Account]
    var activeAccountUuid: String?

    static let empty = AccountsState(accounts: [], activeAccountUuid: nil)
}

struct AccountUsage: Sendable, Codable {
    var session: UsageMetric?
    var weekly: UsageMetric?
    var fable: UsageMetric?
    var extraUsage: UsageMetric?
    var fetchedAt: Date
}

/// Persisted usage cache (Caches/ClaudeBar/usage-cache-v2.json).
struct UsageCacheFile: Sendable, Codable {
    var usageByAccount: [String: AccountUsage]
    var cost: CostSnapshot?

    static let empty = UsageCacheFile(usageByAccount: [:], cost: nil)
}

/// Everything the UI needs to render one account row.
struct AccountDisplay: Sendable, Identifiable {
    let account: Account
    let usage: AccountUsage?
    let isActive: Bool
    let isRecommended: Bool
    let isStale: Bool

    var id: String { self.account.id }
}

enum BannerKind: Sendable {
    case info
    case warning
    case error
}

struct Banner: Sendable, Equatable {
    let kind: BannerKind
    let message: String
}

/// Sendable snapshot of AccountManager state handed to the main actor for rendering.
struct AccountsSnapshot: Sendable {
    let displays: [AccountDisplay]
    let banner: Banner?
    let isPendingAdd: Bool
    let cost: CostSnapshot?
    let updatedAt: Date?
}
