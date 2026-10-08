import Foundation

/// Pages and Workers deployments across every account the token can access.
struct CloudflareSnapshot {
    let accountIDs: [String]
    let deployments: [Deployment]
    /// Set when rows are shown without Workers build status.
    let issue: PlatformIssue?
    /// In-progress rows, re-queried one by one by the fast tier.
    let pendingItems: [CloudflarePendingItem]
}

/// A Queued or Building row and the single request that refreshes it.
struct CloudflarePendingItem: Equatable {
    enum Source: Equatable {
        case pagesDeployment(projectName: String)
        case workersBuild(buildUUID: String)
    }

    let rowID: String
    let accountID: String
    let source: Source
}

/// A fast-tier result: the refreshed Pages row, or the refreshed build behind a Workers row.
enum CloudflarePendingUpdate {
    case pagesDeployment(Deployment)
    case workersBuild(rowID: String, CloudflareWorkerBuild)
}

private struct CloudflareRows {
    var deployments: [Deployment]
    var issue: PlatformIssue?
    var pendingItems: [CloudflarePendingItem] = []
    /// Pages projects and Workers whose list hit the page budget before the filters and limits were satisfied.
    var truncatedLists: [String] = []
}

final class CloudflareService {
    private static let baseURL = "https://api.cloudflare.com/client/v4/"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Only account-scoped endpoints are used, so account-owned tokens work as well as user tokens, except for Workers
    /// build status (see `fetchWorkerRows`). Pages and Workers are fetched independently, so one failing still returns
    /// the other's rows. Pages deployments per project and Workers builds per connected Worker are paged (see
    /// `fetchPaged`) until enough rows pass the branch, environment and state filters for the count or hours limit,
    /// so newer hidden rows cannot crowd out older shown ones; usually the first page is enough. Each list is capped at
    /// 100 items per fetch to protect the 1200 requests / 5 minutes budget (a 429 also blocks the user's dashboard and
    /// wrangler); a list cut off by that cap is named in the snapshot's issue, so partial rows are never shown as
    /// complete. With only one of Production / Preview shown, Pages filters the environment server-side; with neither,
    /// no Pages requests are made. Several issues are joined into one message.
    /// The account and project scope are applied here: unselected accounts, Pages projects and Workers are not requested.
    func fetchDeployments(token: String, preferences: CloudflarePreferences) async throws -> CloudflareSnapshot {
        let selectedProjects = preferences.projects
        var accountIDs = preferences.accountIDs
        if accountIDs.isEmpty {
            let accounts: [CloudflareAccount] = try await get("accounts?per_page=50", token: token)
            accountIDs = accounts.map(\.id)
        }
        if !selectedProjects.isEmpty {
            let projectAccountIDs = Set(selectedProjects.map(\.accountID))
            accountIDs = accountIDs.filter(projectAccountIDs.contains)
        }

        let rows = try await collect(accountIDs) { accountID in
            // nil = every project of that kind in the account.
            func names(_ kind: CloudflareProjectScope.Kind) -> Set<String>? {
                guard !selectedProjects.isEmpty else { return nil }
                return Set(selectedProjects.filter { $0.kind == kind && $0.accountID == accountID }.map(\.name))
            }
            let workerNames = names(.workers)
            let pagesNames = names(.pages)
            var sources: [() async throws -> CloudflareRows] = []
            if workerNames?.isEmpty != true {
                sources.append {
                    try await self.fetchWorkerRows(
                        token: token,
                        accountID: accountID,
                        preferences: preferences,
                        scriptNames: workerNames
                    )
                }
            }
            // Every Pages deployment is Production or Preview, so with both hidden none could be shown.
            if pagesNames?.isEmpty != true, preferences.showProduction || preferences.showPreview {
                sources.append {
                    try await self.fetchPagesRows(
                        token: token,
                        accountID: accountID,
                        preferences: preferences,
                        projectNames: pagesNames
                    )
                }
            }
            return try await self.collect(sources) { try await $0() }
        }.joined()
        var seenMessages: Set<String> = []
        var messages = rows.compactMap(\.issue?.message).filter { seenMessages.insert($0).inserted }
        if let partial = Self.partialResultsMessage(truncatedLists: rows.flatMap(\.truncatedLists)) {
            messages.append(partial)
        }
        return CloudflareSnapshot(
            accountIDs: accountIDs,
            deployments: Deployment.mergedNewestFirst(rows.flatMap(\.deployments)),
            issue: messages.isEmpty ? nil : PlatformIssue(message: messages.joined(separator: " · ")),
            pendingItems: rows.flatMap(\.pendingItems)
        )
    }

