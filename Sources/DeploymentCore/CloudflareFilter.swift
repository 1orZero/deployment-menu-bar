import Foundation

extension CloudflarePreferences {
    /// The Cloudflare rows to show, newest first: rows that `matches`, then the count or hours limit.
    func filter(_ deployments: [Deployment], now: Date = Date()) -> [Deployment] {
        let branches = branchList
        var filtered = deployments
            .filter { matches($0, branches: branches) }
            .sorted { $0.createdAt > $1.createdAt }

        if limitByCount > 0 {
            filtered = Array(filtered.prefix(limitByCount))
        } else if let cutoff = hoursCutoff(now: now) {
            filtered = filtered.filter { $0.createdAt >= cutoff }
        }
        return filtered
    }

    /// The branch, environment and state filters, without the count or hours limit. With a branch filter set, rows
    /// without a branch (wrangler, rollback, promotion, dashboard deployments) are hidden.
    func matches(_ deployment: Deployment) -> Bool {
        matches(deployment, branches: branchList)
    }

    /// The oldest creation date the hours limit keeps; nil when a count limit applies or no hours limit is set.
    func hoursCutoff(now: Date) -> Date? {
        guard limitByCount <= 0, let hours = limitByHours, hours > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(-hours * 3600))
    }

    private func matches(_ deployment: Deployment, branches: [String]) -> Bool {
        guard shows(deployment.state) else { return false }

        switch deployment.environment {
        case .production:
            guard showProduction else { return false }
        case .preview:
            guard showPreview else { return false }
        case .custom, nil:
            break
        }

        if !branches.isEmpty {
            guard let branch = deployment.branch?.lowercased(), branches.contains(branch) else { return false }
        }
        return true
    }

    private func shows(_ state: Deployment.State) -> Bool {
        switch state {
        case .ready: showReady
        case .building: showBuilding
        case .error: showError
        case .queued: showQueued
        case .canceled: showCanceled
        case .skipped: showSkipped
        case .unknown: true
        }
    }
}
