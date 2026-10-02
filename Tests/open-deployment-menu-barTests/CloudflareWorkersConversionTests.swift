import XCTest
@testable import open_deployment_menu_bar

final class CloudflareWorkersConversionTests: XCTestCase {
    func testConvertsWorkersDeploymentToReadyProductionRow() throws {
        let rows = try convert([
            deployment(id: "dep_1", createdOn: "2026-10-02T05:34:18.000433Z", message: "Fix header"),
        ])

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "dep_1")
        XCTAssertEqual(row.platform, .cloudflareWorkers)
        XCTAssertEqual(row.projectName, "api")
        XCTAssertEqual(row.state, .ready)
        XCTAssertEqual(row.environment, .production)
        XCTAssertNil(row.branch)
        XCTAssertNil(row.buildStartedAt)
        XCTAssertNil(row.finishedAt)
        XCTAssertEqual(row.commitMessage, "Fix header")
        XCTAssertEqual(row.sourceLabel, "wrangler")
        XCTAssertNil(row.trafficPercentage)
        XCTAssertEqual(
            row.openURL,
            URL(string: "https://dash.cloudflare.com/acct_1/workers/services/view/api/production")
        )
    }

    func testParsesCreatedOnWithAnyFractionPrecisionAndSortsNewestFirst() throws {
        let rows = try convert([
            deployment(id: "whole", createdOn: "2026-10-02T04:00:00Z"),
            deployment(id: "micro", createdOn: "2026-10-02T05:34:18.000433Z"),
            deployment(id: "five", createdOn: "2026-10-02T04:20:11.40567Z"),
        ])

        XCTAssertEqual(rows.map(\.id), ["micro", "five", "whole"])
        let expected: [TimeInterval] = [1_790_919_258.000433, 1_790_914_811.40567, 1_790_913_600]
        for (row, seconds) in zip(rows, expected) {
            XCTAssertEqual(row.createdAt.timeIntervalSince1970, seconds, accuracy: 0.001)
        }
    }

    func testDropsDeploymentsWithUnparseableDates() throws {
        let rows = try convert([
            deployment(id: "bad", createdOn: "yesterday"),
            deployment(id: "good", createdOn: "2026-10-02T04:00:00Z"),
        ])

        XCTAssertEqual(rows.map(\.id), ["good"])
    }

    func testHidesDeploymentsTriggeredBySecretChanges() throws {
        let rows = try convert([
            deployment(id: "upload", createdOn: "2026-09-23T08:08:34.016282Z", triggeredBy: "upload"),
            deployment(id: "secret", createdOn: "2026-09-23T07:46:59.260754Z", triggeredBy: "secret"),
            deployment(id: "deploy", createdOn: "2026-09-23T07:46:57.886311Z", triggeredBy: "deployment"),
        ])

        XCTAssertEqual(rows.map(\.id), ["upload", "deploy"])
    }

    func testSourceLabels() throws {
        let cases: [(source: String?, triggeredBy: String?, label: String?)] = [
            ("wrangler", "deployment", "wrangler"),
            ("dash", nil, "dashboard"),
            ("dash_template", "upload", "dashboard"),
            ("api", nil, "API"),
            ("terraform", nil, "terraform"),
            (nil, nil, nil),
            ("", nil, nil),
            ("wrangler", "rollback", "rollback"),
            ("dash", "promotion", "promotion"),
        ]

        for testCase in cases {
            let rows = try convert([
                deployment(id: "d", createdOn: "2026-10-02T04:00:00Z", source: testCase.source, triggeredBy: testCase.triggeredBy),
            ])
            XCTAssertEqual(
                rows.first?.sourceLabel,
                testCase.label,
                "source \(testCase.source ?? "nil"), triggered_by \(testCase.triggeredBy ?? "nil")"
            )
        }
    }

    func testTrafficPercentageFollowsTheVersionWhoseShareGrew() throws {
        // Listed oldest first, and with the new version not always first, to show neither order is relied on.
        let rows = try convert([
            deployment(id: "base", createdOn: "2026-10-02T01:00:00Z", versions: [("old", 100)]),
            deployment(id: "start", createdOn: "2026-10-02T02:00:00Z", versions: [("old", 90), ("new", 10)]),
            deployment(id: "mostly-new", createdOn: "2026-10-02T03:00:00Z", versions: [("old", 30), ("new", 70)]),
            deployment(id: "full", createdOn: "2026-10-02T04:00:00Z", versions: [("new", 100)]),
        ])

        XCTAssertEqual(rows.map(\.id), ["full", "mostly-new", "start", "base"])
        XCTAssertEqual(rows.map(\.trafficPercentage), [nil, 70, 10, nil])
    }

    func testTrafficPercentageWithoutPreviousDeploymentUsesSmallestShare() throws {
        let rows = try convert([
            deployment(id: "split", createdOn: "2026-10-02T01:00:00Z", versions: [("b", 20), ("a", 80)]),
        ])

        XCTAssertEqual(rows.first?.trafficPercentage, 20)
    }

    private func convert(_ deployments: [[String: Any]]) throws -> [Deployment] {
        let data = try JSONSerialization.data(withJSONObject: ["deployments": deployments])
        let result = try JSONDecoder().decode(CloudflareWorkerDeploymentsResult.self, from: data)
        return Deployment.cloudflareWorkers(result.deployments, accountID: "acct_1", scriptName: "api")
    }

    private func deployment(
        id: String,
        createdOn: String,
        source: String? = "wrangler",
        triggeredBy: String? = "deployment",
        message: String? = nil,
        versions: [(id: String, percentage: Double)] = [("v1", 100)]
    ) -> [String: Any] {
        var annotations: [String: Any] = [:]
        annotations["workers/triggered_by"] = triggeredBy
        annotations["workers/message"] = message
        var object: [String: Any] = [
            "id": id,
            "created_on": createdOn,
            "strategy": "percentage",
            "author_email": "dev@example.com",
            "versions": versions.map { ["version_id": $0.id, "percentage": $0.percentage] },
            "annotations": annotations,
        ]
        object["source"] = source
        return object
    }
}