    /// Names up to three cut-off lists, then how many more.
    static func partialResultsMessage(truncatedLists: [String]) -> String? {
        guard !truncatedLists.isEmpty else { return nil }
        let names = truncatedLists.sorted()
        var listed = names.prefix(3).joined(separator: ", ")
        if names.count > 3 {
            listed += " +\(names.count - 3) more"
        }
        return "Partial results: stopped after \(maxPages * pageSize) deployments for \(listed)"
    }

    /// One request per item: Pages re-reads the deployment, Workers re-reads the build behind the row. Failed items are
    /// skipped unless every item fails; a 429 is always thrown.
    func fetchPendingUpdates(token: String, items: [CloudflarePendingItem]) async throws -> [CloudflarePendingUpdate] {
        try await collect(items) { item -> CloudflarePendingUpdate? in
            switch item.source {
            case let .pagesDeployment(projectName):
                let deployment: CloudflarePagesDeployment = try await self.get(
                    "accounts/\(item.accountID)/pages/projects/\(projectName)/deployments/\(item.rowID)",
                    token: token
                )
                return Deployment(pages: deployment, accountID: item.accountID, projectName: projectName)
                    .map(CloudflarePendingUpdate.pagesDeployment)
            case let .workersBuild(buildUUID):
                let build: CloudflareWorkerBuild = try await self.get(
                    "accounts/\(item.accountID)/builds/builds/\(buildUUID)",
                    token: token
                )
                return .workersBuild(rowID: item.rowID, build)
            }
        }.compactMap { $0 }
    }

    /// Accounts, Pages projects and Workers the token can access, for the Cloudflare scope pickers. Accounts whose
    /// Pages or Workers list fails still list the other kind.
    func fetchScopeOptions(token: String) async throws -> CloudflareScopeOptions {
        let accounts: [CloudflareAccount] = try await get("accounts?per_page=50", token: token)
        let projects = try await collect(accounts) { account in
            let sources: [() async throws -> [CloudflareProjectScope]] = [
                {
                    let scripts: [CloudflareWorkerScript] = try await self.get(
                        "accounts/\(account.id)/workers/scripts",
                        token: token
                    )
                    return scripts.map { CloudflareProjectScope(kind: .workers, accountID: account.id, name: $0.id) }
                },
                {
                    let pages: [CloudflarePagesProject] = try await self.get(
                        "accounts/\(account.id)/pages/projects",
                        token: token
                    )
                    return pages.map { CloudflareProjectScope(kind: .pages, accountID: account.id, name: $0.name) }
                },
            ]
            return try await self.collect(sources) { try await $0() }.joined()
        }.joined()
        return CloudflareScopeOptions(accounts: accounts, projects: Array(projects))
    }

    /// Workers deployments joined with their Workers Builds. Requests per account: the script list, one deployments
    /// request per script and one `builds/latest` request per 20 scripts; only scripts connected to Workers Builds add
    /// one build list request each (more pages only when the filters need them, see `fetchPaged`), plus one version
    /// lookup per 20 versions they deployed. When the Builds API fails (it rejects account-owned tokens and tokens
    /// without Workers CI Read), the deployments are still returned.
    private func fetchWorkerRows(
        token: String,
        accountID: String,
        preferences: CloudflarePreferences,
        scriptNames: Set<String>?
    ) async throws -> CloudflareRows {
        let allScripts: [CloudflareWorkerScript] = try await get("accounts/\(accountID)/workers/scripts", token: token)
        let scripts = allScripts.filter { scriptNames?.contains($0.id) ?? true }
        async let connectedTags = fetchConnectedScriptTags(
            token: token,
            accountID: accountID,
            tags: scripts.compactMap(\.tag)
        )
        let scriptDeployments = try await collect(scripts) { script in
            let result: CloudflareWorkerDeploymentsResult = try await self.get(
                "accounts/\(accountID)/workers/scripts/\(script.id)/deployments",
                token: token
            )
            return (script: script, deployments: result.deployments)
        }

        var builds: [String: CloudflareWorkerBuilds] = [:]
        var truncatedLists: [String] = []
        var issue: PlatformIssue?
        do {
            (builds, truncatedLists) = try await fetchWorkerBuilds(
                token: token,
                accountID: accountID,
                preferences: preferences,
                connectedTags: try await connectedTags,
                scriptDeployments: scriptDeployments
            )
        } catch {
            if CloudflareAPIError.rateLimitEnd(of: error) != nil { throw error }
            issue = Self.workersBuildsIssue(for: error)
        }

        var rows = CloudflareRows(deployments: [], issue: issue, truncatedLists: truncatedLists)
        for entry in scriptDeployments {
            for (row, buildUUID) in Deployment.cloudflareWorkersRows(
                entry.deployments,
                builds: builds[entry.script.id] ?? .none,
                accountID: accountID,
                scriptName: entry.script.id
            ) {
                rows.deployments.append(row)
                if row.state.isInProgress, let buildUUID {
                    rows.pendingItems.append(
                        CloudflarePendingItem(rowID: row.id, accountID: accountID, source: .workersBuild(buildUUID: buildUUID))
                    )
                }
            }
        }
        return rows
    }

