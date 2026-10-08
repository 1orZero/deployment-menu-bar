import Foundation

/// Both platforms' latest deployments as last fetched on this iPhone. The app saves one after every update and the
/// widget reads it, so a widget can show the app's rows without fetching on its own while they are fresh.
struct DeploymentSnapshot: Codable, Equatable {
    var vercel: PlatformStatus
    var cloudflare: PlatformStatus
    /// When the newest successful fetch finished; nil before the first one.
    var fetchedAt: Date?
    /// A Cloudflare 429 pause, carried over so the widget sends no Cloudflare request before it ends.
    var cloudflarePausedUntil: Date?
    /// Accounts the Cloudflare token reached; the dashboard link opens the account directly when there is one.
    var cloudflareAccountIDs: [String] = []

    /// No token on either platform yet.
    static let empty = DeploymentSnapshot(
        vercel: PlatformStatus(isEnabled: false),
        cloudflare: PlatformStatus(isEnabled: false)
    )

    var hasToken: Bool {
        vercel.isEnabled || cloudflare.isEnabled
    }

    /// Rows of every enabled platform, newest first.
    var deployments: [Deployment] {
        Deployment.mergedNewestFirst(vercel.deployments, cloudflare.deployments)
    }

    var latest: Deployment? {
        deployments.first
    }

    func deployment(id: String) -> Deployment? {
        deployments.first { $0.id == id }
    }

    /// "Vercel: …" and "Cloudflare: …" messages for platforms that failed or are degraded.
    var issues: [String] {
        [(MenuPlatform.vercel, vercel), (MenuPlatform.cloudflare, cloudflare)].compactMap { platform, status in
            guard status.isEnabled, let issue = status.issue else { return nil }
            return "\(platform.name): \(issue.message)"
        }
    }

    /// State totals of the rows created on the same calendar day as `now`.
    func todayCounts(now: Date = Date(), calendar: Calendar = .current) -> StateCounts {
        StateCounts(deployments.filter { calendar.isDate($0.createdAt, inSameDayAs: now) })
    }

    /// The same rows grouped the way the Mac menu groups them for `layout`.
    func composition(layout: MenuLayout) -> MenuComposition {
        MenuComposition(layout: layout, vercel: vercel, cloudflare: cloudflare)
    }
}

/// How many rows are in progress, ready or failed. Queued rows count as building; canceled, skipped and unknown rows
/// are in none of the totals.
struct StateCounts: Equatable {
    var building = 0
    var ready = 0
    var failed = 0

    init(_ deployments: [Deployment]) {
        for deployment in deployments {
            switch deployment.state {
            case .building, .queued: building += 1
            case .ready: ready += 1
            case .error: failed += 1
            case .canceled, .skipped, .unknown: break
            }
        }
    }

    var total: Int {
        building + ready + failed
    }
}

/// Reads and writes the snapshot in the App Group container shared by the app and the widget.
enum SnapshotStore {
    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: PreferencesStore.appGroupIdentifier)?
            .appendingPathComponent("deployment-snapshot.json")
    }

    static func load() -> DeploymentSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(DeploymentSnapshot.self, from: data)
    }

    static func save(_ snapshot: DeploymentSnapshot) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Could not save deployment snapshot: %@", error.localizedDescription)
        }
    }
}
