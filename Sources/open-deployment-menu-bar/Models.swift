import Foundation

struct Preferences: Codable, Equatable {
    static let personalScopeIdentifier = "__personal__"

    var teamId: String
    var projectName: String
    var gitBranches: String
    var showProduction: Bool
    var showPreview: Bool
    var showReady: Bool
    var showBuilding: Bool
    var showError: Bool
    var showQueued: Bool
    var showCanceled: Bool
    var limitByCount: Int?
    var limitByHours: Int?
    var refreshIntervalIdle: Int?
    var refreshIntervalBuilding: Int?
    var cloudflare: CloudflarePreferences
    var general: GeneralPreferences

    static let `default` = Preferences(
        teamId: "",
        projectName: "",
        gitBranches: "",
        showProduction: true,
        showPreview: true,
        showReady: true,
        showBuilding: true,
        showError: true,
        showQueued: true,
        showCanceled: true,
        limitByCount: 5,
        limitByHours: nil,
        refreshIntervalIdle: 15,
        refreshIntervalBuilding: 2,
        cloudflare: .default,
        general: .default
    )

    var teamIdList: [String] {
        commaSeparatedList(from: teamId)
    }

    var projectNameList: [String] {
        commaSeparatedList(from: projectName)
    }

    var normalizedProjectNameSet: Set<String> {
        Set(projectNameList.map { $0.lowercased() })
    }

    var singleProjectName: String? {
        let projects = projectNameList
        guard projects.count == 1 else { return nil }
        return projects[0]
    }

    var branchList: [String] {
        gitBranches
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func commaSeparatedList(from value: String) -> [String] {
        var results: [String] = []
        var seen: Set<String> = []

        for token in value.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let normalized = trimmed.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            results.append(trimmed)
        }

        return results
    }
}

extension Preferences {
    /// Settings saved before Cloudflare support have no `cloudflare` or `general` key; they fall back to the defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teamId = try container.decode(String.self, forKey: .teamId)
        projectName = try container.decode(String.self, forKey: .projectName)
        gitBranches = try container.decode(String.self, forKey: .gitBranches)
        showProduction = try container.decode(Bool.self, forKey: .showProduction)
        showPreview = try container.decode(Bool.self, forKey: .showPreview)
        showReady = try container.decode(Bool.self, forKey: .showReady)
        showBuilding = try container.decode(Bool.self, forKey: .showBuilding)
        showError = try container.decode(Bool.self, forKey: .showError)
        showQueued = try container.decode(Bool.self, forKey: .showQueued)
        showCanceled = try container.decode(Bool.self, forKey: .showCanceled)
        limitByCount = try container.decodeIfPresent(Int.self, forKey: .limitByCount)
        limitByHours = try container.decodeIfPresent(Int.self, forKey: .limitByHours)
        refreshIntervalIdle = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalIdle)
        refreshIntervalBuilding = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalBuilding)
        cloudflare = try container.decodeIfPresent(CloudflarePreferences.self, forKey: .cloudflare) ?? .default
        general = try container.decodeIfPresent(GeneralPreferences.self, forKey: .general) ?? .default
    }
}

struct CloudflarePreferences: Codable, Equatable {
    /// Empty means every account the token can access.
    var accountIDs: [String] = []
    /// Empty means every Pages project and Worker in the account scope.
    var projects: [CloudflareProjectScope] = []
    var gitBranches = ""
    var showProduction = true
    var showPreview = true
    var showReady = true
    var showBuilding = true
    var showError = true
    var showQueued = true
    var showCanceled = true
    var showSkipped = true
    /// 0 means no count limit. Count takes priority over hours when both are set, as for Vercel.
    var limitByCount = 5
    var limitByHours: Int?
    /// Seconds between full fetches.
    var refreshInterval = 30
    /// Seconds between re-queries of only the in-progress rows while any exist.
    var fastRefreshInterval = 5

    static let `default` = CloudflarePreferences()

    var branchList: [String] {
        gitBranches
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

extension CloudflarePreferences {
    /// Missing keys fall back to the defaults so fields added later still decode older settings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .default
        func decode<Value: Decodable>(_ key: CodingKeys, into value: inout Value) throws {
            if let decoded = try container.decodeIfPresent(Value.self, forKey: key) {
                value = decoded
            }
        }
        try decode(.accountIDs, into: &accountIDs)
        try decode(.projects, into: &projects)
        try decode(.gitBranches, into: &gitBranches)
        try decode(.showProduction, into: &showProduction)
        try decode(.showPreview, into: &showPreview)
        try decode(.showReady, into: &showReady)
        try decode(.showBuilding, into: &showBuilding)
        try decode(.showError, into: &showError)
        try decode(.showQueued, into: &showQueued)
        try decode(.showCanceled, into: &showCanceled)
        try decode(.showSkipped, into: &showSkipped)
        try decode(.limitByCount, into: &limitByCount)
        limitByHours = try container.decodeIfPresent(Int.self, forKey: .limitByHours)
        try decode(.refreshInterval, into: &refreshInterval)
        try decode(.fastRefreshInterval, into: &fastRefreshInterval)
    }
}

/// A Pages project or Worker chosen in the Cloudflare project scope.
struct CloudflareProjectScope: Codable, Hashable {
    enum Kind: String, Codable {
        case pages
        case workers
    }

