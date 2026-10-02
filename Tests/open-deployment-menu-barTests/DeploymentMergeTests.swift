import XCTest
@testable import open_deployment_menu_bar

final class DeploymentMergeTests: XCTestCase {
    func testInterleavesPlatformsNewestFirst() {
        let vercel = [row("v-new", .vercel, at: 400), row("v-old", .vercel, at: 100)]
        let cloudflare = [row("cf-newest", .cloudflareWorkers, at: 500), row("cf-mid", .cloudflareWorkers, at: 200)]

        let merged = Deployment.mergedNewestFirst(vercel, cloudflare)

        XCTAssertEqual(merged.map(\.id), ["cf-newest", "v-new", "cf-mid", "v-old"])
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