    /// Tags of the scripts that have at least one build, i.e. are connected to Workers Builds.
    private func fetchConnectedScriptTags(token: String, accountID: String, tags: [String]) async throws -> Set<String> {
        var connected: Set<String> = []
        for batch in Self.batches(of: tags) {
            let result: CloudflareWorkerBuildMap = try await get(
                "accounts/\(accountID)/builds/builds/latest?external_script_ids=\(batch.joined(separator: ","))",
                token: token
            )
            for (tag, build) in result.builds ?? [:] {
                connected.insert(tag)
                if let externalScriptID = build.trigger?.externalScriptID {
                    connected.insert(externalScriptID)
                }
            }
        }
        return connected
    }

    /// Recent builds of each connected script and the builds behind its deployed versions, keyed by script name, and
    /// the scripts whose build list hit the page budget.
    private func fetchWorkerBuilds(
        token: String,
        accountID: String,
        preferences: CloudflarePreferences,
        connectedTags: Set<String>,
        scriptDeployments: [(script: CloudflareWorkerScript, deployments: [CloudflareWorkerDeployment])]
    ) async throws -> (builds: [String: CloudflareWorkerBuilds], truncatedLists: [String]) {
        let connected = scriptDeployments.filter { $0.script.tag.map(connectedTags.contains) == true }
        guard !connected.isEmpty else { return ([:], []) }

        let versionIDs = Set(connected.flatMap { $0.deployments.flatMap { $0.versions.map(\.versionID) } })
        async let byVersionID = fetchBuildsByVersion(token: token, accountID: accountID, versionIDs: Array(versionIDs))
        let recent = try await collect(connected) { entry in
            // Rows are only built after the join, so the filters see each build as the row it makes unjoined. A joined
            // build becomes a Production row, which its `wrangler deploy` command also gives it unjoined.
            let list = try await self.fetchPaged(
                "accounts/\(accountID)/builds/workers/\(entry.script.tag ?? "")/builds",
                token: token,
                preferences: preferences
            ) { (build: CloudflareWorkerBuild) in
                Deployment.cloudflareWorkersBuildRow(build, accountID: accountID, scriptName: entry.script.id)
            }
            return (scriptName: entry.script.id, builds: list.items, truncated: list.truncated)
        }
        let recentByScript = Dictionary(recent.map { ($0.scriptName, $0.builds) }, uniquingKeysWith: { first, _ in first })
        let versions = try await byVersionID

        let builds = Dictionary(
            connected.map { entry in
                (entry.script.id, CloudflareWorkerBuilds(recent: recentByScript[entry.script.id] ?? [], byVersionID: versions))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return (builds, recent.filter(\.truncated).map(\.scriptName))
    }

    /// The build that produced each version; versions uploaded without Workers Builds have no entry.
    private func fetchBuildsByVersion(
        token: String,
        accountID: String,
        versionIDs: [String]
    ) async throws -> [String: CloudflareWorkerBuild] {
        var builds: [String: CloudflareWorkerBuild] = [:]
        for batch in Self.batches(of: versionIDs) {
            let result: CloudflareWorkerBuildMap = try await get(
                "accounts/\(accountID)/builds/builds?version_ids=\(batch.joined(separator: ","))",
                token: token
            )
            builds.merge(result.builds ?? [:]) { first, _ in first }
        }
        return builds
    }

    /// The batch Builds endpoints accept at most 20 IDs per request.
    private static func batches(of ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: 20).map { Array(ids[$0..<min($0 + 20, ids.count)]) }
    }

    static func workersBuildsIssue(for error: Error) -> PlatformIssue {
        if case let CloudflareAPIError.invalidResponse(status, _) = error, status == 401 || status == 403 {
            return PlatformIssue(message: "Workers build status needs a user API token with Workers CI Read")
        }
        return PlatformIssue(message: "Workers build status unavailable: \(error.localizedDescription)")
    }

    /// `projectNames` nil = every project in the account; selected projects are requested without listing projects.
    private func fetchPagesRows(
        token: String,
        accountID: String,
        preferences: CloudflarePreferences,
        projectNames: Set<String>?
    ) async throws -> CloudflareRows {
        let names: [String]
        if let projectNames {
            names = projectNames.sorted()
        } else {
            let projects: [CloudflarePagesProject] = try await get("accounts/\(accountID)/pages/projects", token: token)
            names = projects.map(\.name)
        }
        // The API filters by environment; with both shown, no filter is sent.
        let environmentQuery: [String] = switch (preferences.showProduction, preferences.showPreview) {
        case (true, false): ["env=production"]
        case (false, true): ["env=preview"]
        default: []
        }
        let lists = try await collect(names) { projectName in
            let list = try await self.fetchPaged(
                "accounts/\(accountID)/pages/projects/\(projectName)/deployments",
                query: environmentQuery,
                token: token,
                preferences: preferences
            ) { (deployment: CloudflarePagesDeployment) in
                Deployment(pages: deployment, accountID: accountID, projectName: projectName)
            }
            return (projectName: projectName, rows: list.rows, truncated: list.truncated)
        }
        let rows = lists.flatMap(\.rows)
        let pendingItems = rows.filter(\.state.isInProgress).map { row in
            CloudflarePendingItem(rowID: row.id, accountID: accountID, source: .pagesDeployment(projectName: row.projectName))
        }
        return CloudflareRows(
            deployments: rows,
            pendingItems: pendingItems,
            truncatedLists: lists.filter(\.truncated).map(\.projectName)
        )
    }

    private static let pageSize = 25
    /// At most 100 items per list per full fetch, to stay well inside 1200 requests per 5 minutes.
    private static let maxPages = 4

    /// Requests pages of a newest-first list until one of: `limitByCount` rows pass `preferences.matches`; in hours
    /// mode, the page reaches past the window; a page is not full; `maxPages` pages. Without any limit it pages
    /// until the list ends or `maxPages`. `truncated` = stopped by `maxPages` with a full last page and neither limit
    /// satisfied, so older matching rows may be missing.
    private func fetchPaged<Item: Decodable>(
        _ path: String,
        query: [String] = [],
        token: String,
        preferences: CloudflarePreferences,
        row: (Item) -> Deployment?
    ) async throws -> (items: [Item], rows: [Deployment], truncated: Bool) {
        let cutoff = preferences.hoursCutoff(now: Date())
        var items: [Item] = []
        var rows: [Deployment] = []
        var matched = 0
        for page in 1...Self.maxPages {
            let pageQuery = (query + ["page=\(page)", "per_page=\(Self.pageSize)"]).joined(separator: "&")
            let pageItems: [Item] = try await get("\(path)?\(pageQuery)", token: token)
            let pageRows = pageItems.compactMap(row)
            items += pageItems
            rows += pageRows
            matched += pageRows.lazy.filter(preferences.matches).count

            if pageItems.count < Self.pageSize { break }
            if preferences.limitByCount > 0, matched >= preferences.limitByCount { break }
            if let cutoff, let oldest = pageRows.map(\.createdAt).min(), oldest < cutoff { break }
            if page == Self.maxPages {
                return (items, rows, true)
            }
        }
        return (items, rows, false)
    }

    /// Fetches every element in parallel. Failed elements are skipped; the first error is thrown only when all fail.
    /// A 429 is thrown at once and cancels the remaining requests, since every further request would be rejected too.
    private func collect<Element, Value>(
        _ elements: [Element],
        _ fetch: @escaping (Element) async throws -> Value
    ) async throws -> [Value] {
        let outcome = await withTaskGroup(
            of: Result<Value, Error>.self,
            returning: (values: [Value], firstError: Error?).self
        ) { group in
            for element in elements {
                group.addTask {
                    do {
                        return .success(try await fetch(element))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var values: [Value] = []
            var firstError: Error?

            for await result in group {
                switch result {
                case let .success(value):
                    values.append(value)
                case let .failure(error):
                    if CloudflareAPIError.rateLimitEnd(of: error) != nil {
                        group.cancelAll()
                        return ([], error)
                    }
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
            return (values, firstError)
        }

        if let firstError = outcome.firstError,
           outcome.values.isEmpty || CloudflareAPIError.rateLimitEnd(of: firstError) != nil {
            throw firstError
        }

        return outcome.values
    }

    private func get<Value: Decodable>(_ path: String, token: String) async throws -> Value {
        guard let url = URL(string: Self.baseURL + path) else {
            throw CloudflareAPIError.invalidResponse(status: -1, message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudflareAPIError.invalidResponse(status: -1, message: "No response")
        }

        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
            throw CloudflareAPIError.rateLimited(until: Self.rateLimitEnd(retryAfter: retryAfter, now: Date()))
        }

        let envelope = try? JSONDecoder().decode(CloudflareEnvelope<Value>.self, from: data)
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = envelope?.errors?.first.map { "\($0.message) (\($0.code))" }
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw CloudflareAPIError.invalidResponse(status: httpResponse.statusCode, message: message)
        }

        guard let result = envelope?.result else {
            throw CloudflareAPIError.decodingFailure
        }
        return result
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// When a 429 ends: `Retry-After` is either delay seconds or an HTTP date; without a usable value, 60 s from now.
    static func rateLimitEnd(retryAfter: String?, now: Date) -> Date {
        let value = retryAfter?.trimmingCharacters(in: .whitespaces) ?? ""
        if let seconds = Int(value), seconds >= 0 {
            return now.addingTimeInterval(TimeInterval(seconds))
        }
        if let date = httpDateFormatter.date(from: value) {
            return max(date, now)
        }
        return now.addingTimeInterval(60)
    }
}

enum CloudflareAPIError: LocalizedError {
    case invalidResponse(status: Int, message: String)
    case decodingFailure
    /// HTTP 429; Cloudflare rejects every request from the user until the date.
    case rateLimited(until: Date)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(status, message):
            return "Cloudflare API error (\(status)): \(message)"
        case .decodingFailure:
            return "Failed to decode response from Cloudflare."
        case .rateLimited:
            return "Rate limited by Cloudflare"
        }
    }

    static func rateLimitEnd(of error: Error) -> Date? {
        if case let .rateLimited(until) = error as? CloudflareAPIError {
            return until
        }
        return nil
    }
}

private struct CloudflareEnvelope<Value: Decodable>: Decodable {
    struct Message: Decodable {
        let code: Int
        let message: String
    }

    let errors: [Message]?
    let result: Value?
}

struct CloudflareAccount: Decodable {
    let id: String
    let name: String?
}

struct CloudflareScopeOptions {
    let accounts: [CloudflareAccount]
    let projects: [CloudflareProjectScope]
}

struct CloudflareWorkerScript: Decodable {
    /// The script name.
    let id: String
    /// Immutable script identifier that the Builds API calls `external_script_id`.
    let tag: String?
}

/// A Workers Builds build. Field reference:
/// https://developers.cloudflare.com/api/resources/workers_builds/subresources/builds/methods/list/
struct CloudflareWorkerBuild: Decodable {
    struct TriggerMetadata: Decodable {
        let branch: String?
        let commitMessage: String?
        let deployCommand: String?

        private enum CodingKeys: String, CodingKey {
            case branch
            case commitMessage = "commit_message"
            case deployCommand = "deploy_command"
        }
    }

    struct Trigger: Decodable {
        let externalScriptID: String?
        let deployCommand: String?

        private enum CodingKeys: String, CodingKey {
            case externalScriptID = "external_script_id"
            case deployCommand = "deploy_command"
        }
    }

    let buildUUID: String
    let status: String?
    let buildOutcome: String?
    let createdOn: String?
    let runningOn: String?
    let stoppedOn: String?
    let buildTriggerMetadata: TriggerMetadata?
    let trigger: Trigger?

    private enum CodingKeys: String, CodingKey {
        case buildUUID = "build_uuid"
        case status
        case buildOutcome = "build_outcome"
        case createdOn = "created_on"
        case runningOn = "running_on"
        case stoppedOn = "stopped_on"
        case buildTriggerMetadata = "build_trigger_metadata"
        case trigger
    }
}

/// Result of the batch build lookups, keyed by the requested script tag or version ID.
struct CloudflareWorkerBuildMap: Decodable {
    let builds: [String: CloudflareWorkerBuild]?
}

/// What a Worker's rows are joined with: its recent builds and the builds that produced each version.
struct CloudflareWorkerBuilds {
    var recent: [CloudflareWorkerBuild]
    var byVersionID: [String: CloudflareWorkerBuild]

    static let none = CloudflareWorkerBuilds(recent: [], byVersionID: [:])
}

struct CloudflareWorkerDeploymentsResult: Decodable {
    let deployments: [CloudflareWorkerDeployment]
}

struct CloudflareWorkerDeployment: Decodable {
    struct Version: Decodable {
        let versionID: String
        let percentage: Double

        private enum CodingKeys: String, CodingKey {
            case versionID = "version_id"
            case percentage
        }
    }

    struct Annotations: Decodable {
        let triggeredBy: String?
        let message: String?

        private enum CodingKeys: String, CodingKey {
            case triggeredBy = "workers/triggered_by"
            case message = "workers/message"
        }
    }

    let id: String
    let source: String?
    let createdOn: String
    let versions: [Version]
    let annotations: Annotations?

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case createdOn = "created_on"
        case versions
        case annotations
    }
}

struct CloudflarePagesProject: Decodable {
    let name: String
}

struct CloudflarePagesDeployment: Decodable {
    struct Stage: Decodable {
        let name: String
        let status: String
        let startedOn: String?
        let endedOn: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case status
            case startedOn = "started_on"
            case endedOn = "ended_on"
        }
    }

    struct Trigger: Decodable {
        struct Metadata: Decodable {
            let branch: String?
            let commitMessage: String?

            private enum CodingKeys: String, CodingKey {
                case branch
                case commitMessage = "commit_message"
            }
        }

        let metadata: Metadata?
    }

    let id: String
    let createdOn: String
    let environment: String?
    let isSkipped: Bool?
    let latestStage: Stage?
    let stages: [Stage]?
    let deploymentTrigger: Trigger?

    private enum CodingKeys: String, CodingKey {
        case id
        case createdOn = "created_on"
        case environment
        case isSkipped = "is_skipped"
        case latestStage = "latest_stage"
        case stages
        case deploymentTrigger = "deployment_trigger"
    }
}

extension Deployment {
    /// A Pages deployment row, or nil when its creation date cannot be parsed.
    init?(pages deployment: CloudflarePagesDeployment, accountID: String, projectName: String) {
        guard let createdAt = Self.cloudflareDate(from: deployment.createdOn) else { return nil }
        let state = State(pages: deployment)
        let stages = deployment.stages ?? []
        func date(ofStage name: String, _ keyPath: KeyPath<CloudflarePagesDeployment.Stage, String?>) -> Date? {
            stages.first { $0.name == name }?[keyPath: keyPath].flatMap(Self.cloudflareDate(from:))
        }
        // A finished deployment ends with its latest stage: deploy on success, the failing stage otherwise.
        let finishedAt: Date? = switch state {
        case .ready, .error, .canceled:
            deployment.latestStage?.endedOn.flatMap(Self.cloudflareDate(from:)) ?? date(ofStage: "deploy", \.endedOn)
        case .queued, .building, .skipped, .unknown:
            nil
        }
        let metadata = deployment.deploymentTrigger?.metadata
        let branch = metadata?.branch

        self.init(
            id: deployment.id,
            platform: .cloudflarePages,
            projectName: projectName,
            state: state,
            createdAt: createdAt,
            buildStartedAt: date(ofStage: "build", \.startedOn),
            finishedAt: finishedAt,
            branch: branch?.isEmpty == false ? branch : nil,
            environment: Environment(pagesEnvironment: deployment.environment),
            commitMessage: metadata?.commitMessage,
            openURL: URL(string: "https://dash.cloudflare.com/\(accountID)/pages/view/\(projectName)/\(deployment.id)"),
            sourceLabel: nil,
            trafficPercentage: nil
        )
    }
}

extension Deployment.State {
    /// Pages reports progress as the latest of its stages (queued, initialize, clone_repo, build, deploy).
    init(pages deployment: CloudflarePagesDeployment) {
        guard deployment.isSkipped != true else {
            self = .skipped
            return
        }
        guard let stage = deployment.latestStage else {
            self = .unknown
            return
        }
        switch stage.status {
        case _ where stage.name == "queued", "idle":
            self = .queued
        case "active":
            self = .building
        // An earlier stage's success means the next stage has not started yet.
        case "success":
            self = stage.name == "deploy" ? .ready : .building
        case "failure":
            self = .error
        case "canceled":
            self = .canceled
        case "skipped":
            self = .skipped
        default:
            self = .unknown
        }
    }
}

extension Deployment.Environment {
    init?(pagesEnvironment environment: String?) {
        guard let environment, !environment.isEmpty else { return nil }
        switch environment.lowercased() {
        case "production": self = .production
        case "preview": self = .preview
        default: self = .custom(environment)
        }
    }
}

extension Deployment {
    /// Rows for one Worker script, newest first. Deployments created by secret changes are dropped because they
    /// redeploy the same code. A build joins the oldest deployment that rolled out the version it produced, so one
    /// Git push is one row; rollbacks to a built version stay separate rows. Builds without a deployment become rows
    /// of their own.
    static func cloudflareWorkers(
        _ deployments: [CloudflareWorkerDeployment],
        builds: CloudflareWorkerBuilds = .none,
        accountID: String,
        scriptName: String
    ) -> [Deployment] {
        cloudflareWorkersRows(deployments, builds: builds, accountID: accountID, scriptName: scriptName).map(\.row)
    }

    /// `cloudflareWorkers` rows paired with the UUID of the build each row shows, which the fast tier re-queries.
    static func cloudflareWorkersRows(
        _ deployments: [CloudflareWorkerDeployment],
        builds: CloudflareWorkerBuilds,
        accountID: String,
        scriptName: String
    ) -> [(row: Deployment, buildUUID: String?)] {
        let dated = deployments
            .compactMap { deployment in cloudflareDate(from: deployment.createdOn).map { (deployment, $0) } }
            .sorted { $0.1 > $1.1 }
        let openURL = workersOpenURL(accountID: accountID, scriptName: scriptName)
        func previous(_ index: Int) -> CloudflareWorkerDeployment? {
            index + 1 < dated.count ? dated[index + 1].0 : nil
        }

        var buildByDeploymentID: [String: CloudflareWorkerBuild] = [:]
        var joinedBuildIDs: Set<String> = []
        for index in dated.indices.reversed() {
            let deployment = dated[index].0
            let triggeredBy = deployment.annotations?.triggeredBy
            guard
                triggeredBy != "secret",
                triggeredBy != "rollback",
                let version = rolloutVersion(of: deployment, previous: previous(index)),
                let build = builds.byVersionID[version.versionID],
                joinedBuildIDs.insert(build.buildUUID).inserted
            else { continue }
            buildByDeploymentID[deployment.id] = build
        }

        let deploymentRows = dated.indices.compactMap { index -> (row: Deployment, buildUUID: String?)? in
            let (deployment, createdAt) = dated[index]
            guard deployment.annotations?.triggeredBy != "secret" else { return nil }
            let trafficPercentage = rolloutVersion(of: deployment, previous: previous(index))
                .flatMap { $0.percentage < 100 ? Int($0.percentage.rounded()) : nil }
            if let build = buildByDeploymentID[deployment.id] {
                let row = Deployment(
                    workersBuild: build,
                    id: deployment.id,
                    createdAt: build.createdOn.flatMap(cloudflareDate(from:)) ?? createdAt,
                    environment: .production,
                    fallbackCommitMessage: deployment.annotations?.message,
                    scriptName: scriptName,
                    openURL: openURL,
                    trafficPercentage: trafficPercentage
                )
                return (row, build.buildUUID)
            }
            let row = Deployment(
                id: deployment.id,
                platform: .cloudflareWorkers,
                projectName: scriptName,
                state: .ready,
                createdAt: createdAt,
                buildStartedAt: nil,
                finishedAt: nil,
                branch: nil,
                environment: .production,
                commitMessage: deployment.annotations?.message,
                openURL: openURL,
                sourceLabel: workersSourceLabel(for: deployment),
                trafficPercentage: trafficPercentage
            )
            return (row, nil)
        }

        let buildRows = builds.recent.compactMap { build -> (row: Deployment, buildUUID: String?)? in
            guard
                !joinedBuildIDs.contains(build.buildUUID),
                let row = cloudflareWorkersBuildRow(build, accountID: accountID, scriptName: scriptName)
            else { return nil }
            return (row, build.buildUUID)
        }

        return (deploymentRows + buildRows).sorted { $0.row.createdAt > $1.row.createdAt }
    }

    /// The row of a build that joins no deployment, or nil when its creation date cannot be parsed.
    static func cloudflareWorkersBuildRow(
        _ build: CloudflareWorkerBuild,
        accountID: String,
        scriptName: String
    ) -> Deployment? {
        guard let createdAt = build.createdOn.flatMap(cloudflareDate(from:)) else { return nil }
        return Deployment(
            workersBuild: build,
            id: build.buildUUID,
            createdAt: createdAt,
            environment: Environment(workersBuildTrigger: build),
            fallbackCommitMessage: nil,
            scriptName: scriptName,
            openURL: workersOpenURL(accountID: accountID, scriptName: scriptName),
            trafficPercentage: nil
        )
    }

    private static func workersOpenURL(accountID: String, scriptName: String) -> URL? {
        URL(string: "https://dash.cloudflare.com/\(accountID)/workers/services/view/\(scriptName)/production")
    }

    /// This Workers row with the progress of a re-queried build; everything else stays as the full fetch built it.
    func patched(with build: CloudflareWorkerBuild) -> Deployment {
        Deployment(
            workersBuild: build,
            id: id,
            createdAt: createdAt,
            environment: environment ?? Environment(workersBuildTrigger: build),
            fallbackCommitMessage: commitMessage,
            scriptName: projectName,
            openURL: openURL,
            trafficPercentage: trafficPercentage
        )
    }

    private init(
        workersBuild build: CloudflareWorkerBuild,
        id: String,
        createdAt: Date,
        environment: Environment,
        fallbackCommitMessage: String?,
        scriptName: String,
        openURL: URL?,
        trafficPercentage: Int?
    ) {
        let state = State(workersBuild: build)
        let finishedAt: Date? = switch state {
        case .ready, .error, .canceled:
            build.stoppedOn.flatMap(Self.cloudflareDate(from:))
        case .queued, .building, .skipped, .unknown:
            nil
        }
        let metadata = build.buildTriggerMetadata
        let branch = metadata?.branch
        self.init(
            id: id,
            platform: .cloudflareWorkers,
            projectName: scriptName,
            state: state,
            createdAt: createdAt,
            buildStartedAt: build.runningOn.flatMap(Self.cloudflareDate(from:)),
            finishedAt: finishedAt,
            branch: branch?.isEmpty == false ? branch : nil,
            environment: environment,
            commitMessage: metadata?.commitMessage ?? fallbackCommitMessage,
            openURL: openURL,
            sourceLabel: nil,
            trafficPercentage: trafficPercentage
        )
    }
}

extension Deployment.State {
    /// Queued or Building: the states the fast tier keeps re-querying.
    var isInProgress: Bool {
        self == .queued || self == .building
    }
}

extension Deployment.State {
    init(workersBuild build: CloudflareWorkerBuild) {
        switch (build.status, build.buildOutcome) {
        case (_, "terminated"):
            self = .error
        case ("queued", _):
            self = .queued
        case ("initializing", _), ("running", _):
            self = .building
        case ("stopped", "success"):
            self = .ready
        case ("stopped", "fail"):
            self = .error
        case ("stopped", "cancelled"):
            self = .canceled
        case ("stopped", "skipped"):
            self = .skipped
        default:
            self = .unknown
        }
    }
}

extension Deployment.Environment {
    /// A build that did not produce a fetched deployment is classified by the command it ran: production triggers run
    /// `wrangler deploy`, preview triggers run `wrangler preview` or `wrangler versions upload`, which never deploy.
    init(workersBuildTrigger build: CloudflareWorkerBuild) {
        let command = build.buildTriggerMetadata?.deployCommand ?? build.trigger?.deployCommand
        self = command?.contains("wrangler deploy") == true ? .production : .preview
    }
}

extension Deployment {
    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondDateFormatter = ISO8601DateFormatter()

    private static func cloudflareDate(from string: String) -> Date? {
        fractionalDateFormatter.date(from: string) ?? wholeSecondDateFormatter.date(from: string)
    }

    private static func workersSourceLabel(for deployment: CloudflareWorkerDeployment) -> String? {
        if let triggeredBy = deployment.annotations?.triggeredBy, triggeredBy == "rollback" || triggeredBy == "promotion" {
            return triggeredBy
        }
        switch deployment.source {
        case nil, "":
            return nil
        case "wrangler":
            return "wrangler"
        case "dash", "dash_template":
            return "dashboard"
        case "api":
            return "API"
        case let source?:
            return source
        }
    }

    /// The version being rolled out; its share is the row's traffic percentage when below 100. The API does not order
    /// the versions of a split, so the rolled-out version is the one whose share grew most since the previous
    /// deployment; ties, and deployments without a previous one, use the smallest share.
    private static func rolloutVersion(
        of deployment: CloudflareWorkerDeployment,
        previous: CloudflareWorkerDeployment?
    ) -> CloudflareWorkerDeployment.Version? {
        let previousShares = previous.map { previous in
            Dictionary(previous.versions.map { ($0.versionID, $0.percentage) }, uniquingKeysWith: { first, _ in first })
        }
        func gain(_ version: CloudflareWorkerDeployment.Version) -> Double {
            guard let previousShares else { return 0 }
            return version.percentage - (previousShares[version.versionID] ?? 0)
        }

        return deployment.versions.max { lhs, rhs in
            let lhsGain = gain(lhs)
            let rhsGain = gain(rhs)
            return lhsGain == rhsGain ? lhs.percentage > rhs.percentage : lhsGain < rhsGain
        }
    }
}
