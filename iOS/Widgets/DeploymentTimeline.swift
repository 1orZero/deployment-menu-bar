import AppIntents
import SwiftUI
import WidgetKit

struct DeploymentEntry: TimelineEntry {
    let date: Date
    let snapshot: DeploymentSnapshot
}

/// Shared by every widget kind: reads the app's cached snapshot and fetches only when it is stale.
struct DeploymentProvider: TimelineProvider {
    private static let staleAfter: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> DeploymentEntry {
        DeploymentEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (DeploymentEntry) -> Void) {
        let snapshot = SnapshotStore.load() ?? (context.isPreview ? .placeholder : .empty)
        completion(DeploymentEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DeploymentEntry>) -> Void) {
        Task {
            let now = Date()
            let cached = SnapshotStore.load()
            var snapshot = cached ?? .empty
            if let fetchedAt = cached?.fetchedAt, now.timeIntervalSince(fetchedAt) < Self.staleAfter {
                // Fresh enough; the app or the last widget refresh already fetched.
            } else {
                snapshot = await DeploymentLoader.load(previous: cached, now: now)
                SnapshotStore.save(snapshot)
            }
            let inProgress = snapshot.deployments.contains { $0.isInProgress }
            let next = now.addingTimeInterval(inProgress ? 5 * 60 : 30 * 60)
            completion(Timeline(entries: [DeploymentEntry(date: now, snapshot: snapshot)], policy: .after(next)))
        }
    }
}

struct RefreshDeploymentsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Deployments"

    func perform() async throws -> some IntentResult {
        let snapshot = await DeploymentLoader.load(previous: SnapshotStore.load())
        SnapshotStore.save(snapshot)
        return .result()
    }
}

extension DeploymentSnapshot {
    /// Redaction-friendly stand-in for the widget gallery and placeholders; never saved.
    static var placeholder: DeploymentSnapshot {
        let now = Date()
        func row(_ id: String, _ platform: Deployment.Platform, _ name: String, _ state: Deployment.State, _ ago: TimeInterval, _ took: TimeInterval?) -> Deployment {
            let created = now.addingTimeInterval(-ago)
            return Deployment(
                id: id, platform: platform, projectName: name, state: state, createdAt: created,
                buildStartedAt: created, finishedAt: took.map { created.addingTimeInterval($0) },
                branch: "main", environment: .production, commitMessage: nil, openURL: nil,
                sourceLabel: nil, trafficPercentage: nil
            )
        }
        return DeploymentSnapshot(
            vercel: PlatformStatus(deployments: [
                row("v1", .vercel, "marketing-site", .ready, 120, 55),
                row("v2", .vercel, "dashboard", .building, 600, nil),
                row("v3", .vercel, "docs", .error, 3600, 54),
            ]),
            cloudflare: PlatformStatus(deployments: [
                row("c1", .cloudflarePages, "landing", .ready, 1800, 40),
                row("c2", .cloudflareWorkers, "api-worker", .ready, 7200, 12),
            ]),
            fetchedAt: now
        )
    }
}
