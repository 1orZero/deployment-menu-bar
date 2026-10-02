import Foundation

/// Why a platform is not fully healthy. It marks the status button with ⚠ and gets a banner in the menu.
struct PlatformIssue: Equatable {
    var message: String
}

/// One platform's latest fetch. A platform without a token is disabled rather than failed.
struct PlatformStatus {
    var isEnabled = true
    var deployments: [Deployment] = []
    var issue: PlatformIssue?
}

/// What the menu bar status button shows.
enum StatusButtonState: Equatable {
    case noToken
    case error
    case empty(warning: Bool)
    case deployment(Deployment, warning: Bool)

    init(platforms: [PlatformStatus]) {
        let enabled = platforms.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            self = .noToken
            return
        }

        let warning = enabled.contains { $0.issue != nil }
        // A platform with an issue may still have rows (e.g. degraded access), so "Error" is reserved
        // for when every enabled platform has an issue and nothing is left to show.
        let newest = Deployment.mergedNewestFirst(enabled.flatMap(\.deployments)).first
        if let newest {
            self = .deployment(newest, warning: warning)
        } else if enabled.allSatisfy({ $0.issue != nil }) {
            self = .error
        } else {
            self = .empty(warning: warning)
        }
    }
}
