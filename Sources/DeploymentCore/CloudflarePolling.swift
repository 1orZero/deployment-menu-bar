import Foundation

/// Cloudflare's polling state: the shown rows, the in-progress items the fast tier re-queries, and a 429 pause.
/// The status item controller performs the requests and runs the timers this state plans.
struct CloudflarePolling {
    private(set) var deployments: [Deployment] = []
    private(set) var pendingItems: [CloudflarePendingItem] = []
    private(set) var issue: PlatformIssue?
    /// Set by a 429; no Cloudflare request is sent before this date.
    private(set) var pausedUntil: Date?

    func isPaused(at now: Date) -> Bool {
        pausedUntil.map { $0 > now } ?? false
    }

    /// When the next full fetch and fast re-query may run. A pause defers the full fetch to its end and stops the fast
    /// tier; otherwise the fast tier runs only while some shown row is in progress.
    func plan(at now: Date, preferences: CloudflarePreferences) -> CloudflarePollingPlan {
        if let pausedUntil, pausedUntil > now {
            return CloudflarePollingPlan(nextFullFetch: pausedUntil, fastInterval: nil)
        }
        return CloudflarePollingPlan(
            nextFullFetch: now.addingTimeInterval(preferences.effectiveRefreshInterval),
            fastInterval: pendingItems.isEmpty ? nil : preferences.effectiveFastRefreshInterval
        )
    }

    /// What the menu shows at `now`. While paused the last rows stay, with the remaining wait as the issue.
    func status(at now: Date) -> PlatformStatus {
        guard let pausedUntil else {
            return PlatformStatus(deployments: deployments, issue: issue)
        }
        let remaining = Int(pausedUntil.timeIntervalSince(now).rounded(.up))
        let retry = remaining > 0 ? "retrying in \(Self.formatted(seconds: remaining))" : "retrying now"
        return PlatformStatus(deployments: deployments, issue: PlatformIssue(message: "Rate limited by Cloudflare — \(retry)"))
    }

    /// A successful full fetch replaces the rows and ends a pause. Only in-progress items among `rows` (the rows left
    /// after scope and filters) stay pending.
    mutating func applyFullFetch(rows: [Deployment], pendingItems: [CloudflarePendingItem], issue: PlatformIssue?) {
        deployments = rows
        let shownIDs = Set(rows.map(\.id))
        self.pendingItems = pendingItems.filter { shownIDs.contains($0.rowID) }
        self.issue = issue
        pausedUntil = nil
    }

    /// A 429 pauses polling and keeps the last rows; any other failure replaces them with the error.
    mutating func applyFailure(_ error: Error) {
        if let end = CloudflareAPIError.rateLimitEnd(of: error) {
            pausedUntil = end
            return
        }
        deployments = []
        pendingItems = []
        issue = PlatformIssue(message: error.localizedDescription)
        pausedUntil = nil
    }

    /// Patches fast-tier results into the shown rows. Returns true when an item finished, so a full fetch picks up
    /// what a single re-query does not return (e.g. the deployment a finished build produced).
    mutating func applyUpdates(_ updates: [CloudflarePendingUpdate]) -> Bool {
        var finished = false
        for update in updates {
            let rowID: String
            switch update {
            case let .pagesDeployment(row):
                rowID = row.id
            case let .workersBuild(id, _):
                rowID = id
            }
            guard let index = deployments.firstIndex(where: { $0.id == rowID }) else { continue }
            let row: Deployment
            switch update {
            case let .pagesDeployment(updated):
                row = updated
            case let .workersBuild(_, build):
                row = deployments[index].patched(with: build)
            }
            deployments[index] = row
            if !row.state.isInProgress {
                pendingItems.removeAll { $0.rowID == rowID }
                finished = true
            }
        }
        return finished
    }

    private static func formatted(seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

struct CloudflarePollingPlan: Equatable {
    let nextFullFetch: Date
    /// Seconds between fast re-queries; nil when the fast tier is stopped.
    let fastInterval: TimeInterval?
}

extension CloudflarePreferences {
    static let minimumRefreshInterval = 10
    static let minimumFastRefreshInterval = 2

    var effectiveRefreshInterval: TimeInterval {
        TimeInterval(max(refreshInterval, Self.minimumRefreshInterval))
    }

    var effectiveFastRefreshInterval: TimeInterval {
        TimeInterval(max(fastRefreshInterval, Self.minimumFastRefreshInterval))
    }
}
