import XCTest
@testable import open_deployment_menu_bar

final class CloudflarePollingTests: XCTestCase {
    /// 2026-10-02T04:00:00Z, a Friday.
    private let now = Date(timeIntervalSince1970: 1_790_913_600)

    override func tearDown() {
        RateLimitStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Retry-After

    func testRetryAfterAcceptsSecondsAndHTTPDateAndDefaultsToOneMinute() {
        let cases: [(header: String?, delay: TimeInterval)] = [
            ("42", 42),
            (" 0 ", 0),
            ("Fri, 02 Oct 2026 04:01:30 GMT", 90),
            ("Fri, 02 Oct 2026 03:59:00 GMT", 0),
            (nil, 60),
            ("soon", 60),
        ]
        for (header, delay) in cases {
            XCTAssertEqual(
                CloudflareService.rateLimitEnd(retryAfter: header, now: now),
                now.addingTimeInterval(delay),
                header ?? "nil"
            )
        }
    }

    // MARK: - Scheduling

    func testFastTierRunsOnlyWhileAShownRowIsInProgress() {
        var polling = CloudflarePolling()
        XCTAssertEqual(polling.plan(at: now, preferences: .default), plan(full: 30, fast: nil))

        polling.applyFullFetch(rows: [pagesRow("dep_building", state: .building)], pendingItems: [pagesItem("dep_building")], issue: nil)
        XCTAssertEqual(polling.plan(at: now, preferences: .default), plan(full: 30, fast: 5))

        // A filter hid the in-progress row, so it is not re-queried.
        polling.applyFullFetch(rows: [pagesRow("dep_ready", state: .ready)], pendingItems: [pagesItem("dep_building")], issue: nil)
        XCTAssertEqual(polling.plan(at: now, preferences: .default), plan(full: 30, fast: nil))
    }

    func testIntervalsBelowTheMinimumsAreRaised() {
        var preferences = CloudflarePreferences.default
        preferences.refreshInterval = 3
        preferences.fastRefreshInterval = 1
        var polling = CloudflarePolling()
        polling.applyFullFetch(rows: [pagesRow("dep_building", state: .building)], pendingItems: [pagesItem("dep_building")], issue: nil)

        XCTAssertEqual(polling.plan(at: now, preferences: preferences), plan(full: 10, fast: 2))
    }

    func testPauseStopsTheFastTierAndDefersTheFullFetchToItsEnd() {
        var polling = CloudflarePolling()
        polling.applyFullFetch(rows: [pagesRow("dep_building", state: .building)], pendingItems: [pagesItem("dep_building")], issue: nil)
        let end = now.addingTimeInterval(42)
        polling.applyFailure(CloudflareAPIError.rateLimited(until: end))

        XCTAssertTrue(polling.isPaused(at: now))
        XCTAssertEqual(polling.plan(at: now, preferences: .default), CloudflarePollingPlan(nextFullFetch: end, fastInterval: nil))
        XCTAssertFalse(polling.isPaused(at: end))
        XCTAssertEqual(
            polling.plan(at: end, preferences: .default),
            CloudflarePollingPlan(nextFullFetch: end.addingTimeInterval(30), fastInterval: 5)
        )
    }

    // MARK: - Patching

    func testFinishedPagesDeploymentReplacesItsRowAndAsksForAFullFetch() {
        var polling = CloudflarePolling()
        polling.applyFullFetch(
            rows: [pagesRow("dep_building", state: .building), pagesRow("dep_old", state: .ready)],
            pendingItems: [pagesItem("dep_building")],
            issue: nil
        )

        XCTAssertFalse(polling.applyUpdates([.pagesDeployment(pagesRow("dep_building", state: .building))]))
        XCTAssertEqual(polling.pendingItems.map(\.rowID), ["dep_building"])

        XCTAssertFalse(polling.applyUpdates([.pagesDeployment(pagesRow("dep_unknown", state: .ready))]))
        XCTAssertEqual(polling.deployments.map(\.id), ["dep_building", "dep_old"])

        XCTAssertTrue(polling.applyUpdates([.pagesDeployment(pagesRow("dep_building", state: .ready))]))
        XCTAssertEqual(polling.deployments.map(\.state), [.ready, .ready])
        XCTAssertEqual(polling.deployments.map(\.id), ["dep_building", "dep_old"])
        XCTAssertTrue(polling.pendingItems.isEmpty)
        XCTAssertNil(polling.plan(at: now, preferences: .default).fastInterval)
    }

    func testFinishedWorkersBuildPatchesStateAndTimesButKeepsTheRow() throws {
        let rows = Deployment.cloudflareWorkersRows(
            [],
            builds: CloudflareWorkerBuilds(recent: [try workerBuild(status: "running", outcome: nil)], byVersionID: [:]),
            accountID: "acct_1",
            scriptName: "api"
        )
        let running = try XCTUnwrap(rows.first)
        XCTAssertEqual(running.buildUUID, "build_1")
        var polling = CloudflarePolling()
        polling.applyFullFetch(
            rows: [running.row],
            pendingItems: [CloudflarePendingItem(rowID: running.row.id, accountID: "acct_1", source: .workersBuild(buildUUID: "build_1"))],
            issue: nil
        )

        let finished = polling.applyUpdates([
            .workersBuild(rowID: running.row.id, try workerBuild(status: "stopped", outcome: "success")),
        ])

        XCTAssertTrue(finished)
        let row = try XCTUnwrap(polling.deployments.first)
        XCTAssertEqual(row.id, running.row.id)
        XCTAssertEqual(row.state, .ready)
        XCTAssertEqual(row.finishedAt, ISO8601DateFormatter().date(from: "2026-10-02T05:01:40Z"))
        XCTAssertEqual(row.branch, "main")
        XCTAssertEqual(row.environment, .production)
        XCTAssertEqual(row.createdAt, running.row.createdAt)
    }

    // MARK: - Service

    func testFullFetchReportsInProgressRowsAndTheFastTierRequestsOnlyThem() async throws {
        RateLimitStubURLProtocol.responses = pagesResponses(latestStage: ["name": "build", "status": "active"])

        let snapshot = try await service().fetchDeployments(token: "token", preferences: .default)

        XCTAssertEqual(snapshot.pendingItems, [pagesItem("dep_building")])

        RateLimitStubURLProtocol.reset()
        RateLimitStubURLProtocol.responses[singleDeploymentPath] = (200, [:], envelope(pagesDeployment(
            id: "dep_building",
            latestStage: ["name": "deploy", "status": "success", "ended_on": "2026-10-02T04:00:40Z"]
        )))
        RateLimitStubURLProtocol.responses["/client/v4/accounts/acct_1/builds/builds/build_1"] = (
            200, [:], envelope(try JSONSerialization.jsonObject(with: workerBuildData(status: "running", outcome: nil)))
        )

        let updates = try await service().fetchPendingUpdates(token: "token", items: [
            pagesItem("dep_building"),
            CloudflarePendingItem(rowID: "dep_worker", accountID: "acct_1", source: .workersBuild(buildUUID: "build_1")),
        ])

        XCTAssertEqual(
            Set(RateLimitStubURLProtocol.requestedPaths),
            [singleDeploymentPath, "/client/v4/accounts/acct_1/builds/builds/build_1"]
        )
        XCTAssertEqual(RateLimitStubURLProtocol.requestedPaths.count, 2)
        var polling = CloudflarePolling()
        polling.applyFullFetch(rows: snapshot.deployments, pendingItems: snapshot.pendingItems, issue: nil)
        XCTAssertTrue(polling.applyUpdates(updates))
        XCTAssertEqual(polling.deployments.first?.state, .ready)
    }

    /// A 429 on any request, including the Builds lookups whose other failures only degrade the rows, pauses polling
    /// with the last rows and a countdown, and the next full fetch after the pause clears it.
    func testRateLimitPausesWithLastRowsAndCountdownThenResumes() async throws {
        let rateLimitedPaths = [
            "/client/v4/accounts/acct_1/pages/projects/qa-site/deployments",
            "/client/v4/accounts/acct_1/builds/builds/latest",
        ]
        for rateLimitedPath in rateLimitedPaths {
            RateLimitStubURLProtocol.responses = pagesResponses(latestStage: ["name": "deploy", "status": "success"])
            var polling = CloudflarePolling()
            let first = try await service().fetchDeployments(token: "token", preferences: .default)
            polling.applyFullFetch(rows: first.deployments, pendingItems: first.pendingItems, issue: first.issue)

            RateLimitStubURLProtocol.responses[rateLimitedPath] = (
                429,
                ["Retry-After": "42"],
                ["success": false, "errors": [["code": 10000, "message": "Rate limited"]]]
            )
            let requestedAt = Date()
            var thrown: Error?
            do {
                _ = try await service().fetchDeployments(token: "token", preferences: .default)
            } catch {
                thrown = error
            }
            let end = try XCTUnwrap(thrown.flatMap(CloudflareAPIError.rateLimitEnd(of:)), rateLimitedPath)
            XCTAssertEqual(end.timeIntervalSince(requestedAt), 42, accuracy: 2, rateLimitedPath)
            polling.applyFailure(try XCTUnwrap(thrown))

            let paused = polling.status(at: end.addingTimeInterval(-42))
            XCTAssertEqual(paused.deployments.map(\.id), ["dep_building"])
            XCTAssertEqual(paused.issue?.message, "Rate limited by Cloudflare — retrying in 42s")
            XCTAssertEqual(polling.status(at: end.addingTimeInterval(-0.4)).issue?.message, "Rate limited by Cloudflare — retrying in 1s")
            XCTAssertEqual(polling.status(at: end).issue?.message, "Rate limited by Cloudflare — retrying now")
            XCTAssertEqual(
                StatusButtonState(platforms: [paused]),
                .deployment(try XCTUnwrap(paused.deployments.first), warning: true)
            )
            XCTAssertEqual(polling.plan(at: end.addingTimeInterval(-42), preferences: .default).nextFullFetch, end)

            RateLimitStubURLProtocol.responses = pagesResponses(latestStage: ["name": "deploy", "status": "success"])
            let resumed = try await service().fetchDeployments(token: "token", preferences: .default)
            polling.applyFullFetch(rows: resumed.deployments, pendingItems: resumed.pendingItems, issue: resumed.issue)

            XCTAssertNil(polling.pausedUntil)
            XCTAssertNil(polling.status(at: end).issue)
        }
    }

    func testRateLimitedFastTierThrowsTheResumeDate() async throws {
        RateLimitStubURLProtocol.responses[singleDeploymentPath] = (429, ["Retry-After": "300"], [:])

        do {
            _ = try await service().fetchPendingUpdates(token: "token", items: [pagesItem("dep_building")])
            XCTFail("Expected a 429")
        } catch {
            let end = try XCTUnwrap(CloudflareAPIError.rateLimitEnd(of: error))
            var polling = CloudflarePolling()
            polling.applyFailure(error)
            XCTAssertEqual(
                polling.status(at: end.addingTimeInterval(-300)).issue?.message,
                "Rate limited by Cloudflare — retrying in 5m 0s"
            )
        }
    }

    // MARK: - Fixtures

    private let singleDeploymentPath = "/client/v4/accounts/acct_1/pages/projects/qa-site/deployments/dep_building"

    private func plan(full: TimeInterval, fast: TimeInterval?) -> CloudflarePollingPlan {
        CloudflarePollingPlan(nextFullFetch: now.addingTimeInterval(full), fastInterval: fast)
    }

    private func pagesItem(_ id: String) -> CloudflarePendingItem {
        CloudflarePendingItem(rowID: id, accountID: "acct_1", source: .pagesDeployment(projectName: "qa-site"))
    }

    private func pagesRow(_ id: String, state: Deployment.State) -> Deployment {
        Deployment(
            id: id,
            platform: .cloudflarePages,
            projectName: "qa-site",
            state: state,
            createdAt: now,
            buildStartedAt: nil,
            finishedAt: nil,
            branch: "main",
            environment: .production,
            commitMessage: nil,
            openURL: nil,
            sourceLabel: nil,
            trafficPercentage: nil
        )
    }

    private func pagesResponses(latestStage: [String: Any]) -> [String: (Int, [String: String], Any)] {
        [
            "/client/v4/accounts": (200, [:], envelope([["id": "acct_1", "name": "Account"]])),
            "/client/v4/accounts/acct_1/workers/scripts": (200, [:], envelope([["id": "api", "tag": "tag_api"]])),
            "/client/v4/accounts/acct_1/workers/scripts/api/deployments": (200, [:], envelope(["deployments": []])),
            "/client/v4/accounts/acct_1/builds/builds/latest": (200, [:], envelope(["builds": [:]])),
            "/client/v4/accounts/acct_1/pages/projects": (200, [:], envelope([["name": "qa-site"]])),
            "/client/v4/accounts/acct_1/pages/projects/qa-site/deployments": (
                200, [:], envelope([pagesDeployment(id: "dep_building", latestStage: latestStage)])
            ),
        ]
    }

    private func pagesDeployment(id: String, latestStage: [String: Any]) -> [String: Any] {
        [
            "id": id,
            "created_on": "2026-10-02T04:00:00Z",
            "environment": "production",
            "is_skipped": false,
            "latest_stage": latestStage,
            "stages": [],
            "deployment_trigger": ["type": "ad_hoc", "metadata": ["branch": "main", "commit_message": "Commit"]],
        ]
    }

    private func workerBuildData(status: String, outcome: String?) throws -> Data {
        var object: [String: Any] = [
            "build_uuid": "build_1",
            "status": status,
            "created_on": "2026-10-02T05:00:00Z",
            "running_on": "2026-10-02T05:00:10Z",
            "build_trigger_metadata": ["branch": "main", "commit_message": "Add feature", "deploy_command": "npx wrangler deploy"],
        ]
        object["build_outcome"] = outcome
        if status == "stopped" {
            object["stopped_on"] = "2026-10-02T05:01:40Z"
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func workerBuild(status: String, outcome: String?) throws -> CloudflareWorkerBuild {
        try JSONDecoder().decode(CloudflareWorkerBuild.self, from: workerBuildData(status: status, outcome: outcome))
    }

    private func envelope(_ result: Any) -> [String: Any] {
        ["errors": [], "messages": [], "result": result, "success": true]
    }

    private func service() -> CloudflareService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitStubURLProtocol.self]
        return CloudflareService(session: URLSession(configuration: configuration))
    }
}

/// Serves canned status, headers and JSON per URL path and records the requested paths. Requests arrive
/// concurrently, hence the lock.
private final class RateLimitStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedResponses: [String: (Int, [String: String], Any)] = [:]
    private static var storedPaths: [String] = []

    static var responses: [String: (Int, [String: String], Any)] {
        get { lock.withLock { storedResponses } }
        set { lock.withLock { storedResponses = newValue } }
    }

    static var requestedPaths: [String] {
        lock.withLock { storedPaths }
    }

    static func reset() {
        lock.withLock {
            storedResponses = [:]
            storedPaths = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let stub = Self.lock.withLock {
            Self.storedPaths.append(url.path)
            return Self.storedResponses[url.path]
        }
        let (status, headers, body) = stub ?? (404, [:], ["errors": [["code": 7003, "message": "Not found"]]])
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
