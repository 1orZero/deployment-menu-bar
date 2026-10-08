import Foundation

/// Fetches Vercel and Cloudflare deployments on their own schedules and keeps each platform's latest result.
/// Vercel polls on the idle or building interval. Cloudflare runs a full fetch on its interval plus a fast tier that
/// re-queries only in-progress rows, and pauses every request after a 429. `onUpdate` runs on the main thread after
/// every change; the Mac menu bar and the iOS app render from it.
final class DeploymentPoller: NSObject {
    var onUpdate: (() -> Void)?

    private(set) var vercel = PlatformStatus()
    private(set) var cloudflareAccountIDs: [String] = []
    private(set) var lastFetchDate: Date?
    /// False until the platform's first fetch or token check finishes, so a caller can keep showing cached rows.
    private(set) var hasVercelResult = false
    private(set) var hasCloudflareResult = false

    private let store: PreferencesStore
    private let deploymentService = DeploymentService()
    private let cloudflareService = CloudflareService()

    private var refreshTimer: Timer?
    private var cloudflareRefreshTimer: Timer?
    private var cloudflareFastTimer: Timer?
    private var cloudflareEnabled = true
    private var cloudflarePolling = CloudflarePolling()
    private var cloudflareFastFetchInFlight = false

    init(store: PreferencesStore = .shared) {
        self.store = store
    }

    var cloudflare: PlatformStatus {
        cloudflareEnabled ? cloudflarePolling.status(at: Date()) : PlatformStatus(isEnabled: false)
    }

    /// Set while a Cloudflare 429 pause lasts; its banner counts down, so callers re-render every second.
    var cloudflarePausedUntil: Date? {
        cloudflareEnabled ? cloudflarePolling.pausedUntil : nil
    }

    func refresh() {
        refreshVercel()
        refreshCloudflare()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cloudflareRefreshTimer?.invalidate()
        cloudflareRefreshTimer = nil
        cloudflareFastTimer?.invalidate()
        cloudflareFastTimer = nil
    }

    private func notify() {
        onUpdate?()
    }

