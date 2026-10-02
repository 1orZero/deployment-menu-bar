import XCTest
@testable import open_deployment_menu_bar

final class StatusButtonStateTests: XCTestCase {
    private let failure = PlatformIssue(message: "Cloudflare API error (401): Invalid token")

    func testShowsNewestAcrossHealthyPlatformsWithoutWarning() {
        let vercel = PlatformStatus(deployments: [row("v", .vercel, at: 100)])
        let cloudflare = PlatformStatus(deployments: [row("cf", .cloudflareWorkers, at: 200)])

        XCTAssertEqual(
            StatusButtonState(platforms: [vercel, cloudflare]),
            .deployment(row("cf", .cloudflareWorkers, at: 200), warning: false)
        )
    }

    func testOneFailingPlatformShowsTheOtherWithWarning() {
        let vercel = PlatformStatus(deployments: [row("v", .vercel, at: 100)])
        let cloudflare = PlatformStatus(issue: failure)

        XCTAssertEqual(
            StatusButtonState(platforms: [vercel, cloudflare]),
            .deployment(row("v", .vercel, at: 100), warning: true)
        )
    }

    func testAllEnabledPlatformsFailingShowsError() {
        let vercel = PlatformStatus(issue: PlatformIssue(message: "Vercel API error (403): Forbidden"))
        let cloudflare = PlatformStatus(issue: failure)

        XCTAssertEqual(StatusButtonState(platforms: [vercel, cloudflare]), .error)
    }

    func testOnlyEnabledPlatformFailingShowsError() {
        let vercel = PlatformStatus(isEnabled: false)
        let cloudflare = PlatformStatus(issue: failure)

        XCTAssertEqual(StatusButtonState(platforms: [vercel, cloudflare]), .error)
    }

    func testNoEnabledPlatformShowsNoToken() {
        let disabled = PlatformStatus(isEnabled: false)

        XCTAssertEqual(StatusButtonState(platforms: [disabled, disabled]), .noToken)
    }

    func testDisabledPlatformIsNotAFailure() {
        let vercel = PlatformStatus(deployments: [row("v", .vercel, at: 100)])
        let cloudflare = PlatformStatus(isEnabled: false)

        XCTAssertEqual(
            StatusButtonState(platforms: [vercel, cloudflare]),
            .deployment(row("v", .vercel, at: 100), warning: false)
        )
    }

    func testHealthyPlatformWithoutRowsAndFailingPlatformShowsEmptyWithWarning() {
        let vercel = PlatformStatus()
        let cloudflare = PlatformStatus(issue: failure)

        XCTAssertEqual(StatusButtonState(platforms: [vercel, cloudflare]), .empty(warning: true))
    }

    func testPlatformWithIssueButRowsStillShowsRowsWithWarning() {
        let vercel = PlatformStatus(issue: PlatformIssue(message: "Vercel API error (500): Internal"))
        let cloudflare = PlatformStatus(
            deployments: [row("cf", .cloudflareWorkers, at: 200)],
            issue: PlatformIssue(message: "Missing Workers CI Read")
        )

        XCTAssertEqual(
            StatusButtonState(platforms: [vercel, cloudflare]),
            .deployment(row("cf", .cloudflareWorkers, at: 200), warning: true)
        )
    }

    private func row(_ id: String, _ platform: Deployment.Platform, at seconds: TimeInterval) -> Deployment {
        Deployment(
            id: id,
            platform: platform,
            projectName: id,
            state: .ready,
            createdAt: Date(timeIntervalSince1970: seconds),
            buildStartedAt: nil,
            finishedAt: nil,
            branch: nil,
            environment: .production,
            commitMessage: nil,
            openURL: nil,
            sourceLabel: nil,
            trafficPercentage: nil
        )
    }
}
