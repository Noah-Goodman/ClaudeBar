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
    /// Models in the window ClaudeBar had no rates for. Their tokens are in the
    /// totals above but their cost is not, so the figures understate by their share.
    let unpricedModels: [String]
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

/// A global hotkey, stored in Carbon's units because `RegisterEventHotKey` takes
/// them directly; `ShortcutRecorder` converts from `NSEvent` at the boundary.
struct KeyCombo: Sendable, Codable, Equatable {
    /// Carbon modifier bits, spelled out so this file stays Foundation-only.
    /// These match HIToolbox's `cmdKey`/`shiftKey`/`optionKey`/`controlKey`.
    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000

    let keyCode: UInt32
    let modifiers: UInt32

    /// A bare key would swallow that keystroke system-wide, which is never what
    /// someone means to configure. Whether the *specific* modifiers are acceptable
    /// is left to the OS: Sequoia rejects shift/option-only combos with -9868, but
    /// 15.2 relaxed that again, so hardcoding the rule here would be wrong on one
    /// version or the other.
    var hasModifier: Bool { self.modifiers != 0 }
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