    private func scheduleRefreshTimer(hasBuilding: Bool) {
        refreshTimer?.invalidate()
        let preferences = store.current
        let idleInterval = TimeInterval(preferences.refreshIntervalIdle ?? 15)
        let buildingInterval = TimeInterval(preferences.refreshIntervalBuilding ?? 2)
        let interval: TimeInterval = hasBuilding ? buildingInterval : idleInterval
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(triggerRefreshTimer),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Applies the Cloudflare polling plan. The full-fetch timer restarts only when `restartingFullFetch` is set, so
    /// fast re-queries do not keep postponing it; the fast timer runs only while the plan has a fast interval.
    private func scheduleCloudflareTimers(restartingFullFetch: Bool) {
        let preferences = store.current.cloudflare
        let plan = cloudflarePolling.plan(at: Date(), preferences: preferences)

        if restartingFullFetch {
            cloudflareRefreshTimer?.invalidate()
            let timer = Timer(
                fireAt: plan.nextFullFetch,
                interval: preferences.effectiveRefreshInterval,
                target: self,
                selector: #selector(triggerCloudflareRefreshTimer),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            cloudflareRefreshTimer = timer
        }

        guard let fastInterval = plan.fastInterval else {
            cloudflareFastTimer?.invalidate()
            cloudflareFastTimer = nil
            return
        }
        if let cloudflareFastTimer, cloudflareFastTimer.isValid, cloudflareFastTimer.timeInterval == fastInterval {
            return
        }
        cloudflareFastTimer?.invalidate()
        let timer = Timer(
            timeInterval: fastInterval,
            target: self,
            selector: #selector(triggerCloudflareFastTimer),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        cloudflareFastTimer = timer
    }

    @objc private func triggerRefreshTimer() {
        refreshVercel()
    }

    @objc private func triggerCloudflareRefreshTimer() {
        refreshCloudflare()
    }

    @objc private func triggerCloudflareFastTimer() {
        refreshCloudflareInProgress()
    }

    private func refreshVercel() {
        guard let token = store.token(for: .vercel) else {
            // Keep checking on the idle interval: a token can arrive from another device through iCloud Keychain.
            scheduleRefreshTimer(hasBuilding: false)
            vercel = PlatformStatus(isEnabled: false)
            hasVercelResult = true
            notify()
            return
        }
        let preferences = store.current
        Task {
            do {
                let deployments = try await deploymentService.fetchAllDeployments(preferences: preferences, token: token)
                let filtered = preferences.filter(deployments)

                await MainActor.run {
                    // The token may have been removed or replaced while the request was in flight.
                    guard self.store.token(for: .vercel) == token else { return }
                    self.vercel = PlatformStatus(deployments: filtered)
                    self.hasVercelResult = true
                    self.lastFetchDate = Date()
                    let hasBuilding = filtered.contains { $0.state == .building || $0.state == .queued }
                    self.scheduleRefreshTimer(hasBuilding: hasBuilding)
                    self.notify()
                }
            } catch {
                await MainActor.run {
                    guard self.store.token(for: .vercel) == token else { return }
                    self.vercel = PlatformStatus(issue: PlatformIssue(message: error.localizedDescription))
                    self.hasVercelResult = true
                    // Keep polling on the idle interval so a recovered platform clears its ⚠ on its own.
                    self.scheduleRefreshTimer(hasBuilding: false)
                    self.notify()
                }
            }
        }
    }

    /// Full fetch on its own interval, independent of Vercel's polling. During a 429 pause nothing is sent; the
    /// full-fetch timer fires again when the pause ends.
    private func refreshCloudflare() {
        guard let token = store.token(for: .cloudflare) else {
            cloudflareEnabled = false
            hasCloudflareResult = true
            cloudflarePolling = CloudflarePolling()
            cloudflareAccountIDs = []
            // Keep checking on the full interval: a token can arrive from another device through iCloud Keychain.
            scheduleCloudflareTimers(restartingFullFetch: true)
            notify()
            return
        }
        cloudflareEnabled = true
        scheduleCloudflareTimers(restartingFullFetch: true)
        guard !cloudflarePolling.isPaused(at: Date()) else {
            notify()
            return
        }
        let preferences = store.current.cloudflare
        Task {
            do {
                let snapshot = try await cloudflareService.fetchDeployments(token: token, preferences: preferences)
                let filtered = preferences.filter(snapshot.deployments)

                await MainActor.run {
                    guard self.store.token(for: .cloudflare) == token else { return }
                    self.hasCloudflareResult = true
                    self.cloudflarePolling.applyFullFetch(
                        rows: filtered,
                        pendingItems: snapshot.pendingItems,
                        issue: snapshot.issue
                    )
                    self.cloudflareAccountIDs = snapshot.accountIDs
                    self.lastFetchDate = Date()
                    self.scheduleCloudflareTimers(restartingFullFetch: false)
                    self.notify()
                }
            } catch {
                await MainActor.run {
                    guard self.store.token(for: .cloudflare) == token else { return }
                    self.applyCloudflareFailure(error)
                }
            }
        }
    }

    /// Fast tier: re-queries only the in-progress rows of the last full fetch, one request each. When one finishes,
    /// a full fetch picks up the rows it joins with.
    private func refreshCloudflareInProgress() {
        let items = cloudflarePolling.pendingItems
        guard
            !cloudflareFastFetchInFlight,
            !items.isEmpty,
            !cloudflarePolling.isPaused(at: Date()),
            let token = store.token(for: .cloudflare)
        else { return }
        cloudflareFastFetchInFlight = true
        Task {
            let result: Result<[CloudflarePendingUpdate], Error>
            do {
                result = .success(try await cloudflareService.fetchPendingUpdates(token: token, items: items))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.cloudflareFastFetchInFlight = false
                guard self.store.token(for: .cloudflare) == token else { return }
                switch result {
                case let .success(updates):
                    let finished = self.cloudflarePolling.applyUpdates(updates)
                    self.notify()
                    if finished {
                        self.refreshCloudflare()
                    } else {
                        self.scheduleCloudflareTimers(restartingFullFetch: false)
                    }
                case let .failure(error):
                    // Other failures are left to the next full fetch, which reports them.
                    guard CloudflareAPIError.rateLimitEnd(of: error) != nil else { return }
                    self.applyCloudflareFailure(error)
                }
            }
        }
    }

    private func applyCloudflareFailure(_ error: Error) {
        cloudflarePolling.applyFailure(error)
        hasCloudflareResult = true
        // A pause moves the next full fetch to its end; otherwise keep polling on the full interval.
        scheduleCloudflareTimers(restartingFullFetch: cloudflarePolling.pausedUntil != nil)
        notify()
    }
}
