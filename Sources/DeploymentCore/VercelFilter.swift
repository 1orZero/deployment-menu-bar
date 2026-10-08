import Foundation

extension Preferences {
    /// The Vercel rows to show, newest first: project, state, environment and branch filters, then the count or
    /// hours limit (count wins when both are set).
    func filter(_ deployments: [Deployment], now: Date = Date()) -> [Deployment] {
        let normalizedProjectNames = normalizedProjectNameSet
        let branches = branchList

        var filtered = deployments.filter { deployment in
            if !normalizedProjectNames.isEmpty {
                guard normalizedProjectNames.contains(deployment.projectName.lowercased()) else { return false }
            }

            switch deployment.state {
            case .ready:
                guard showReady else { return false }
            case .building:
                guard showBuilding else { return false }
            case .error:
                guard showError else { return false }
            case .queued:
                guard showQueued else { return false }
            case .canceled:
                guard showCanceled else { return false }
            case .skipped, .unknown:
                break
            }

            switch deployment.environment {
            case .production:
                guard showProduction else { return false }
            case .preview:
                guard showPreview else { return false }
            case .custom, nil:
                break
            }

            if !branches.isEmpty {
                let branch = (deployment.branch ?? "").lowercased()
                if branch.isEmpty || !branches.contains(branch) {
                    return false
                }
            }

            return true
        }

        if let limit = limitByCount, limit > 0 {
            filtered = Array(filtered.prefix(limit))
        } else if let hours = limitByHours, hours > 0 {
            let cutoff = now.addingTimeInterval(TimeInterval(-hours * 3600))
            filtered = filtered.filter { $0.createdAt >= cutoff }
        }

        return filtered.sorted { $0.createdAt > $1.createdAt }
    }
}
