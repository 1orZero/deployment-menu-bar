import XCTest
@testable import open_deployment_menu_bar

final class MenuCompositionTests: XCTestCase {
    private let vercelRow = MenuCompositionTests.row("v", .vercel, at: 100)
    private let pagesRow = MenuCompositionTests.row("p", .cloudflarePages, at: 300)
    private let workersRow = MenuCompositionTests.row("w", .cloudflareWorkers, at: 200)
    private let cloudflareIssue = PlatformIssue(message: "Cloudflare API error (401): Invalid token")

    func testByTimeMergesNewestFirstWithBannersOnTopAndDashboardsInFooter() {
        let composition = MenuComposition(
            layout: .byTime,
            vercel: PlatformStatus(deployments: [vercelRow]),
            cloudflare: PlatformStatus(deployments: [workersRow, pagesRow], issue: cloudflareIssue)
        )

        XCTAssertEqual(composition.entries, [
            .banner("Cloudflare: Cloudflare API error (401): Invalid token"),
            .separator,
            .deployment(pagesRow),
            .deployment(workersRow),
            .deployment(vercelRow),
        ])
        XCTAssertEqual(composition.footerDashboards, [.vercel, .cloudflare])
    }

    func testByPlatformGivesEachEnabledPlatformItsOwnSection() {
        let composition = MenuComposition(
            layout: .byPlatform,
            vercel: PlatformStatus(deployments: [vercelRow]),
            cloudflare: PlatformStatus(deployments: [workersRow, pagesRow])
        )

        XCTAssertEqual(composition.entries, [
            .header("Vercel"),
            .deployment(vercelRow),
            .dashboard(.vercel),
            .separator,
            .header("Cloudflare"),
            .deployment(pagesRow),
            .deployment(workersRow),
            .dashboard(.cloudflare),
        ])
        XCTAssertEqual(composition.footerDashboards, [])
    }

    func testByPlatformShowsAFailureOnlyInsideTheFailingSection() {
        let composition = MenuComposition(
            layout: .byPlatform,
            vercel: PlatformStatus(deployments: [vercelRow]),
            cloudflare: PlatformStatus(issue: cloudflareIssue)
        )

        XCTAssertEqual(composition.entries, [
            .header("Vercel"),
            .deployment(vercelRow),
            .dashboard(.vercel),
            .separator,
            .header("Cloudflare"),
            .banner("Cloudflare API error (401): Invalid token"),
            .dashboard(.cloudflare),
        ])
    }

    func testByPlatformOmitsDisabledPlatform() {
        let composition = MenuComposition(
            layout: .byPlatform,
            vercel: PlatformStatus(isEnabled: false),
            cloudflare: PlatformStatus()
        )

        XCTAssertEqual(composition.entries, [
            .header("Cloudflare"),
            .notice(MenuComposition.noDeploymentsMessage),
            .dashboard(.cloudflare),
        ])
        XCTAssertEqual(composition.footerDashboards, [])
    }

    func testNoEnabledPlatformKeepsNoTokenPresentationInEitherLayout() {
        for layout in MenuLayout.allCases {
            let composition = MenuComposition(
                layout: layout,
                vercel: PlatformStatus(isEnabled: false),
                cloudflare: PlatformStatus(isEnabled: false)
            )

            XCTAssertEqual(composition.entries, [.notice(MenuComposition.noTokenMessage), .separator], "\(layout)")
            XCTAssertEqual(composition.footerDashboards, [.vercel, .cloudflare], "\(layout)")
        }
    }

    private static func row(_ id: String, _ platform: Deployment.Platform, at seconds: TimeInterval) -> Deployment {
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
