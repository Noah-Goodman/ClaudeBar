import SwiftUI

struct UsageCardView: View {
    let snapshot: UsageSnapshot?
    let error: String?
    let onRetry: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.headerSection
            if let snapshot {
                self.metricsSection(snapshot)
                self.costOrScanSection(snapshot)
            } else if let error {
                self.errorSection(error)
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
            Text("Claude")
                .font(.system(size: 14, weight: .bold))
            if let snapshot {
                Text("Updated \(Formatting.timeAgo(from: snapshot.updatedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.top, 6)
        }
    }

    @ViewBuilder
    private func metricsSection(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = snapshot.session {
                MetricRow(metric: session)
            }
            if let weekly = snapshot.weekly {
                MetricRow(metric: weekly)
            }
            if let sonnet = snapshot.sonnet {
                MetricRow(metric: sonnet)
            }
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private func costOrScanSection(_ snapshot: UsageSnapshot) -> some View {
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
        } else if let progress = snapshot.scanProgress, !progress.isComplete {
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

    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Button("Retry") { self.onRetry() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
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
        HStack {
            Spacer()
            Button("Quit") { self.onQuit() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    static func barColor(for percent: Int) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return Color(nsColor: .controlAccentColor)
    }
}

struct MetricRow: View {
    let metric: UsageMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.metric.label)
                .font(.system(size: 13, weight: .semibold))
            UsageProgressBar(
                percent: self.metric.usedPercent,
                tintColor: UsageCardView.barColor(for: self.metric.usedPercent))
            HStack {
                Text("\(self.metric.usedPercent)% used")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset = self.metric.resetDescription {
                    Text(reset)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
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
