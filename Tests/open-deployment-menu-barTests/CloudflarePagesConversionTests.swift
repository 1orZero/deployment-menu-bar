import XCTest
@testable import open_deployment_menu_bar

final class CloudflarePagesConversionTests: XCTestCase {
    func testMapsLatestStageToState() throws {
        let expected: [(stage: String, status: String, state: Deployment.State)] = [
            ("queued", "active", .queued),
            ("build", "idle", .queued),
            ("initialize", "active", .building),
            ("clone_repo", "active", .building),
            ("build", "active", .building),
            ("deploy", "active", .building),
            ("deploy", "success", .ready),
            ("build", "success", .building),
            ("build", "failure", .error),
            ("deploy", "failure", .error),
            ("build", "canceled", .canceled),
            ("build", "skipped", .skipped),
            ("build", "paused", .unknown),
        ]
        for (name, status, state) in expected {
            let row = try convert(deployment(latestStage: stage(name, status)))
            XCTAssertEqual(row.state, state, "\(name) \(status)")
        }
    }

    func testIsSkippedWinsOverLatestStage() throws {
        let row = try convert(deployment(latestStage: stage("deploy", "success"), isSkipped: true))

        XCTAssertEqual(row.state, .skipped)
    }

    func testMissingLatestStageIsUnknown() throws {
        let row = try convert(deployment(latestStage: nil))

        XCTAssertEqual(row.state, .unknown)
    }

    func testConvertsProductionDeploymentFromTriggerMetadata() throws {
        let row = try convert(deployment(
            id: "dep_1",
            environment: "production",
            branch: "main",
            commitMessage: "Add landing page"
        ))

        XCTAssertEqual(row.id, "dep_1")
        XCTAssertEqual(row.platform, .cloudflarePages)
        XCTAssertEqual(row.projectName, "qa-site")
        XCTAssertEqual(row.environment, .production)
        XCTAssertEqual(row.branch, "main")
        XCTAssertEqual(row.commitMessage, "Add landing page")
        XCTAssertNil(row.sourceLabel)
        XCTAssertNil(row.trafficPercentage)
        XCTAssertEqual(row.createdAt.timeIntervalSince1970, 1_790_913_600.5, accuracy: 0.001)
        XCTAssertEqual(row.openURL, URL(string: "https://dash.cloudflare.com/acct_1/pages/view/qa-site/dep_1"))
    }

    func testPreviewAndMissingMetadata() throws {
        let preview = try convert(deployment(environment: "preview", branch: "feature/login"))
        XCTAssertEqual(preview.environment, .preview)
        XCTAssertEqual(preview.branch, "feature/login")

        let bare = try convert(deployment(environment: nil, branch: "", commitMessage: nil))
        XCTAssertNil(bare.environment)
        XCTAssertNil(bare.branch)
        XCTAssertNil(bare.commitMessage)
    }

    func testReadyDurationRunsFromBuildStartToDeployEnd() throws {
        let row = try convert(deployment(
            latestStage: stage("deploy", "success", ended: "2026-10-02T04:01:30Z"),
            stages: [
                stage("queued", "success", started: "2026-10-02T04:00:00Z", ended: "2026-10-02T04:00:05Z"),
                stage("build", "success", started: "2026-10-02T04:00:10Z", ended: "2026-10-02T04:01:20Z"),
                stage("deploy", "success", started: "2026-10-02T04:01:20Z", ended: "2026-10-02T04:01:30Z"),
            ]
        ))

        XCTAssertEqual(row.buildStartedAt, date("2026-10-02T04:00:10Z"))
        XCTAssertEqual(row.finishedAt, date("2026-10-02T04:01:30Z"))
    }

    func testFailedDeploymentFinishesWhenFailingStageEnds() throws {
        let row = try convert(deployment(
            latestStage: stage("build", "failure", started: "2026-10-02T04:00:10Z", ended: "2026-10-02T04:00:40Z"),
            stages: [
                stage("build", "failure", started: "2026-10-02T04:00:10Z", ended: "2026-10-02T04:00:40Z"),
                stage("deploy", "idle"),
            ]
        ))

        XCTAssertEqual(row.state, .error)
        XCTAssertEqual(row.buildStartedAt, date("2026-10-02T04:00:10Z"))
        XCTAssertEqual(row.finishedAt, date("2026-10-02T04:00:40Z"))
    }

    func testInProgressDeploymentHasNoFinishAndFallsBackToCreationBeforeBuild() throws {
        let row = try convert(deployment(
            latestStage: stage("initialize", "active", started: "2026-10-02T04:00:02Z"),
            stages: [
                stage("initialize", "active", started: "2026-10-02T04:00:02Z"),
                stage("build", "idle"),
                stage("deploy", "idle"),
            ]
        ))

        XCTAssertEqual(row.state, .building)
        XCTAssertNil(row.buildStartedAt)
        XCTAssertNil(row.finishedAt)
        XCTAssertEqual(row.buildStartDate, row.createdAt)
    }

    func testUnparseableCreationDateDropsRow() throws {
        let data = try JSONSerialization.data(withJSONObject: deployment(createdOn: "yesterday"))
        let decoded = try JSONDecoder().decode(CloudflarePagesDeployment.self, from: data)

        XCTAssertNil(Deployment(pages: decoded, accountID: "acct_1", projectName: "qa-site"))
    }

    private func convert(_ object: [String: Any]) throws -> Deployment {
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CloudflarePagesDeployment.self, from: data)
        return try XCTUnwrap(Deployment(pages: decoded, accountID: "acct_1", projectName: "qa-site"))
    }

    private func date(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private func stage(_ name: String, _ status: String, started: String? = nil, ended: String? = nil) -> [String: Any] {
        ["name": name, "status": status, "started_on": nullable(started), "ended_on": nullable(ended)]
    }

    private func nullable(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    /// Shaped like the Pages deployments API response, including its explicit nulls.
    private func deployment(
        id: String = "dep",
        createdOn: String = "2026-10-02T04:00:00.500000Z",
        environment: String? = "production",
        latestStage: [String: Any]? = ["name": "deploy", "status": "success", "started_on": NSNull(), "ended_on": NSNull()],
        stages: [[String: Any]] = [],
        isSkipped: Bool = false,
        branch: String? = "main",
        commitMessage: String? = "Commit"
    ) -> [String: Any] {
        [
            "id": id,
            "short_id": String(id.prefix(8)),
            "project_name": "qa-site",
            "created_on": createdOn,
            "environment": nullable(environment),
            "is_skipped": isSkipped,
            "latest_stage": nullable(latestStage),
            "stages": stages,
            "deployment_trigger": [
                "type": "ad_hoc",
                "metadata": [
                    "branch": nullable(branch),
                    "commit_hash": "abc123",
                    "commit_message": nullable(commitMessage),
                    "commit_dirty": false,
                ],
            ],
        ]
    }
}
