import SwiftUI
import UIKit

/// Screen B: one deployment, read from the live snapshot so it keeps updating while open.
struct DeploymentDetailView: View {
    let deploymentID: String

    @EnvironmentObject private var feed: DeploymentFeed

    var body: some View {
        Group {
            if let deployment = feed.snapshot.deployment(id: deploymentID) {
                // In-progress rows tick every second; finished ones only need the day labels to roll over.
                TimelineView(.periodic(from: .now, by: deployment.isInProgress ? 1 : 60)) { context in
                    DeploymentDetailContent(deployment: deployment, now: context.date)
                }
            } else {
                ContentUnavailableView(
                    "Deployment Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("It is no longer in the latest deployments.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DeploymentDetailContent: View {
    let deployment: Deployment
    let now: Date

    @Environment(\.openURL) private var openURL
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                details
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlatformBadge(platform: deployment.platform, size: 52)
                .padding(.bottom, 6)
            Text(deployment.projectName)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
            Text(platformLine)
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            statePill
                .padding(.top, 2)
        }
    }

    private var platformLine: String {
        switch deployment.platform {
        case .vercel: "Vercel"
        case .cloudflarePages: "Cloudflare Pages"
        case .cloudflareWorkers: "Cloudflare Workers"
        }
    }

    private var statePill: some View {
        let style = StateStyle(deployment.state)
        return Label(stateText(style), systemImage: style.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(style.color)
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(style.color.opacity(0.12), in: Capsule())
    }

    private func stateText(_ style: StateStyle) -> String {
        guard let duration = deployment.duration(now: now) else { return style.label }
        let formatted = DeploymentFormat.duration(duration)
        switch deployment.state {
        case .ready: return "Ready in \(formatted)"
        case .error: return "Error after \(formatted)"
        case .canceled: return "Canceled after \(formatted)"
        case .building, .queued: return "\(style.label) \(formatted)"
        case .skipped, .unknown: return style.label
        }
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let branch = deployment.branch {
            rows.append(("Branch", branch))
        }
        if let environment = deployment.environmentLabel {
            rows.append(("Environment", environment))
        }
        if let commit = deployment.commitTitle {
            rows.append(("Commit", commit))
        }
        if let source = deployment.sourceLabel {
            rows.append(("Source", source))
        }
        if let traffic = deployment.trafficPercentage {
            rows.append(("Rollout", "\(traffic)%"))
        }
        rows.append(("Started", Self.dateTime(deployment.buildStartDate, now: now)))
        if let duration = deployment.duration(now: now) {
            rows.append(("Duration", DeploymentFormat.duration(duration)))
        }
        return rows
    }

    private var details: some View {
        Card {
            ForEach(Array(detailRows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    RowDivider()
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(row.0)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize()
                    Text(row.1)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                if let url = deployment.openURL {
                    openURL(url)
                }
            } label: {
                Label("Open in Browser", systemImage: "arrow.up.forward.square")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(deployment.openURL == nil)
            .opacity(deployment.openURL == nil ? 0.4 : 1)

            Button {
                guard let url = deployment.openURL else { return }
                UIPasteboard.general.url = url
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopy = false
                }
            } label: {
                Label(didCopy ? "Copied" : "Copy Deployment URL", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Palette.accent)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(deployment.openURL == nil)
            .opacity(deployment.openURL == nil ? 0.4 : 1)
            .sensoryFeedback(.success, trigger: didCopy) { _, copied in copied }
        }
    }

    /// "Today 13:54", "Yesterday 09:10" or "Oct 6, 13:54".
    private static func dateTime(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }
}
