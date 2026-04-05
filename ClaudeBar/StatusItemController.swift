import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var refreshTask: Task<Void, Never>?
    private var currentSnapshot: UsageSnapshot?
    private var currentError: String?

    init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
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
        do {
            let rawOutput = try await CLISession.shared.fetchUsage()
            let parsed = try UsageParser.parse(rawOutput)

            let session = parsed.sessionPercentUsed.map {
                UsageMetric(label: "Session", usedPercent: $0, resetDescription: parsed.sessionReset)
            }
            let weekly = parsed.weeklyPercentUsed.map {
                UsageMetric(label: "Weekly", usedPercent: $0, resetDescription: parsed.weeklyReset)
            }
            let sonnet = parsed.sonnetPercentUsed.map {
                UsageMetric(label: "Sonnet", usedPercent: $0, resetDescription: parsed.sonnetReset)
            }

            let cached = CachedUsage(
                session: session, weekly: weekly, sonnet: sonnet,
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
                        self?.updateScanProgress(session: session, weekly: weekly, sonnet: sonnet, progress: progress)
                    }
                }
            }

            let cost = await Task.detached { CostScanner.shared.scan() }.value
            progressTask.cancel()

            let cachedWithCost = CachedUsage(
                session: session, weekly: weekly, sonnet: sonnet,
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

    private func updateScanProgress(
        session: UsageMetric?,
        weekly: UsageMetric?,
        sonnet: UsageMetric?,
        progress: ScanProgress)
    {
        guard !progress.isComplete else { return }
        self.currentSnapshot = UsageSnapshot(
            session: session, weekly: weekly, sonnet: sonnet,
            cost: nil, scanProgress: progress, updatedAt: self.currentSnapshot?.updatedAt ?? Date())
        self.rebuildMenu()
    }
}
