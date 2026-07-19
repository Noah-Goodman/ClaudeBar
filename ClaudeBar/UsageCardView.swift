import SwiftUI

struct UsageCardView: View {
    let snapshot: AccountsSnapshot?
    let scanProgress: ScanProgress?
    let isRefreshing: Bool
    let launchAtLogin: Bool
    let onToggleLaunchAtLogin: () -> Void
    let onRefresh: () -> Void
    let onSwitch: (String) -> Void
    let onAddAccount: () -> Void
    let onCancelAddAccount: () -> Void
    let onRemove: (String, String) -> Void
    let onCheckForUpdates: (() -> Void)?
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.headerSection
            if let banner = self.snapshot?.banner {
                BannerView(banner: banner)
            }
            if let snapshot {
                if snapshot.displays.isEmpty && !snapshot.isPendingAdd {
                    self.emptySection
                } else {
                    self.accountsSection(snapshot)
                }
                if snapshot.isPendingAdd {
                    PendingAddRow(onCancel: self.onCancelAddAccount)
                }
                self.costOrScanSection(snapshot)
            } else {
                self.loadingSection
            }
            Divider().padding(.vertical, 6)
            self.footerSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 310)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Claude")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                if self.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button(action: self.onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let updatedAt = self.snapshot?.updatedAt {
                Text("Updated \(Formatting.timeAgo(from: updatedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.top, 6)
        }
    }

    private func accountsSection(_ snapshot: AccountsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(snapshot.displays) { display in
                AccountRow(
                    display: display,
                    showBadges: snapshot.displays.count > 1,
                    onSwitch: { self.onSwitch(display.id) },
                    onRemove: { self.onRemove(display.id, display.account.email) })
                if display.id != snapshot.displays.last?.id {
                    Divider()
                }
            }
        }
        .padding(.top, 6)
    }

    private var emptySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No accounts yet")
                .font(.system(size: 12, weight: .semibold))
            Text("Sign into Claude Code (run claude and /login) and ClaudeBar will pick the account up automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func costOrScanSection(_ snapshot: AccountsSnapshot) -> some View {
        if let cost = snapshot.cost, cost.todayTokens > 0 || cost.last30DaysTokens > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.vertical, 6)
                Text("Cost")
                    .font(.system(size: 13, weight: .semibold))
                Text("Today: \(Formatting.formatCost(cost.todayCostUSD)) \u{00B7} \(Formatting.formatTokens(cost.todayTokens)) tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Last 30 days: \(Formatting.formatCost(cost.last30DaysCostUSD)) \u{00B7} \(Formatting.formatTokens(cost.last30DaysTokens)) tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if let progress = self.scanProgress, !progress.isComplete {
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.vertical, 6)
                HStack(spacing: 6) {
                    Spacer()
                    Text("Scanning logs...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if progress.totalFiles > 0 {
                        Text("\(progress.scannedFiles)/\(progress.totalFiles)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                if progress.totalFiles > 0 {
                    ScanProgressBar(fraction: progress.fraction)
                }
            }
        }
    }

    private var loadingSection: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Loading...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Toggle("Launch at Login", isOn: Binding(
                    get: { self.launchAtLogin },
                    set: { _ in self.onToggleLaunchAtLogin() }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer()
                Button("Add Account") { self.onAddAccount() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(self.snapshot?.isPendingAdd == true)
                Button("Quit") { self.onQuit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
            if let onCheckForUpdates = self.onCheckForUpdates {
                HStack {
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Check for Updates") { onCheckForUpdates() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    static func barColor(for percent: Int) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return Color(nsColor: .controlAccentColor)
    }
}

struct BannerView: View {
    let banner: Banner

    private var color: Color {
        switch self.banner.kind {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        Text(self.banner.message)
            .font(.system(size: 11))
            .foregroundStyle(self.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}

struct AccountRow: View {
    let display: AccountDisplay
    let showBadges: Bool
    let onSwitch: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(self.display.account.email)
                    .font(.system(size: 12, weight: self.display.isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if self.display.isActive {
                    BadgeView(text: "Active", color: Color(nsColor: .controlAccentColor))
                } else if self.showBadges && self.display.isRecommended {
                    BadgeView(text: "Next", color: .green)
                }
                Spacer()
                if !self.display.isActive {
                    if self.isHovering {
                        Button(action: self.onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove account")
                    }
                    Button("Switch") { self.onSwitch() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 10))
                }
            }
            // Fixed-height body so a rebuild mid-open never shifts rows below.
            Group {
                if self.display.account.needsRelogin {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("Re-login required")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if let usage = self.display.usage {
                    VStack(alignment: .leading, spacing: 4) {
                        CompactMetricLine(metric: usage.session, fallbackLabel: "Session", stale: self.display.isStale)
                        CompactMetricLine(metric: usage.weekly, fallbackLabel: "Weekly", stale: self.display.isStale)
                    }
                } else {
                    Text("No usage data yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 32, alignment: .center)

            if let usage = self.display.usage, !self.display.account.needsRelogin {
                if let fable = usage.fable {
                    CompactMetricLine(metric: fable, fallbackLabel: fable.label, stale: self.display.isStale)
                }
                if let extra = usage.extraUsage {
                    CompactMetricLine(metric: extra, fallbackLabel: extra.label, stale: self.display.isStale)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { self.isHovering = $0 }
    }
}

struct BadgeView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(self.text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(self.color.opacity(0.18))
            .foregroundStyle(self.color)
            .clipShape(Capsule())
    }
}

struct CompactMetricLine: View {
    let metric: UsageMetric?
    let fallbackLabel: String
    let stale: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(self.metric?.label ?? self.fallbackLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
                .lineLimit(1)
            if let metric, metric.isUnlimited {
                Text("Unlimited")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let metric {
                UsageProgressBar(
                    percent: metric.usedPercent,
                    tintColor: UsageCardView.barColor(for: metric.usedPercent))
                    .frame(height: 5)
                    .opacity(self.stale ? 0.5 : 1)
                Text("\(metric.usedPercent)%")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
                Text(self.resetText(metric))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 74, alignment: .trailing)
                    .lineLimit(1)
            } else {
                UsageProgressBar(percent: 0, tintColor: .clear)
                    .frame(height: 5)
                Text("--")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, alignment: .trailing)
                Text("")
                    .frame(width: 74)
            }
        }
    }

    private func resetText(_ metric: UsageMetric) -> String {
        if let spent = metric.spentDescription { return spent }
        guard let resetsAt = metric.resetsAt else { return "" }
        return Formatting.resetDescription(from: resetsAt)
    }
}

struct PendingAddRow: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 4)
            HStack(alignment: .top, spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                Text("Run claude and use /login to sign into the other account. ClaudeBar will detect it automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Cancel") { self.onCancel() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct UsageProgressBar: View {
    let percent: Int
    var tintColor: Color = Color(nsColor: .controlAccentColor)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(self.tintColor)
                    .frame(width: max(0, geometry.size.width * CGFloat(min(self.percent, 100)) / 100))
            }
        }
        .frame(height: 6)
    }
}

struct ScanProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: max(0, geometry.size.width * CGFloat(min(self.fraction, 1))))
            }
        }
        .frame(height: 3)
    }
}
