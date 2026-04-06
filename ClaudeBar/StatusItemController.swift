import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var refreshTask: Task<Void, Never>?
    private var currentSnapshot: UsageSnapshot?
    private var currentError: String?
    private var isRefreshing = false

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()
        self.menu.delegate = self
        self.statusItem.menu = self.menu

        if let cached = CachedUsage.load() {
            self.currentSnapshot = cached.toSnapshot()
            self.setIcon(
                sessionUsed: cached.session.map { Double($0.usedPercent) },
                weeklyUsed: cached.weekly.map { Double($0.usedPercent) },
                stale: cached.isStale)
        } else {
            self.setIcon(sessionUsed: nil, weeklyUsed: nil, stale: true)
        }

        self.rebuildMenu()
        self.startPolling()
    }

    private func rebuildMenu() {
        self.menu.removeAllItems()

        let cardView = UsageCardView(
            snapshot: self.currentSnapshot,
            error: self.currentError,
            isRefreshing: self.isRefreshing,
            launchAtLogin: SMAppService.mainApp.status == .enabled,
            onToggleLaunchAtLogin: { [weak self] in Task { self?.toggleLaunchAtLogin() } },
            onRefresh: { [weak self] in Task { await self?.forceRefresh() } },
            onRetry: { [weak self] in Task { await self?.forceRefresh() } },
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

    private func startPolling() {
        self.refreshTask = Task { [weak self] in
            await self?.refreshIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refreshIfNeeded()
            }
        }
    }

    private func refreshIfNeeded() async {
        if let cached = CachedUsage.load(), !cached.isStale {
            return
        }
        await self.fetchAndUpdate()
    }

    private func forceRefresh() async {
        await self.fetchAndUpdate()
    }

    private func fetchAndUpdate() async {
        self.isRefreshing = true
        self.rebuildMenu()
        defer {
            self.isRefreshing = false
            self.rebuildMenu()
        }
        do {
            let rawOutput = try await CLISession.shared.fetchUsage()
            let parsed = try UsageParser.parse(rawOutput)

            let session = parsed.sessionPercentUsed.map {
                UsageMetric(label: "Session", usedPercent: $0, resetDescription: parsed.sessionReset, spentDescription: nil, isUnlimited: false)
            }
            let weekly = parsed.weeklyPercentUsed.map {
                UsageMetric(label: "Weekly", usedPercent: $0, resetDescription: parsed.weeklyReset, spentDescription: nil, isUnlimited: false)
            }
            let sonnet = parsed.sonnetPercentUsed.map {
                UsageMetric(label: "Sonnet", usedPercent: $0, resetDescription: parsed.sonnetReset, spentDescription: nil, isUnlimited: false)
            }
            let extraUsage: UsageMetric?
            if let percent = parsed.extraUsagePercentUsed {
                extraUsage = UsageMetric(label: "Extra Usage", usedPercent: percent, resetDescription: parsed.extraUsageReset, spentDescription: parsed.extraUsageSpent, isUnlimited: false)
            } else if parsed.extraUsageUnlimited {
                extraUsage = UsageMetric(label: "Extra Usage", usedPercent: 0, resetDescription: nil, spentDescription: "Unlimited", isUnlimited: true)
            } else {
                extraUsage = nil
            }

            let cached = CachedUsage(
                session: session, weekly: weekly, sonnet: sonnet, extraUsage: extraUsage,
                cost: nil, fetchedAt: Date())
            cached.save()

            self.currentSnapshot = cached.toSnapshot(
                scanProgress: ScanProgress(scannedFiles: 0, totalFiles: 0, isComplete: false))
            self.currentError = nil

            self.setIcon(
                sessionUsed: session.map { Double($0.usedPercent) },
                weeklyUsed: weekly.map { Double($0.usedPercent) },
                stale: false)
            self.rebuildMenu()

            let progressTask = Task { [weak self] in
                for await progress in CostScanner.shared.progressStream {
                    await MainActor.run {
                        self?.updateScanProgress(session: session, weekly: weekly, sonnet: sonnet, extraUsage: extraUsage, progress: progress)
                    }
                }
            }

            let cost = await Task.detached { CostScanner.shared.scan() }.value
            progressTask.cancel()

            let cachedWithCost = CachedUsage(
                session: session, weekly: weekly, sonnet: sonnet, extraUsage: extraUsage,
                cost: cost, fetchedAt: Date())
            cachedWithCost.save()

            self.currentSnapshot = cachedWithCost.toSnapshot()
            self.rebuildMenu()
        } catch let error as FetchError {
            switch error {
            case .claudeNotInstalled:
                self.currentError = "Claude CLI not found. Install it first."
            case .timedOut:
                self.currentError = "Claude CLI timed out."
            case .parseFailed(let message):
                self.currentError = message
            }
            self.setIcon(sessionUsed: nil, weeklyUsed: nil, stale: true)
            self.rebuildMenu()
        } catch {
            self.currentError = error.localizedDescription
            self.setIcon(sessionUsed: nil, weeklyUsed: nil, stale: true)
            self.rebuildMenu()
        }
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            self.rebuildMenu()
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
            self.currentError = "Failed to update login item: \(error.localizedDescription)"
        }
        self.rebuildMenu()
    }

    private func updateScanProgress(
        session: UsageMetric?,
        weekly: UsageMetric?,
        sonnet: UsageMetric?,
        extraUsage: UsageMetric?,
        progress: ScanProgress)
    {
        guard !progress.isComplete else { return }
        self.currentSnapshot = UsageSnapshot(
            session: session, weekly: weekly, sonnet: sonnet, extraUsage: extraUsage,
            cost: nil, scanProgress: progress, updatedAt: self.currentSnapshot?.updatedAt ?? Date())
        self.rebuildMenu()
    }
}