    let kind: Kind
    let accountID: String
    let name: String
}

/// How the dropdown groups deployments: one merged list, or one section per platform.
enum MenuLayout: String, Codable, CaseIterable {
    case byTime
    case byPlatform
}

/// Settings shared by every platform.
struct GeneralPreferences: Codable, Equatable {
    var menuLayout: MenuLayout

    static let `default` = GeneralPreferences(menuLayout: .byTime)
}

extension GeneralPreferences {
    /// Missing or unrecognized values fall back to the defaults so older or newer settings still decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menuLayout = (try? container.decodeIfPresent(MenuLayout.self, forKey: .menuLayout)) ?? Self.default.menuLayout
    }
}

final class PreferencesStore {
    static let shared = PreferencesStore()

    static let didChangeNotification = Notification.Name("PreferencesStoreDidChange")

    static let storageKey = "vercelStatusPreferences"
    static let legacyDomain = "com.andrew.vercel-deployment-menu-bar"
    /// JSON key under which earlier versions kept the Vercel token in plaintext.
    static let plaintextTokenKey = "vercelToken"

    private let userDefaults: UserDefaults
    private let tokenStore: TokenStore
    /// Polling reads tokens on every refresh; caching keeps that from hitting the Keychain each time.
    private var cachedTokens: [TokenAccount: String?] = [:]

    private(set) var current: Preferences {
        didSet {
            persist()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: current)
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        legacyUserDefaults: UserDefaults? = UserDefaults(suiteName: PreferencesStore.legacyDomain),
        tokenStore: TokenStore = KeychainTokenStore()
    ) {
        self.userDefaults = userDefaults
        self.tokenStore = tokenStore
        // Settings saved under the old bundle ID are copied once; existing settings always win.
        if
            userDefaults.object(forKey: Self.storageKey) == nil,
            let legacyData = legacyUserDefaults?.data(forKey: Self.storageKey)
        {
            userDefaults.set(legacyData, forKey: Self.storageKey)
        }
        Self.migratePlaintextToken(in: [userDefaults, legacyUserDefaults].compactMap { $0 }, to: tokenStore)
        if
            let data = userDefaults.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        {
            current = decoded
        } else {
            current = .default
        }
    }

    func update(_ transform: (inout Preferences) -> Void) {
        var updated = current
        transform(&updated)
        current = updated
    }

    func save(_ preferences: Preferences) {
        current = preferences
    }

    func token(for account: TokenAccount) -> String? {
        if let cached = cachedTokens[account] {
            return cached
        }
        let stored = tokenStore.token(for: account)
        cachedTokens[account] = .some(stored)
        return stored
    }

    /// Makes the next `token(for:)` read the store again, picking up changes made outside the app.
    func discardCachedToken(for account: TokenAccount) {
        cachedTokens[account] = nil
    }

