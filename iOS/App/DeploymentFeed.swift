import Combine
import SwiftUI
import WidgetKit

/// The app's live deployments: polls with the Mac app's schedule while the app is in the foreground and publishes a
/// snapshot after every change. Each snapshot is saved for the widget, and widgets reload when rows change; reloads
/// requested while the app is in the foreground do not count against the widget's daily budget.
@MainActor
final class DeploymentFeed: ObservableObject {
    @Published private(set) var snapshot: DeploymentSnapshot

    private let store: PreferencesStore
    private let poller: DeploymentPoller
    private var preferencesObserver: AnyCancellable?
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init(store: PreferencesStore = .shared) {
        self.store = store
        poller = DeploymentPoller(store: store)
        snapshot = SnapshotStore.load() ?? .empty
        poller.onUpdate = { [weak self] in
            MainActor.assumeIsolated { self?.publish() }
        }
        preferencesObserver = NotificationCenter.default
            .publisher(for: PreferencesStore.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.poller.refresh() }
    }

    /// Starts polling; call when the scene becomes active. Tokens are re-read, so ones synced from the Mac while the
    /// app was in the background are picked up.
    func start() {
        poller.refresh()
    }

    /// Stops the timers; call when the scene leaves the foreground.
    func stop() {
        poller.stop()
    }

    /// Fetches now and returns after the next update (or 15 seconds), for pull to refresh.
    func refreshNow() async {
        await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
            poller.refresh()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.resumeRefreshWaiters()
            }
        }
    }

    private func publish() {
        let updated = DeploymentSnapshot(
            vercel: poller.hasVercelResult ? poller.vercel : snapshot.vercel,
            cloudflare: poller.hasCloudflareResult ? poller.cloudflare : snapshot.cloudflare,
            fetchedAt: poller.lastFetchDate ?? snapshot.fetchedAt,
            cloudflarePausedUntil: poller.cloudflarePausedUntil,
            cloudflareAccountIDs: poller.hasCloudflareResult ? poller.cloudflareAccountIDs : snapshot.cloudflareAccountIDs
        )
        resumeRefreshWaiters()
        guard updated != snapshot else { return }
        let rowsChanged = updated.vercel != snapshot.vercel || updated.cloudflare != snapshot.cloudflare
        snapshot = updated
        SnapshotStore.save(updated)
        if rowsChanged {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func resumeRefreshWaiters() {
        let waiters = refreshWaiters
        refreshWaiters = []
        waiters.forEach { $0.resume() }
    }
}
