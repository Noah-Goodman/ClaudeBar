import Foundation
import os

/// Owns the account roster, per-account usage cache, and the live Claude Code
/// credential item. All keychain blobs are treated as opaque `Data`: only the
/// token fields inside `claudeAiOauth` are ever mutated, so unknown fields
/// (e.g. `mcpOAuth`) survive round-trips.
actor AccountManager {
    static let shared = AccountManager()

    private let logger = Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "accounts")

    private var state: AccountsState
    private var cache: UsageCacheFile
    private var errorBanner: Banner?
    private var infoBanner: Banner?
    private var infoBannerExpiresAt: Date?
    private var pendingAddUntil: Date?
    private var clobberRepairsByUuid: [String: [Date]] = [:]
    private var isFetching = false

    /// Keychain read caches. Every SecItem read can trigger a user-facing
    /// permission prompt, so a refresh cycle must hit each item at most once.
    /// The roster item is only ever written by ClaudeBar, so its cache never
    /// expires; the live item is shared with the claude CLI and gets a short TTL.
    private var liveBlobCache: (blob: Data, readAt: Date)?
    private var rosterBlobs: [String: Data]?
    private var rosterLoadError: KeychainError?
    private static let liveBlobCacheTTL: TimeInterval = 5

    private static let activeStaleInterval: TimeInterval = 5 * 60
    private static let inactiveStaleInterval: TimeInterval = 15 * 60
    private static let pendingAddDuration: TimeInterval = 10 * 60
    private static let expiryRefreshMargin: TimeInterval = 5 * 60
    private static let clobberWindow: TimeInterval = 10 * 60
    private static let clobberCap = 3

    init() {
        self.state = Self.loadState()
        self.cache = Self.loadCache()
    }

    // MARK: - Snapshot for UI

    func snapshot() -> AccountsSnapshot {
        let now = Date()
        let ordered = self.state.accounts.sorted { $0.displayOrder < $1.displayOrder }
        let recommendedId = ordered.count > 1
            ? Self.recommendedAccountId(accounts: ordered, usageByAccount: self.cache.usageByAccount)
            : nil

        let displays = ordered.map { account -> AccountDisplay in
            let usage = self.cache.usageByAccount[account.id]
            let isActive = account.id == self.state.activeAccountUuid
            let staleAfter = isActive ? Self.activeStaleInterval : Self.inactiveStaleInterval
            let isStale = usage.map { now.timeIntervalSince($0.fetchedAt) > staleAfter } ?? true
            return AccountDisplay(
                account: account,
                usage: usage,
                isActive: isActive,
                isRecommended: account.id == recommendedId,
                isStale: isStale)
        }

        if let expiresAt = self.infoBannerExpiresAt, expiresAt < now {
            self.infoBanner = nil
            self.infoBannerExpiresAt = nil
        }

        let activeUsage = self.state.activeAccountUuid.flatMap { self.cache.usageByAccount[$0] }
        let updatedAt = activeUsage?.fetchedAt
            ?? self.cache.usageByAccount.values.map(\.fetchedAt).max()

        return AccountsSnapshot(
            displays: displays,
            banner: self.errorBanner ?? self.infoBanner,
            isPendingAdd: self.isPendingAdd,
            cost: self.cache.cost,
            updatedAt: updatedAt)
    }

    var isPendingAdd: Bool {
        guard let until = self.pendingAddUntil else { return false }
        return until > Date()
    }

    // MARK: - Reconcile

    /// Compares the live credential item against the roster and resolves any
    /// divergence: adopt external switches, harvest CLI-side token refreshes,
    /// repair clobbers from lingering sessions, and capture brand-new logins.
    func reconcile() async {
        let liveBlob: Data
        do {
            liveBlob = try self.readLiveBlobCached()
        } catch KeychainError.notFound {
            self.errorBanner = Banner(
                kind: .warning,
                message: "No Claude Code login found. Run claude and /login first.")
            return
        } catch KeychainError.accessDenied, KeychainError.cancelled {
            self.errorBanner = Banner(
                kind: .error,
                message: "Keychain access denied. Allow ClaudeBar to read the Claude Code credentials.")
            return
        } catch {
            self.errorBanner = Banner(kind: .error, message: "Keychain read failed: \(error)")
            return
        }

        guard let liveTokens = Self.parseTokens(from: liveBlob) else {
            self.errorBanner = Banner(
                kind: .warning,
                message: "Claude Code credentials look empty. Run claude and /login.")
            return
        }

        // In sync with the active account — the common case, no network needed.
        if let activeUuid = self.state.activeAccountUuid,
           let storedBlob = try? self.readRosterBlob(for: activeUuid),
           let storedTokens = Self.parseTokens(from: storedBlob),
           storedTokens.accessToken == liveTokens.accessToken
        {
            self.errorBanner = nil
            return
        }

        // Token matches another roster account: the user switched outside ClaudeBar.
        // Adopt it — reflect reality, never fight it.
        for account in self.state.accounts where account.id != self.state.activeAccountUuid {
            guard let storedBlob = try? self.readRosterBlob(for: account.id),
                  let storedTokens = Self.parseTokens(from: storedBlob),
                  storedTokens.accessToken == liveTokens.accessToken
            else { continue }
            self.logger.info("Adopting externally-switched account \(account.email, privacy: .private)")
            self.state.activeAccountUuid = account.id
            self.errorBanner = nil
            self.saveState()
            return
        }

        // Unknown token: identify who it belongs to.
        var workingBlob = liveBlob
        var workingTokens = liveTokens
        let profile: OAuthProfile
        do {
            profile = try await self.fetchProfileRefreshingIfNeeded(blob: &workingBlob, tokens: &workingTokens)
        } catch APIError.unauthorized, APIError.invalidGrant {
            self.errorBanner = Banner(
                kind: .warning,
                message: "Claude login expired. Run claude and /login to sign in again.")
            return
        } catch {
            // Network trouble — leave everything as-is and try again next tick.
            self.logger.info("Reconcile profile fetch failed transiently: \(String(describing: error), privacy: .public)")
            return
        }

        guard let uuid = profile.account?.uuid else {
            self.logger.error("Profile response had no account uuid")
            return
        }

        if uuid == self.state.activeAccountUuid {
            // The CLI refreshed the active account's tokens; harvest them.
            self.storeRosterBlob(workingBlob, for: uuid)
            self.setNeedsRelogin(false, for: uuid)
            self.refreshOauthAccountSnapshot(for: uuid)
            self.errorBanner = nil
            self.saveState()
            return
        }

        if self.state.accounts.contains(where: { $0.id == uuid }) {
            if self.state.activeAccountUuid == nil
                || !self.state.accounts.contains(where: { $0.id == self.state.activeAccountUuid })
            {
                // No coherent active account to defend — adopt instead of repairing.
                self.storeRosterBlob(workingBlob, for: uuid)
                self.setNeedsRelogin(false, for: uuid)
                self.state.activeAccountUuid = uuid
                self.errorBanner = nil
                self.saveState()
                return
            }
            self.repairClobber(byAccount: uuid, freshBlob: workingBlob)
            return
        }

        await self.captureNewAccount(uuid: uuid, profile: profile, blob: workingBlob)
    }

    /// A lingering claude session on old account X refreshed its token over our
    /// swap. Save X's fresh tokens first (rotation orphaned the previous ones),
    /// then restore the intended active account into the live item.
    private func repairClobber(byAccount clobberUuid: String, freshBlob: Data) {
        let now = Date()
        var repairs = (self.clobberRepairsByUuid[clobberUuid] ?? [])
            .filter { now.timeIntervalSince($0) < Self.clobberWindow }

        let clobberEmail = self.state.accounts.first(where: { $0.id == clobberUuid })?.email ?? "another account"

        // Freshest tokens always get saved, even when we stop repairing.
        self.storeRosterBlob(freshBlob, for: clobberUuid)
        self.setNeedsRelogin(false, for: clobberUuid)
        self.saveState()

        guard repairs.count < Self.clobberCap else {
            self.errorBanner = Banner(
                kind: .warning,
                message: "A running claude session keeps re-authenticating \(clobberEmail). Close it, then Switch again.")
            return
        }

        guard let activeUuid = self.state.activeAccountUuid,
              let activeBlob = try? self.readRosterBlob(for: activeUuid)
        else { return }

        do {
            try self.writeLiveBlobTracked(activeBlob)
        } catch {
            self.errorBanner = Banner(kind: .error, message: "Keychain write failed: \(error)")
            return
        }
        self.patchClaudeJson(oauthAccountRaw: self.state.accounts.first(where: { $0.id == activeUuid })?.oauthAccountRaw)

        repairs.append(now)
        self.clobberRepairsByUuid[clobberUuid] = repairs
        self.logger.info("Repaired credential clobber by \(clobberEmail, privacy: .private) (\(repairs.count)/\(Self.clobberCap))")
    }

    /// Implements both first-launch auto-capture and the guided Add Account flow.
    private func captureNewAccount(uuid: String, profile: OAuthProfile, blob: Data) async {
        let email = profile.account?.email ?? "unknown@unknown"
        let account = Account(
            id: uuid,
            email: email,
            organizationName: profile.organization?.name,
            oauthAccountRaw: Self.readOauthAccountRaw(matching: uuid),
            displayOrder: (self.state.accounts.map(\.displayOrder).max() ?? -1) + 1,
            needsRelogin: false)

        self.storeRosterBlob(blob, for: uuid)
        self.state.accounts.append(account)
        self.state.activeAccountUuid = uuid
        self.pendingAddUntil = nil
        self.errorBanner = nil
        self.saveState()
        self.logger.info("Captured account \(email, privacy: .private)")

        await self.fetchUsage(for: account, isActive: true)
        self.saveCache()
    }

    private func fetchProfileRefreshingIfNeeded(
        blob: inout Data, tokens: inout OAuthTokens) async throws -> OAuthProfile
    {
        do {
            return try await AnthropicAPI.fetchProfile(accessToken: tokens.accessToken)
        } catch APIError.unauthorized {
            guard let refreshToken = tokens.refreshToken else { throw APIError.unauthorized }
            let refreshed = try await AnthropicAPI.refresh(refreshToken: refreshToken)
            guard let newBlob = Self.applyRefresh(refreshed, to: blob),
                  let newTokens = Self.parseTokens(from: newBlob)
            else { throw APIError.decode(message: "Could not apply refreshed tokens") }
            try self.writeLiveBlobTracked(newBlob)
            blob = newBlob
            tokens = newTokens
            return try await AnthropicAPI.fetchProfile(accessToken: newTokens.accessToken)
        }
    }

    // MARK: - Switch

    /// Swaps the live credential item to `target`. Returns false (with a banner)
    /// when the switch could not complete.
    @discardableResult
    func switchTo(accountUuid target: String) async -> Bool {
        await self.reconcile()

        guard let index = self.state.accounts.firstIndex(where: { $0.id == target }) else { return false }
        if self.state.activeAccountUuid == target { return true }
        let email = self.state.accounts[index].email

        var blob: Data
        do {
            blob = try self.readRosterBlob(for: target)
        } catch {
            self.errorBanner = Banner(kind: .error, message: "No stored credentials for \(email): \(error)")
            return false
        }
        guard var tokens = Self.parseTokens(from: blob) else {
            self.errorBanner = Banner(kind: .error, message: "Stored credentials for \(email) are unreadable.")
            return false
        }

        // Refresh ahead of the swap when the token is about to expire, so the CLI
        // starts with a working token. A needsRelogin account skips this: writing
        // its stale blob is intentional — the CLI will prompt /login and reconcile
        // harvests the result.
        let needsRelogin = self.state.accounts[index].needsRelogin
        let expiringSoon = tokens.expiresAt.map { $0 < Date().addingTimeInterval(Self.expiryRefreshMargin) } ?? false
        if expiringSoon && !needsRelogin {
            if let refreshToken = tokens.refreshToken {
                do {
                    let refreshed = try await AnthropicAPI.refresh(refreshToken: refreshToken)
                    guard let newBlob = Self.applyRefresh(refreshed, to: blob),
                          let newTokens = Self.parseTokens(from: newBlob)
                    else {
                        self.errorBanner = Banner(kind: .error, message: "Could not apply refreshed tokens for \(email).")
                        return false
                    }
                    // Store first: if the live write fails, the rotated tokens must not be lost.
                    self.storeRosterBlob(newBlob, for: target)
                    blob = newBlob
                    tokens = newTokens
                } catch APIError.invalidGrant, APIError.unauthorized {
                    self.state.accounts[index].needsRelogin = true
                    self.saveState()
                    self.errorBanner = Banner(
                        kind: .warning,
                        message: "\(email) needs a re-login. Switch again, then run claude and /login.")
                    return false
                } catch {
                    self.errorBanner = Banner(kind: .error, message: "Token refresh for \(email) failed: \(error)")
                    return false
                }
            } else {
                self.state.accounts[index].needsRelogin = true
                self.saveState()
            }
        }

        do {
            try self.writeLiveBlobTracked(blob)
        } catch {
            self.errorBanner = Banner(kind: .error, message: "Keychain write failed: \(error)")
            return false
        }
        self.patchClaudeJson(oauthAccountRaw: self.state.accounts[index].oauthAccountRaw)

        self.state.activeAccountUuid = target
        self.clobberRepairsByUuid = [:]
        self.errorBanner = nil
        self.infoBanner = Banner(
            kind: .info,
            message: "Switched to \(email).")
        self.infoBannerExpiresAt = Date().addingTimeInterval(2 * 60)
        self.saveState()

        await self.reconcile()
        return true
    }

    // MARK: - Add / Remove

    func beginAddAccount() {
        self.pendingAddUntil = Date().addingTimeInterval(Self.pendingAddDuration)
    }

    func cancelAddAccount() {
        self.pendingAddUntil = nil
    }

    /// Refuses to remove the active account. Returns false when refused.
    @discardableResult
    func removeAccount(accountUuid: String) -> Bool {
        guard accountUuid != self.state.activeAccountUuid else { return false }
        guard let index = self.state.accounts.firstIndex(where: { $0.id == accountUuid }) else { return false }
        self.removeRosterBlob(for: accountUuid)
        self.state.accounts.remove(at: index)
        self.cache.usageByAccount.removeValue(forKey: accountUuid)
        self.clobberRepairsByUuid.removeValue(forKey: accountUuid)
        self.saveState()
        self.saveCache()
        return true
    }

    // MARK: - Usage fetching

    /// Fetches usage for stale accounts, active first, sequentially with a ~1s
    /// stagger — never parallel bursts against the API.
    func refreshUsage(force: Bool = false) async {
        guard !self.isFetching else { return }
        self.isFetching = true
        defer { self.isFetching = false }

        let now = Date()
        let ordered = self.state.accounts.sorted {
            let lhsActive = $0.id == self.state.activeAccountUuid
            let rhsActive = $1.id == self.state.activeAccountUuid
            if lhsActive != rhsActive { return lhsActive }
            return $0.displayOrder < $1.displayOrder
        }

        var fetchedAny = false
        for account in ordered {
            let isActive = account.id == self.state.activeAccountUuid
            let staleAfter = isActive ? Self.activeStaleInterval : Self.inactiveStaleInterval
            if !force,
               let cached = self.cache.usageByAccount[account.id],
               now.timeIntervalSince(cached.fetchedAt) < staleAfter
            {
                continue
            }
            if account.needsRelogin { continue }
            if fetchedAny {
                try? await Task.sleep(for: .seconds(1))
            }
            await self.fetchUsage(for: account, isActive: isActive)
            fetchedAny = true
        }
        if fetchedAny {
            self.saveCache()
            self.saveState()
        }
    }

    private func fetchUsage(for account: Account, isActive: Bool) async {
        // The active account's token comes from the live item — the CLI keeps it
        // fresh. Inactive accounts use their roster blob.
        var blob: Data
        do {
            blob = isActive
                ? try self.readLiveBlobCached()
                : try self.readRosterBlob(for: account.id)
        } catch {
            self.logger.error("Credential read for \(account.email, privacy: .private) failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard var tokens = Self.parseTokens(from: blob) else { return }

        // Refresh only when actually expired; the CLI owns routine refreshes of
        // the active account.
        if let expiresAt = tokens.expiresAt, expiresAt <= Date() {
            switch await self.refreshTokens(blob: &blob, tokens: &tokens, for: account, isActive: isActive) {
            case .refreshed: break
            case .needsRelogin, .transientFailure: return
            }
        }

        do {
            let raw = try await AnthropicAPI.fetchUsage(accessToken: tokens.accessToken)
            self.cache.usageByAccount[account.id] = Self.mapUsage(raw, fetchedAt: Date())
            self.setNeedsRelogin(false, for: account.id)
        } catch APIError.unauthorized {
            switch await self.refreshTokens(blob: &blob, tokens: &tokens, for: account, isActive: isActive) {
            case .refreshed:
                do {
                    let raw = try await AnthropicAPI.fetchUsage(accessToken: tokens.accessToken)
                    self.cache.usageByAccount[account.id] = Self.mapUsage(raw, fetchedAt: Date())
                    self.setNeedsRelogin(false, for: account.id)
                } catch APIError.unauthorized {
                    self.setNeedsRelogin(true, for: account.id)
                } catch {
                    self.logger.info("Usage retry for \(account.email, privacy: .private) failed: \(String(describing: error), privacy: .public)")
                }
            case .needsRelogin, .transientFailure:
                return
            }
        } catch APIError.rateLimited {
            self.logger.info("Rate limited fetching usage for \(account.email, privacy: .private); skipping cycle")
        } catch {
            // Network or server trouble: keep the cache, snapshot() marks it stale.
            self.logger.info("Usage fetch for \(account.email, privacy: .private) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private enum RefreshOutcome {
        case refreshed
        case needsRelogin
        case transientFailure
    }

    private func refreshTokens(
        blob: inout Data, tokens: inout OAuthTokens,
        for account: Account, isActive: Bool) async -> RefreshOutcome
    {
        guard let refreshToken = tokens.refreshToken else {
            self.setNeedsRelogin(true, for: account.id)
            return .needsRelogin
        }
        do {
            let refreshed = try await AnthropicAPI.refresh(refreshToken: refreshToken)
            guard let newBlob = Self.applyRefresh(refreshed, to: blob),
                  let newTokens = Self.parseTokens(from: newBlob)
            else { return .transientFailure }
            // Persist rotated tokens before using them — rotation orphans the old ones.
            if isActive {
                do {
                    try self.writeLiveBlobTracked(newBlob)
                } catch {
                    self.logger.error("Live keychain write after refresh failed: \(String(describing: error), privacy: .public)")
                    return .transientFailure
                }
            }
            self.storeRosterBlob(newBlob, for: account.id)
            blob = newBlob
            tokens = newTokens
            return .refreshed
        } catch APIError.invalidGrant, APIError.unauthorized {
            self.setNeedsRelogin(true, for: account.id)
            return .needsRelogin
        } catch {
            self.logger.info("Token refresh for \(account.email, privacy: .private) failed: \(String(describing: error), privacy: .public)")
            return .transientFailure
        }
    }

    func recordCost(_ cost: CostSnapshot) {
        self.cache.cost = cost
        self.saveCache()
    }

    // MARK: - Recommendation

    /// Among accounts with usage data that don't need a re-login, the soonest
    /// weekly reset wins; weekly always dominates. Ties break on the soonest
    /// session reset. Accounts with no weekly reset sort last.
    static func recommendedAccountId(
        accounts: [Account], usageByAccount: [String: AccountUsage]) -> String?
    {
        let farFuture = Date.distantFuture
        let candidates = accounts.compactMap { account -> (id: String, weekly: Date, session: Date)? in
            guard !account.needsRelogin, let usage = usageByAccount[account.id] else { return nil }
            return (
                id: account.id,
                weekly: usage.weekly?.resetsAt ?? farFuture,
                session: usage.session?.resetsAt ?? farFuture)
        }
        return candidates.min { lhs, rhs in
            if lhs.weekly != rhs.weekly { return lhs.weekly < rhs.weekly }
            return lhs.session < rhs.session
        }?.id
    }

    // MARK: - Usage mapping

    static func mapUsage(_ raw: OAuthUsage, fetchedAt: Date) -> AccountUsage {
        var session: UsageMetric?
        var weekly: UsageMetric?
        var fable: UsageMetric?

        func metric(label: String, percent: Double, resetsAt: Date?) -> UsageMetric {
            UsageMetric(
                label: label,
                usedPercent: Int(max(0, min(100, percent)).rounded()),
                resetsAt: resetsAt,
                spentDescription: nil,
                isUnlimited: false)
        }

        for limit in raw.limits ?? [] {
            guard let percent = limit.percent else { continue }
            switch limit.kind {
            case "session":
                session = metric(label: "Session", percent: percent, resetsAt: limit.resetsAt)
            case "weekly_all":
                weekly = metric(label: "Weekly", percent: percent, resetsAt: limit.resetsAt)
            case "weekly_scoped":
                let label = limit.scope?.model?.displayName ?? "Model"
                fable = metric(label: label, percent: percent, resetsAt: limit.resetsAt)
            default:
                break
            }
        }

        if session == nil, let window = raw.fiveHour, let utilization = window.utilization {
            session = metric(label: "Session", percent: utilization, resetsAt: window.resetsAt)
        }
        if weekly == nil, let window = raw.sevenDay, let utilization = window.utilization {
            weekly = metric(label: "Weekly", percent: utilization, resetsAt: window.resetsAt)
        }
        if fable == nil, let window = raw.sevenDayOpus, let utilization = window.utilization {
            fable = metric(label: "Opus", percent: utilization, resetsAt: window.resetsAt)
        }

        var extraUsage: UsageMetric?
        if let extra = raw.extraUsage, extra.isEnabled == true {
            let divisor = pow(10.0, Double(extra.decimalPlaces ?? 2))
            var spent: String?
            if let used = extra.usedCredits, let limit = extra.monthlyLimit, limit > 0 {
                spent = String(
                    format: "$%.2f / $%.2f spent", used / divisor, limit / divisor)
            }
            extraUsage = UsageMetric(
                label: "Extra Usage",
                usedPercent: Int(max(0, min(100, extra.utilization ?? 0)).rounded()),
                resetsAt: nil,
                spentDescription: spent,
                isUnlimited: false)
        }

        return AccountUsage(
            session: session, weekly: weekly, fable: fable,
            extraUsage: extraUsage, fetchedAt: fetchedAt)
    }

    // MARK: - Credential blob handling

    private struct OAuthTokens {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    private static func parseTokens(from blob: Data) -> OAuthTokens? {
        guard let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt)
    }

    /// Rewrites only the token fields inside `claudeAiOauth`, leaving every other
    /// field of the blob untouched.
    private static func applyRefresh(_ refreshed: RefreshedTokens, to blob: Data) -> Data? {
        guard let accessToken = refreshed.accessToken,
              var root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any]
        else { return nil }
        oauth["accessToken"] = accessToken
        if let refreshToken = refreshed.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresIn = refreshed.expiresIn {
            oauth["expiresAt"] = ((Date().timeIntervalSince1970 + expiresIn) * 1000).rounded()
        }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root)
    }

    private func readLiveBlobCached() throws -> Data {
        if let cached = self.liveBlobCache,
           Date().timeIntervalSince(cached.readAt) < Self.liveBlobCacheTTL
        {
            return cached.blob
        }
        let blob = try KeychainStore.readLiveBlob()
        self.liveBlobCache = (blob, Date())
        return blob
    }

    private func writeLiveBlobTracked(_ blob: Data) throws {
        try KeychainStore.writeLiveBlob(blob)
        self.liveBlobCache = (blob, Date())
    }

    /// Loads the roster item once per launch. A missing item means an empty
    /// roster; access-denied propagates so a denied prompt never gets mistaken
    /// for "no accounts" (persisting on top of that would lose stored blobs).
    /// A failed load is cached for the session: retrying every cycle would
    /// turn one denied prompt into an endless prompt loop.
    private func loadRosterBlobs() throws -> [String: Data] {
        if let rosterBlobs = self.rosterBlobs { return rosterBlobs }
        if let error = self.rosterLoadError { throw error }
        do {
            let data = try KeychainStore.readRoster()
            let decoded = (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
            self.rosterBlobs = decoded
            return decoded
        } catch KeychainError.notFound {
            self.rosterBlobs = [:]
            return [:]
        } catch let error as KeychainError {
            self.rosterLoadError = error
            self.errorBanner = Banner(
                kind: .error,
                message: "ClaudeBar can't read its stored accounts (\(error)). Quit and reopen ClaudeBar to retry.")
            throw error
        }
    }

    private func readRosterBlob(for uuid: String) throws -> Data {
        guard let blob = try self.loadRosterBlobs()[uuid] else { throw KeychainError.notFound }
        return blob
    }

    private func storeRosterBlob(_ blob: Data, for uuid: String) {
        guard var blobs = try? self.loadRosterBlobs() else {
            self.logger.error("Roster keychain read failed; not persisting blob for \(uuid, privacy: .public)")
            return
        }
        blobs[uuid] = blob
        self.persistRosterBlobs(blobs)
    }

    private func removeRosterBlob(for uuid: String) {
        guard var blobs = try? self.loadRosterBlobs(), blobs[uuid] != nil else { return }
        blobs.removeValue(forKey: uuid)
        self.persistRosterBlobs(blobs)
    }

    private func persistRosterBlobs(_ blobs: [String: Data]) {
        self.rosterBlobs = blobs
        do {
            let data = try JSONEncoder().encode(blobs)
            try KeychainStore.writeRoster(data)
        } catch {
            self.logger.error("Roster keychain write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func setNeedsRelogin(_ value: Bool, for uuid: String) {
        guard let index = self.state.accounts.firstIndex(where: { $0.id == uuid }),
              self.state.accounts[index].needsRelogin != value
        else { return }
        self.state.accounts[index].needsRelogin = value
        self.saveState()
    }

    // MARK: - ~/.claude.json

    private static var claudeJsonURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    /// The `oauthAccount` object from ~/.claude.json, verbatim, if it belongs to
    /// the given account.
    private static func readOauthAccountRaw(matching uuid: String) -> Data? {
        guard let data = try? Data(contentsOf: self.claudeJsonURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthAccount = root["oauthAccount"] as? [String: Any],
              oauthAccount["accountUuid"] as? String == uuid
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: oauthAccount)
    }

    private func refreshOauthAccountSnapshot(for uuid: String) {
        guard let raw = Self.readOauthAccountRaw(matching: uuid),
              let index = self.state.accounts.firstIndex(where: { $0.id == uuid })
        else { return }
        self.state.accounts[index].oauthAccountRaw = raw
    }

    /// Read-modify-write touching only the `oauthAccount` key. Failures are
    /// non-fatal: the CLI rebuilds this metadata on its own after a session.
    private func patchClaudeJson(oauthAccountRaw: Data?) {
        guard let raw = oauthAccountRaw else { return }
        let url = Self.claudeJsonURL
        do {
            let data = try Data(contentsOf: url)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw APIError.decode(message: "~/.claude.json is not an object")
            }
            root["oauthAccount"] = try JSONSerialization.jsonObject(with: raw)
            let output = try JSONSerialization.data(withJSONObject: root)
            try output.write(to: url, options: .atomic)
        } catch {
            self.logger.error("Patching ~/.claude.json failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Persistence

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ClaudeBar", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ClaudeBar", isDirectory: true)
            .appendingPathComponent("usage-cache-v2.json")
    }

    private static func loadState() -> AccountsState {
        guard let data = try? Data(contentsOf: self.stateURL),
              let decoded = try? JSONDecoder().decode(AccountsState.self, from: data)
        else { return .empty }
        return decoded
    }

    private static func loadCache() -> UsageCacheFile {
        guard let data = try? Data(contentsOf: self.cacheURL),
              let decoded = try? JSONDecoder().decode(UsageCacheFile.self, from: data)
        else { return .empty }
        return decoded
    }

    private func saveState() {
        Self.save(self.state, to: Self.stateURL)
    }

    private func saveCache() {
        Self.save(self.cache, to: Self.cacheURL)
    }

    private static func save<Value: Encodable>(_ value: Value, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "accounts")
                .error("Persist to \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
