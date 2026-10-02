import XCTest
@testable import open_deployment_menu_bar

/// Build objects follow the 200 examples of the Workers Builds API reference:
/// - List builds: https://developers.cloudflare.com/api/resources/workers_builds/subresources/builds/methods/list/
/// - Get builds by Worker version (`result.builds` keyed by version ID):
///   https://developers.cloudflare.com/api/resources/workers_builds/methods/get_builds_by_version/
/// - Get latest builds by script IDs (`result.builds` keyed by script tag):
///   https://developers.cloudflare.com/api/resources/workers_builds/methods/get_latest_builds/
/// Deployment objects follow https://developers.cloudflare.com/api/resources/workers/subresources/scripts/subresources/deployments/methods/list/
final class CloudflareWorkersBuildsTests: XCTestCase {
    func testBuildJoinsTheDeploymentOfItsVersionAsOneRow() throws {
        let pushed = build(uuid: "build_main", branch: "main", commitMessage: "Add new feature")
        let rows = try convert(
            deployments: [deployment(id: "dep_main", createdOn: "2026-10-02T05:01:30Z", versionID: "v2")],
            recent: [pushed],
            byVersionID: ["v2": pushed]
        )

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "dep_main")
        XCTAssertEqual(row.state, .ready)
        XCTAssertEqual(row.environment, .production)
        XCTAssertEqual(row.branch, "main")
        XCTAssertEqual(row.commitMessage, "Add new feature")
        XCTAssertNil(row.sourceLabel)
        XCTAssertEqual(row.createdAt, date("2026-10-02T05:00:00Z"))
        XCTAssertEqual(row.buildStartedAt, date("2026-10-02T05:00:10Z"))
        XCTAssertEqual(row.finishedAt, date("2026-10-02T05:01:40Z"))
    }

    func testDeploymentsWithoutBuildStayReadyWithSourceAndRollbackOfBuiltVersionStaysSeparate() throws {
        let pushed = build(uuid: "build_main", branch: "main", commitMessage: "Add new feature")
        let rows = try convert(
            deployments: [
                deployment(id: "dep_rollback", createdOn: "2026-10-02T07:00:00Z", versionID: "v2", triggeredBy: "rollback"),
                deployment(id: "dep_wrangler", createdOn: "2026-10-02T06:00:00Z", versionID: "v3", message: "Local fix"),
                deployment(id: "dep_main", createdOn: "2026-10-02T05:01:30Z", versionID: "v2"),
            ],
            recent: [pushed],
            byVersionID: ["v2": pushed]
        )

        XCTAssertEqual(rows.map(\.id), ["dep_rollback", "dep_wrangler", "dep_main"])
        XCTAssertEqual(rows[0].sourceLabel, "rollback")
        XCTAssertNil(rows[0].branch)
        XCTAssertEqual(rows[1].state, .ready)
        XCTAssertEqual(rows[1].sourceLabel, "wrangler")
        XCTAssertEqual(rows[1].commitMessage, "Local fix")
        XCTAssertEqual(rows[2].branch, "main")
    }

    func testBuildWithoutDeploymentIsPreviewUnlessItsCommandDeploys() throws {
        let preview = build(
            uuid: "build_preview",
            createdOn: "2026-10-02T08:00:00Z",
            branch: "feature/login",
            deployCommand: "npx wrangler versions upload"
        )
        let workerPreview = build(
            uuid: "build_worker_preview",
            createdOn: "2026-10-02T08:30:00Z",
            branch: "fix/typo",
            deployCommand: "npx wrangler preview"
        )
        let runningProduction = build(
            uuid: "build_running",
            createdOn: "2026-10-02T09:00:00Z",
            status: "running",
            outcome: nil,
            branch: "main",
            deployCommand: "npx wrangler deploy"
        )
        let rows = try convert(deployments: [], recent: [preview, workerPreview, runningProduction], byVersionID: [:])

        XCTAssertEqual(rows.map(\.id), ["build_running", "build_worker_preview", "build_preview"])
        XCTAssertEqual(rows.map(\.environment), [.production, .preview, .preview])
        XCTAssertEqual(rows[0].state, .building)
        XCTAssertNil(rows[0].finishedAt)
        XCTAssertEqual(rows[2].state, .ready)
        XCTAssertEqual(rows[2].branch, "feature/login")
        XCTAssertEqual(
            rows[2].openURL,
            URL(string: "https://dash.cloudflare.com/acct_1/workers/services/view/api/production")
        )
    }

    func testStateTable() throws {
        let cases: [(status: String, outcome: String?, state: Deployment.State)] = [
            ("queued", nil, .queued),
            ("initializing", nil, .building),
            ("running", nil, .building),
            ("stopped", "success", .ready),
            ("stopped", "fail", .error),
            ("stopped", "terminated", .error),
            ("stopped", "cancelled", .canceled),
            ("stopped", "skipped", .skipped),
        ]
        for (status, outcome, expected) in cases {
            let rows = try convert(
                deployments: [],
                recent: [build(uuid: "b", status: status, outcome: outcome)],
                byVersionID: [:]
            )
            XCTAssertEqual(rows.first?.state, expected, "\(status) / \(outcome ?? "nil")")
        }
    }

    // MARK: - Service

    override func tearDown() {
        StubURLProtocol.responses = [:]
        super.tearDown()
    }

    func testBuildsAPIRejectingTheTokenKeepsDeploymentsAndReportsTheMissingPermission() async throws {
        StubURLProtocol.responses = baseResponses
        // 401 example of https://developers.cloudflare.com/api/resources/workers_builds/methods/get_latest_builds/,
        // with the code and message the Builds API returns for account-owned tokens.
        StubURLProtocol.responses["/client/v4/accounts/acct_1/builds/builds/latest"] = (
            401,
            ["errors": [["code": 12006, "message": "Invalid token"]], "messages": [], "result": NSNull(), "success": false]
        )

        let snapshot = try await service().fetchDeployments(token: "token", preferences: .default)

        XCTAssertEqual(snapshot.deployments.map(\.id), ["dep_main"])
        XCTAssertEqual(snapshot.deployments.first?.sourceLabel, "wrangler")
        XCTAssertNil(snapshot.deployments.first?.branch)
        XCTAssertEqual(snapshot.issue?.message, "Workers build status needs a user API token with Workers CI Read")
    }

    func testServiceJoinsBuildsLookedUpByScriptTagAndVersion() async throws {
        let pushed = build(uuid: "build_main", branch: "main", commitMessage: "Add new feature")
        let preview = build(uuid: "build_preview", createdOn: "2026-10-02T08:00:00Z", branch: "feature/login",
                            deployCommand: "npx wrangler versions upload")
        StubURLProtocol.responses = baseResponses
        StubURLProtocol.responses["/client/v4/accounts/acct_1/builds/builds/latest"] = (
            200, envelope(["builds": ["tag_api": preview]])
        )
        StubURLProtocol.responses["/client/v4/accounts/acct_1/builds/workers/tag_api/builds"] = (
            200, envelope([preview, pushed])
        )
        StubURLProtocol.responses["/client/v4/accounts/acct_1/builds/builds"] = (
            200, envelope(["builds": ["v2": pushed]])
        )

        let snapshot = try await service().fetchDeployments(token: "token", preferences: .default)

        XCTAssertNil(snapshot.issue)
        XCTAssertEqual(snapshot.deployments.map(\.id), ["build_preview", "dep_main"])
        XCTAssertEqual(snapshot.deployments.map(\.environment), [.preview, .production])
        XCTAssertEqual(snapshot.deployments.last?.branch, "main")
        XCTAssertEqual(StubURLProtocol.queries["/client/v4/accounts/acct_1/builds/builds/latest"], "external_script_ids=tag_api")
        XCTAssertEqual(StubURLProtocol.queries["/client/v4/accounts/acct_1/builds/builds"], "version_ids=v2")
    }

    // MARK: - Fixtures

    private var baseResponses: [String: (Int, Any)] {
        [
            "/client/v4/accounts": (200, envelope([["id": "acct_1", "name": "Account"]])),
            "/client/v4/accounts/acct_1/workers/scripts": (200, envelope([["id": "api", "tag": "tag_api"]])),
            "/client/v4/accounts/acct_1/workers/scripts/api/deployments": (
                200,
                envelope(["deployments": [deployment(id: "dep_main", createdOn: "2026-10-02T05:01:30Z", versionID: "v2")]])
            ),
            "/client/v4/accounts/acct_1/pages/projects": (200, envelope([])),
        ]
    }

    private func service() -> CloudflareService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return CloudflareService(session: URLSession(configuration: configuration))
    }

    private func envelope(_ result: Any) -> [String: Any] {
        ["errors": [], "messages": [], "result": result, "success": true]
    }

    private func convert(
        deployments: [[String: Any]],
        recent: [[String: Any]],
        byVersionID: [String: [String: Any]]
    ) throws -> [Deployment] {
        let deploymentsData = try JSONSerialization.data(withJSONObject: ["deployments": deployments])
        let recentData = try JSONSerialization.data(withJSONObject: recent)
        let versionsData = try JSONSerialization.data(withJSONObject: ["builds": byVersionID])
        let builds = CloudflareWorkerBuilds(
            recent: try JSONDecoder().decode([CloudflareWorkerBuild].self, from: recentData),
            byVersionID: try JSONDecoder().decode(CloudflareWorkerBuildMap.self, from: versionsData).builds ?? [:]
        )
        return Deployment.cloudflareWorkers(
            try JSONDecoder().decode(CloudflareWorkerDeploymentsResult.self, from: deploymentsData).deployments,
            builds: builds,
            accountID: "acct_1",
            scriptName: "api"
        )
    }

    private func deployment(
        id: String,
        createdOn: String,
        versionID: String,
        triggeredBy: String = "upload",
        message: String? = nil
    ) -> [String: Any] {
        var annotations: [String: Any] = ["workers/triggered_by": triggeredBy]
        annotations["workers/message"] = message
        return [
            "id": id,
            "created_on": createdOn,
            "source": "wrangler",
            "strategy": "percentage",
            "versions": [["version_id": versionID, "percentage": 100]],
            "annotations": annotations,
        ]
    }

    private func build(
        uuid: String,
        createdOn: String = "2026-10-02T05:00:00Z",
        status: String = "stopped",
        outcome: String? = "success",
        branch: String = "main",
        commitMessage: String = "Add new feature",
        deployCommand: String = "npx wrangler deploy"
    ) -> [String: Any] {
        var object: [String: Any] = [
            "build_uuid": uuid,
            "status": status,
            "created_on": createdOn,
            "initializing_on": "2026-10-02T05:00:05Z",
            "running_on": "2026-10-02T05:00:10Z",
            "modified_on": "2026-10-02T05:01:40Z",
            "build_trigger_metadata": [
                "author": "developer@cloudflare.com",
                "branch": branch,
                "build_command": "npm run build",
                "build_trigger_source": "push",
                "commit_hash": "abc123def456",
                "commit_message": commitMessage,
                "deploy_command": deployCommand,
                "provider_type": "github",
                "repo_name": "workers-sdk",
                "root_directory": "/",
            ],
            "trigger": [
                "branch_includes": ["main"],
                "deploy_command": deployCommand,
                "external_script_id": "tag_api",
                "trigger_name": "Production Deploy",
            ],
        ]
        object["build_outcome"] = outcome
        if status == "stopped" {
            object["stopped_on"] = "2026-10-02T05:01:40Z"
        }
        return object
    }

    private func date(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}

/// Serves canned JSON per URL path and records each path's query. Requests arrive concurrently, hence the lock.
private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedResponses: [String: (Int, Any)] = [:]
    private static var storedQueries: [String: String] = [:]

    static var responses: [String: (Int, Any)] {
        get { lock.withLock { storedResponses } }
        set { lock.withLock { storedResponses = newValue; storedQueries = [:] } }
    }

    static var queries: [String: String] {
        lock.withLock { storedQueries }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let stub = Self.lock.withLock {
            Self.storedQueries[url.path] = url.query
            return Self.storedResponses[url.path]
        }
        let (status, body) = stub ?? (404, ["errors": [["code": 7003, "message": "Not found"]]])
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
