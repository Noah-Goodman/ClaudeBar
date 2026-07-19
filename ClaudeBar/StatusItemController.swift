import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var refreshTask: Task<Void, Never>?
    private var pendingAddTask: Task<Void, Never>?
    private var snapshot: AccountsSnapshot?
    private var scanProgress: ScanProgress?
    private var isRefreshing = false
    private var lastCostScanAt: Date?
    private let onCheckForUpdates: (() -> Void)?

    private static let costScanInterval: TimeInterval = 15 * 60

    init(onCheckForUpdates: (() -> Void)? = nil) {
        self.onCheckForUpdates = onCheckForUpdates
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()
        self.menu.delegate = self
        self.statusItem.menu = self.menu

        self.setIcon(sessionUsed: nil, weeklyUsed: nil, stale: true)
        self.rebuildMenu()
        self.startPolling()
    }

    private func rebuildMenu() {
        self.menu.removeAllItems()

        let cardView = UsageCardView(
            snapshot: self.snapshot,
            scanProgress: self.scanProgress,
            isRefreshing: self.isRefreshing,
            launchAtLogin: SMAppService.mainApp.status == .enabled,
            onToggleLaunchAtLogin: { [weak self] in Task { self?.toggleLaunchAtLogin() } },
            onRefresh: { [weak self] in Task { await self?.fetchAndUpdate(force: true) } },
            onSwitch: { [weak self] accountUuid in Task { await self?.switchTo(accountUuid) } },
            onAddAccount: { [weak self] in Task { await self?.beginAddAccount() } },
            onCancelAddAccount: { [weak self] in Task { await self?.cancelAddAccount() } },
            onRemove: { [weak self] accountUuid, email in
                Task { await self?.confirmAndRemove(accountUuid: accountUuid, email: email) }
            },
            onCheckForUpdates: self.onCheckForUpdates,
            onQuit: { NSApplication.shared.terminate(nil) })
        let hostingView = NSHostingView(rootView: cardView)
        hostingView.frame.size = hostingView.fittingSize

        let menuItem = NSMenuItem()
        menuItem.view = hostingView
        self.menu.addItem(menuItem)
    }

    private func setIcon(sessionUsed: Double?, weeklyUsed: Double?, stale: Bool) {
        self.statusItem.button?.image = IconRenderer.makeIcon(
            sessionUsed: sessionUsed,
            weeklyUsed: weeklyUsed,
            stale: stale)
    }

    /// Icon reflects the ACTIVE account only.
    private func applyIcon() {
        guard let active = self.snapshot?.displays.first(where: \.isActive),
              let usage = active.usage
        else {
            self.setIcon(sessionUsed: nil, weeklyUsed: nil, stale: true)
            return
        }
        self.setIcon(
            sessionUsed: usage.session.map { Double($0.usedPercent) },
            weeklyUsed: usage.weekly.map { Double($0.usedPercent) },
            stale: active.isStale)
    }

    private func startPolling() {
        self.refreshTask = Task { [weak self] in
            await self?.bootstrap()
            await self?.fetchAndUpdate(force: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.fetchAndUpdate(force: false)
            }
        }
    }

    /// Instant render from the persisted cache before any network round-trip.
    private func bootstrap() async {
        self.snapshot = await AccountManager.shared.snapshot()
        self.applyIcon()
        self.rebuildMenu()
    }

    private func fetchAndUpdate(force: Bool) async {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        self.rebuildMenu()
        defer {
            self.isRefreshing = false
            self.rebuildMenu()
        }

        await AccountManager.shared.reconcile()
        await AccountManager.shared.refreshUsage(force: force)
        await self.refreshSnapshot()

        let costIsDue = self.lastCostScanAt.map {
            Date().timeIntervalSince($0) > Self.costScanInterval
        } ?? true
        if force || costIsDue {
            await self.runCostScan()
        }
    }

    private func refreshSnapshot() async {
        self.snapshot = await AccountManager.shared.snapshot()
        self.applyIcon()
        self.rebuildMenu()
        if self.snapshot?.isPendingAdd == true {
            self.startPendingAddLoop()
        }
    }

    private func runCostScan() async {
        let progressTask = Task { [weak self] in
            for await progress in CostScanner.shared.progressStream {
                await MainActor.run {
                    guard let self, !progress.isComplete else { return }
                    self.scanProgress = progress
                    self.rebuildMenu()
                }
            }
        }

        let cost = await Task.detached { CostScanner.shared.scan() }.value
        progressTask.cancel()
        self.scanProgress = nil
        self.lastCostScanAt = Date()

        await AccountManager.shared.recordCost(cost)
        self.snapshot = await AccountManager.shared.snapshot()
        self.rebuildMenu()
    }

    // MARK: - Account actions

    private func switchTo(_ accountUuid: String) async {
        self.isRefreshing = true
        self.rebuildMenu()
        await AccountManager.shared.switchTo(accountUuid: accountUuid)
        await AccountManager.shared.refreshUsage(force: false)
        self.isRefreshing = false
        await self.refreshSnapshot()
    }

    private func beginAddAccount() async {
        await AccountManager.shared.beginAddAccount()
        await self.refreshSnapshot()
    }

    private func cancelAddAccount() async {
        await AccountManager.shared.cancelAddAccount()
        self.pendingAddTask?.cancel()
        self.pendingAddTask = nil
        await self.refreshSnapshot()
    }

    /// While an add is pending, reconcile every 5s so the new login is detected
    /// moments after the user finishes /login.
    private func startPendingAddLoop() {
        guard self.pendingAddTask == nil else { return }
        self.pendingAddTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.pendingAddTask = nil } }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await AccountManager.shared.reconcile()
                let snapshot = await AccountManager.shared.snapshot()
                self.snapshot = snapshot
                self.applyIcon()
                self.rebuildMenu()
                if !snapshot.isPendingAdd { return }
            }
        }
    }

    private func confirmAndRemove(accountUuid: String, email: String) async {
        let alert = NSAlert()
        alert.messageText = "Remove \(email) from ClaudeBar?"
        alert.informativeText = "ClaudeBar forgets this account's stored credentials and usage. The Anthropic account itself is not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        await AccountManager.shared.removeAccount(accountUuid: accountUuid)
        await self.refreshSnapshot()
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            self.rebuildMenu()
            Task { [weak self] in
                await AccountManager.shared.reconcile()
                await self?.refreshSnapshot()
            }
        }
    }

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Failed to update login item: \(error.localizedDescription)")
        }
        self.rebuildMenu()
    }
}
