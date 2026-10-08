import Foundation

/// One fetch of both platforms with the saved scope and filters, for the widget, which cannot keep polling. Failures
/// become platform issues, the same way the app shows them.
enum DeploymentLoader {
    static func load(
        previous: DeploymentSnapshot?,
        store: PreferencesStore = .shared,
        now: Date = Date()
    ) async -> DeploymentSnapshot {
        async let vercel = loadVercel(store: store)
        async let cloudflare = loadCloudflare(previous: previous, store: store, now: now)
        let (vercelStatus, cloudflareResult) = await (vercel, cloudflare)

        let fetched = vercelStatus.fetched || cloudflareResult.fetched
        return DeploymentSnapshot(
            vercel: vercelStatus.status,
            cloudflare: cloudflareResult.status,
            fetchedAt: fetched ? now : previous?.fetchedAt,
            cloudflarePausedUntil: cloudflareResult.pausedUntil,
            cloudflareAccountIDs: cloudflareResult.accountIDs ?? previous?.cloudflareAccountIDs ?? []
        )
    }

    private static func loadVercel(store: PreferencesStore) async -> (status: PlatformStatus, fetched: Bool) {
        guard let token = store.token(for: .vercel) else {
            return (PlatformStatus(isEnabled: false), false)
        }
        let preferences = store.current
        do {
            let deployments = try await DeploymentService().fetchAllDeployments(preferences: preferences, token: token)
            return (PlatformStatus(deployments: preferences.filter(deployments)), true)
        } catch {
            return (PlatformStatus(issue: PlatformIssue(message: error.localizedDescription)), false)
        }
    }

    private static func loadCloudflare(
        previous: DeploymentSnapshot?,
        store: PreferencesStore,
        now: Date
    ) async -> (status: PlatformStatus, fetched: Bool, pausedUntil: Date?, accountIDs: [String]?) {
        guard let token = store.token(for: .cloudflare) else {
            return (PlatformStatus(isEnabled: false), false, nil, [])
        }
        let previousRows = previous?.cloudflare.deployments ?? []

        // Inside a 429 pause nothing is sent; the last rows stay with the pause as the issue.
        if let pausedUntil = previous?.cloudflarePausedUntil, pausedUntil > now {
            var polling = CloudflarePolling()
            polling.applyFailure(CloudflareAPIError.rateLimited(until: pausedUntil))
            let issue = polling.status(at: now).issue
            return (PlatformStatus(deployments: previousRows, issue: issue), false, pausedUntil, nil)
        }

        let preferences = store.current.cloudflare
        do {
            let snapshot = try await CloudflareService().fetchDeployments(token: token, preferences: preferences)
            let status = PlatformStatus(deployments: preferences.filter(snapshot.deployments), issue: snapshot.issue)
            return (status, true, nil, snapshot.accountIDs)
        } catch {
            var polling = CloudflarePolling()
            polling.applyFailure(error)
            let issue = polling.status(at: now).issue
            // A 429 keeps the last rows like the app does; any other failure shows only the error.
            let rows = polling.pausedUntil == nil ? [] : previousRows
            return (PlatformStatus(deployments: rows, issue: issue), false, polling.pausedUntil, nil)
        }
    }
}