    /// Stores the trimmed token; an empty value deletes the stored token.
    func setToken(_ token: String, for account: TokenAccount) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try tokenStore.deleteToken(for: account)
                cachedTokens[account] = .some(nil)
            } else {
                try tokenStore.setToken(trimmed, for: account)
                cachedTokens[account] = .some(trimmed)
            }
        } catch {
            cachedTokens[account] = nil
            throw error
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: current)
    }

    /// Moves a plaintext Vercel token left by earlier versions into the token store, preferring the first domain's
    /// value. The plaintext is removed from every domain only once the token store holds a token, so a failed
    /// write leaves all domains untouched and is retried on the next launch.
    private static func migratePlaintextToken(in domains: [UserDefaults], to tokenStore: TokenStore) {
        let documents = domains.compactMap { defaults -> (UserDefaults, [String: Any])? in
            guard
                let data = defaults.data(forKey: storageKey),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object[plaintextTokenKey] != nil
            else {
                return nil
            }
            return (defaults, object)
        }
        guard !documents.isEmpty else { return }

        let plaintextToken = documents
            .compactMap { ($0.1[plaintextTokenKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let plaintextToken, tokenStore.token(for: .vercel) == nil {
            do {
                try tokenStore.setToken(plaintextToken, for: .vercel)
            } catch {
                NSLog("Keeping plaintext Vercel token until next launch: %@", error.localizedDescription)
                return
            }
        }

        for (defaults, var object) in documents {
            object.removeValue(forKey: plaintextTokenKey)
            if let data = try? JSONSerialization.data(withJSONObject: object) {
                defaults.set(data, forKey: storageKey)
            }
        }
    }

    private func persist() {
        guard
            let encoded = try? JSONEncoder().encode(current),
            var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else {
            return
        }
        // A plaintext token whose migration failed is kept so the next launch can retry it.
        if
            let storedData = userDefaults.data(forKey: Self.storageKey),
            let stored = try? JSONSerialization.jsonObject(with: storedData) as? [String: Any],
            let plaintextToken = stored[Self.plaintextTokenKey]
        {
            object[Self.plaintextTokenKey] = plaintextToken
        }
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }
}

struct Team: Decodable {
    let id: String
    let slug: String
    let name: String
}

struct TeamsResponse: Decodable {
    let teams: [Team]
}

struct Project: Decodable {
    let id: String
    let name: String
}

struct ProjectsResponse: Decodable {
    let projects: [Project]
}

/// Provider-neutral deployment consumed by filtering, sorting, the status button, and the menu.
struct Deployment: Equatable {
    enum Platform: Equatable {
        case vercel
        case cloudflarePages
        case cloudflareWorkers
    }

    enum State: Equatable {
        case queued
        case building
        case ready
        case error
        case canceled
        /// Cloudflare Pages deployments skipped by build watch paths or branch rules; Vercel never reports it.
        case skipped
        case unknown
    }

    enum Environment: Equatable {
        case production
        case preview
        /// Any other provider environment name (e.g. Vercel custom environments), kept as reported.
        case custom(String)
    }

    let id: String
    let platform: Platform
    let projectName: String
    let state: State
    let createdAt: Date
    let buildStartedAt: Date?
    let finishedAt: Date?
    let branch: String?
    let environment: Environment?
    let commitMessage: String?
    let openURL: URL?
    let sourceLabel: String?
    let trafficPercentage: Int?

    /// Start of the build, falling back to creation when the provider has not reported one.
    var buildStartDate: Date {
        buildStartedAt ?? createdAt
    }
}

extension Deployment {
    /// Rows from every platform interleaved into one list, newest first.
    static func mergedNewestFirst(_ lists: [Deployment]...) -> [Deployment] {
        lists.joined().sorted { $0.createdAt > $1.createdAt }
    }
}

struct VercelDeployment: Decodable {
    enum State: String, Decodable {
        case building = "BUILDING"
        case error = "ERROR"
        case ready = "READY"
        case queued = "QUEUED"
        case canceled = "CANCELED"
        case unknown

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = State(rawValue: rawValue) ?? .unknown
        }
    }

    struct Creator: Decodable {
        let username: String?
    }

    struct Meta: Decodable {
        let githubCommitMessage: String?
        let githubCommitRef: String?
    }

    struct GitSource: Decodable {
        let ref: String?
        let type: String?
    }

    let uid: String
    let name: String
    let url: String
    let inspectorUrl: String?
    let created: TimeInterval
    let state: State
    let ready: TimeInterval?
    let buildingAt: TimeInterval?
    let target: String?
    let creator: Creator
    let meta: Meta?
    let gitSource: GitSource?
}

struct VercelDeploymentsResponse: Decodable {
    let deployments: [VercelDeployment]
}

extension Deployment {
    init(vercel deployment: VercelDeployment) {
        let branch = deployment.gitSource?.ref ?? deployment.meta?.githubCommitRef
        self.init(
            id: deployment.uid,
            platform: .vercel,
            projectName: deployment.name,
            state: State(vercel: deployment.state),
            createdAt: Self.date(fromMilliseconds: deployment.created),
            buildStartedAt: deployment.buildingAt.map(Self.date(fromMilliseconds:)),
            finishedAt: deployment.ready.map(Self.date(fromMilliseconds:)),
            branch: branch?.isEmpty == false ? branch : nil,
            environment: Environment(vercelTarget: deployment.target),
            commitMessage: deployment.meta?.githubCommitMessage,
            openURL: Self.vercelOpenURL(for: deployment),
            sourceLabel: nil,
            trafficPercentage: nil
        )
    }

    private static func date(fromMilliseconds milliseconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Vercel's inspector page when available, otherwise the deployment URL (which the API returns without a scheme).
    private static func vercelOpenURL(for deployment: VercelDeployment) -> URL? {
        if
            let inspectorUrl = deployment.inspectorUrl,
            !inspectorUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let url = URL(string: inspectorUrl)
        {
            return url
        }
        if deployment.url.hasPrefix("http://") || deployment.url.hasPrefix("https://") {
            return URL(string: deployment.url)
        }
        return URL(string: "https://\(deployment.url)")
    }
}

extension Deployment.State {
    init(vercel state: VercelDeployment.State) {
        switch state {
        case .queued: self = .queued
        case .building: self = .building
        case .ready: self = .ready
        case .error: self = .error
        case .canceled: self = .canceled
        case .unknown: self = .unknown
        }
    }
}

extension Deployment.Environment {
    init?(vercelTarget target: String?) {
        guard let target else { return nil }
        switch target.lowercased() {
        case "production": self = .production
        case "preview": self = .preview
        default: self = .custom(target)
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse(status: Int, message: String)
    case decodingFailure

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(status, message):
            return "Vercel API error (\(status)): \(message)"
        case .decodingFailure:
            return "Failed to decode response from Vercel."
        }
    }
}
