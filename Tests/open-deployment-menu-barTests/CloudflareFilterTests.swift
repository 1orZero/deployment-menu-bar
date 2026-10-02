import XCTest
@testable import open_deployment_menu_bar

final class CloudflareFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    func testBranchFilterHidesRowsWithoutBranchAndMatchesCaseInsensitively() {
        var preferences = CloudflarePreferences.default
        preferences.gitBranches = " Main , develop"
        let rows = [
            row("main", branch: "main", ago: 1),
            row("wrangler", branch: nil, ago: 2),
            row("feature", branch: "feature/x", ago: 3),
            row("develop", branch: "DEVELOP", ago: 4),
        ]

        XCTAssertEqual(preferences.filter(rows, now: now).map(\.id), ["main", "develop"])
    }

    func testEmptyBranchFilterKeepsRowsWithoutBranch() {
        let rows = [row("wrangler", branch: nil, ago: 1)]

        XCTAssertEqual(CloudflarePreferences.default.filter(rows, now: now).map(\.id), ["wrangler"])
    }

    func testEnvironmentToggles() {
        var preferences = CloudflarePreferences.default
        preferences.showProduction = false
        let rows = [
            row("prod", environment: .production, ago: 1),
            row("preview", environment: .preview, ago: 2),
            row("none", environment: nil, ago: 3),
        ]

        XCTAssertEqual(preferences.filter(rows, now: now).map(\.id), ["preview", "none"])

        preferences.showProduction = true
        preferences.showPreview = false
        XCTAssertEqual(preferences.filter(rows, now: now).map(\.id), ["prod", "none"])
    }

    func testStateTogglesIncludingSkipped() {
        var preferences = CloudflarePreferences.default
        preferences.limitByCount = 0
        let states: [Deployment.State] = [.ready, .building, .error, .queued, .canceled, .skipped]
        let rows = states.enumerated().map { row("\($1)", state: $1, ago: TimeInterval($0)) }

        preferences.showSkipped = false
        XCTAssertEqual(preferences.filter(rows, now: now).map(\.id), ["ready", "building", "error", "queued", "canceled"])

        preferences.showSkipped = true
        preferences.showReady = false
        preferences.showBuilding = false
        preferences.showError = false
        preferences.showQueued = false
        preferences.showCanceled = false
        XCTAssertEqual(preferences.filter(rows, now: now).map(\.id), ["skipped"])
    }

    func testCountLimitTakesPriorityOverHours() {
        var preferences = CloudflarePreferences.default
        preferences.limitByCount = 2
        preferences.limitByHours = 100
        let rows = [row("old", ago: 3 * 3600), row("new", ago: 60), row("mid", ago: 3600)]

        XCTAssertEqual(preferences.filter(rows, now: now).map(\.id), ["new", "mid"])
    }

    func testHoursLimitWithoutCount() {
        var preferences = CloudflarePreferences.default
        preferences.limitByCount = 0
        preferences.limitByHours = 2
        let rows = [row("old", ago: 3 * 3600), row("new", ago: 60), row("mid", ago: 3600)]

        XCTAssertEqual(preferences.filter(rows, now: now).map(\.id), ["new", "mid"])
    }

    func testSettingsSavedBeforeFiltersDecodeToShowEverything() throws {
        let json = Data(#"{"limitByCount": 7, "refreshInterval": 30}"#.utf8)

        let decoded = try JSONDecoder().decode(CloudflarePreferences.self, from: json)

        var expected = CloudflarePreferences.default
        expected.limitByCount = 7
        XCTAssertEqual(decoded, expected)
        XCTAssertTrue(decoded.accountIDs.isEmpty)
        XCTAssertTrue(decoded.projects.isEmpty)
        XCTAssertTrue(decoded.showSkipped)
    }

    private func row(
        _ id: String,
        state: Deployment.State = .ready,
        branch: String? = "main",
        environment: Deployment.Environment? = .production,
        ago seconds: TimeInterval
    ) -> Deployment {
        Deployment(
            id: id,
            platform: .cloudflarePages,
            projectName: id,
            state: state,
            createdAt: now.addingTimeInterval(-seconds),
            buildStartedAt: nil,
            finishedAt: nil,
            branch: branch,
            environment: environment,
            commitMessage: nil,
            openURL: nil,
            sourceLabel: nil,
            trafficPercentage: nil
        )
    }
}
