import AppIntents
import SwiftUI
import WidgetKit

@main
struct OpenDeploymentWidgets: WidgetBundle {
    var body: some Widget {
        LatestWidget()
        CountsWidget()
        DeploymentsWidget()
        PlatformsWidget()
    }
}

// MARK: - Widgets

struct LatestWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Latest", provider: DeploymentProvider()) { entry in
            LatestView(entry: entry)
        }
        .configurationDisplayName("Latest Deployment")
        .description("The newest deployment across your platforms.")
        .supportedFamilies([.systemSmall, .accessoryInline, .accessoryRectangular, .accessoryCircular])
    }
}

struct CountsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Counts", provider: DeploymentProvider()) { entry in
            CountsView(entry: entry)
        }
        .configurationDisplayName("Today's Status")
        .description("Building, ready and failed deployments today.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct DeploymentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Deployments", provider: DeploymentProvider()) { entry in
            DeploymentsView(entry: entry)
        }
        .configurationDisplayName("Recent Deployments")
        .description("Your most recent deployments.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct PlatformsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Platforms", provider: DeploymentProvider()) { entry in
            PlatformsView(entry: entry)
        }
        .configurationDisplayName("Platform Split")
        .description("Vercel and Cloudflare side by side.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Shared pieces

private func updatedText(_ snapshot: DeploymentSnapshot) -> String? {
    snapshot.fetchedAt.map { "Updated " + $0.formatted(date: .omitted, time: .shortened) }
}

/// "Vercel issue" from "Vercel: message".
private func issueTitle(_ snapshot: DeploymentSnapshot) -> String? {
    guard let first = snapshot.issues.first else { return nil }
    let platform = first.split(separator: ":").first.map(String.init) ?? first
    return "\(platform) issue"
}

/// Shown instead of content when there is no token or no rows; nil when content can be drawn.
private struct EmptyStateText: View {
    let snapshot: DeploymentSnapshot

    static func message(_ snapshot: DeploymentSnapshot) -> String? {
        if !snapshot.hasToken { return "Add a token in the app" }
        if snapshot.deployments.isEmpty { return "No deployments found" }
        return nil
    }

    var body: some View {
        Text(Self.message(snapshot) ?? "")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Elapsed-time detail for a row: live for in-progress rows, the build duration for finished ones.
private struct DurationDetail: View {
    let deployment: Deployment

    var body: some View {
        switch deployment.state {
        case .building:
            Text(deployment.buildStartDate, style: .timer) + Text(" so far")
        case .queued:
            Text(deployment.createdAt, style: .timer) + Text(" so far")
        case .error:
            Text(deployment.duration().map { "after " + DeploymentFormat.duration($0) } ?? "")
        default:
            Text(deployment.duration().map { "in " + DeploymentFormat.duration($0) } ?? "")
        }
    }
}

private struct RefreshButton: View {
    var size: CGFloat = 26

    var body: some View {
        Button(intent: RefreshDeploymentsIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: size, height: size)
                .background(Palette.chip, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }
}

// MARK: - Latest (W1, W6)

struct LatestView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DeploymentEntry

    var body: some View {
        content
            .widgetURL(entry.snapshot.latest.map { DeepLink.deployment(id: $0.id).url })
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        default: small.containerBackground(Palette.surface, for: .widget)
        }
    }

    @ViewBuilder private var small: some View {
        if let latest = entry.snapshot.latest {
            let style = StateStyle(latest.state)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    PlatformBadge(platform: latest.platform, size: 26)
                    Spacer()
                    Text(DeploymentFormat.time(latest.createdAt, now: entry.date))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: 2)
                Text(latest.projectName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Text(latest.metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: style.symbol)
                    Text(style.label)
                }
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(style.color)
                DurationDetail(deployment: latest)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            EmptyStateText(snapshot: entry.snapshot)
        }
    }

    @ViewBuilder private var inline: some View {
        if let latest = entry.snapshot.latest {
            Label("\(latest.projectName) \(StateStyle(latest.state).label)", systemImage: latest.platform.symbol)
        } else {
            Text(EmptyStateText.message(entry.snapshot) ?? "")
        }
    }

    @ViewBuilder private var rectangular: some View {
        if let latest = entry.snapshot.latest {
            let style = StateStyle(latest.state)
            let counts = entry.snapshot.todayCounts(now: entry.date)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: latest.platform.symbol)
                    Text(latest.projectName).fontWeight(.bold).lineLimit(1)
                }
                .widgetAccentable()
                HStack(spacing: 4) {
                    Image(systemName: style.symbol)
                    Text(style.label)
                    if latest.isInProgress {
                        Text("·")
                        Text(latest.state == .queued ? latest.createdAt : latest.buildStartDate, style: .timer)
                    }
                }
                .lineLimit(1)
                Text(counts.failed > 0 ? "\(counts.failed) failed today" : "\(counts.ready) ready today")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(EmptyStateText.message(entry.snapshot) ?? "")
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var circular: some View {
        let counts = entry.snapshot.todayCounts(now: entry.date)
        return Gauge(value: Double(counts.ready), in: 0...Double(max(counts.total, 1))) {
            Text("READY")
        } currentValueLabel: {
            Text("\(counts.ready)/\(counts.total)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }
}

// MARK: - Counts (W2)

struct CountsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DeploymentEntry

    var body: some View {
        if family == .accessoryCircular {
            circular
        } else {
            small.containerBackground(Palette.surface, for: .widget)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "xmark.circle").font(.system(size: 12, weight: .semibold))
                Text("\(entry.snapshot.todayCounts(now: entry.date).failed)")
                    .font(.system(size: 20, weight: .bold))
                Text("FAILED").font(.system(size: 8, weight: .semibold))
            }
            .widgetAccentable()
        }
    }

    @ViewBuilder private var small: some View {
        let snapshot = entry.snapshot
        if !snapshot.hasToken {
            EmptyStateText(snapshot: snapshot)
        } else {
            let counts = snapshot.todayCounts(now: entry.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Today")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    if snapshot.vercel.isEnabled { PlatformBadge(platform: .vercel, size: 16) }
                    if snapshot.cloudflare.isEnabled { PlatformBadge(platform: .cloudflarePages, size: 16) }
                }
                Spacer(minLength: 0)
                countRow("Building", counts.building, Palette.building)
                countRow("Ready", counts.ready, Palette.ready)
                countRow("Failed", counts.failed, Palette.error)
                Spacer(minLength: 0)
                if let issue = issueTitle(snapshot) {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.warningText)
                        .lineLimit(1)
                } else if let updated = updatedText(snapshot) {
                    Text(updated)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private func countRow(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Text("\(value)")
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? Palette.textTertiary : color)
        }
    }
}

// MARK: - Deployments (W3, W5)

struct DeploymentsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DeploymentEntry

    private var isLarge: Bool { family == .systemLarge }

    var body: some View {
        content.containerBackground(Palette.surface, for: .widget)
    }

    @ViewBuilder private var content: some View {
        let snapshot = entry.snapshot
        VStack(alignment: .leading, spacing: isLarge ? 10 : 6) {
            header
            if EmptyStateText.message(snapshot) != nil {
                EmptyStateText(snapshot: snapshot)
            } else {
                if isLarge {
                    tiles
                    if let issue = snapshot.issues.first {
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.warningText)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.warningBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                let rows = Array(snapshot.deployments.prefix(isLarge ? 5 : 3))
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, deployment in
                        if index > 0 { Divider().overlay(Palette.separator) }
                        Link(destination: DeepLink.deployment(id: deployment.id).url) {
                            row(deployment)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Deployments")
                .font(.system(size: isLarge ? 16 : 14, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            if let fetchedAt = entry.snapshot.fetchedAt {
                Text(isLarge ? updatedText(entry.snapshot) ?? "" : fetchedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            RefreshButton(size: isLarge ? 28 : 24)
        }
    }

    private var tiles: some View {
        let counts = entry.snapshot.todayCounts(now: entry.date)
        return HStack(spacing: 8) {
            tile("Building", counts.building, Palette.building)
            tile("Ready", counts.ready, Palette.ready)
            tile("Failed", counts.failed, Palette.error)
        }
    }

    private func tile(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? Palette.textTertiary : color)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ deployment: Deployment) -> some View {
        let style = StateStyle(deployment.state)
        return HStack(spacing: 8) {
            PlatformBadge(platform: deployment.platform, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(deployment.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(deployment.metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: style.symbol)
                    if !isLarge { Text(style.label) }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.color)
                Text(DeploymentFormat.time(deployment.createdAt, now: entry.date))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.vertical, isLarge ? 5 : 3)
    }
}

// MARK: - Platforms (W4)

struct PlatformsView: View {
    let entry: DeploymentEntry

    var body: some View {
        Group {
            if entry.snapshot.hasToken {
                HStack(spacing: 12) {
                    column(.vercel, entry.snapshot.vercel)
                    Rectangle().fill(Palette.separator).frame(width: 1)
                    column(.cloudflarePages, entry.snapshot.cloudflare)
                }
            } else {
                EmptyStateText(snapshot: entry.snapshot)
            }
        }
        .containerBackground(Palette.surface, for: .widget)
    }

    @ViewBuilder private func column(_ platform: Deployment.Platform, _ status: PlatformStatus) -> some View {
        let latest = status.deployments.max { $0.createdAt < $1.createdAt }
        let column = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PlatformBadge(platform: platform, size: 20)
                Text(platform.menuPlatform.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
            }
            Spacer(minLength: 2)
            if !status.isEnabled {
                Text("No token")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textTertiary)
            } else if let latest {
                let style = StateStyle(latest.state)
                Text(latest.projectName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: style.symbol)
                    Text("\(style.label) · \(DeploymentFormat.time(latest.createdAt, now: entry.date))")
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.color)
            } else {
                Text("No deployments found")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 2)
            if status.isEnabled {
                if let issue = status.issue {
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.warningText)
                        .lineLimit(1)
                } else {
                    let counts = StateCounts(status.deployments.filter {
                        Calendar.current.isDate($0.createdAt, inSameDayAs: entry.date)
                    })
                    Text("\(counts.ready) ready · \(counts.failed) failed")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        if let latest {
            Link(destination: DeepLink.deployment(id: latest.id).url) { column }
        } else {
            column
        }
    }
}

// MARK: - Previews

private let previewEntry = DeploymentEntry(date: Date(), snapshot: .placeholder)
private let emptyEntry = DeploymentEntry(date: Date(), snapshot: .empty)

#Preview("Latest", as: .systemSmall) { LatestWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Latest inline", as: .accessoryInline) { LatestWidget() } timeline: { previewEntry }
#Preview("Latest rectangular", as: .accessoryRectangular) { LatestWidget() } timeline: { previewEntry }
#Preview("Latest circular", as: .accessoryCircular) { LatestWidget() } timeline: { previewEntry }
#Preview("Counts", as: .systemSmall) { CountsWidget() } timeline: { previewEntry }
#Preview("Counts circular", as: .accessoryCircular) { CountsWidget() } timeline: { previewEntry }
#Preview("Deployments", as: .systemMedium) { DeploymentsWidget() } timeline: { previewEntry }
#Preview("Dashboard", as: .systemLarge) { DeploymentsWidget() } timeline: { previewEntry }
#Preview("Platforms", as: .systemMedium) { PlatformsWidget() } timeline: { previewEntry }
