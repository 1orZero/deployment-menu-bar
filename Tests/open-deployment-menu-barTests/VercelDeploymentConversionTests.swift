import XCTest
@testable import open_deployment_menu_bar

final class VercelDeploymentConversionTests: XCTestCase {
    func testConvertsFullVercelDeployment() throws {
        let deployment = try convert("""
        {
          "uid": "dpl_1",
          "name": "my-app",
          "url": "my-app-abc.vercel.app",
          "inspectorUrl": "https://vercel.com/team/my-app/dpl_1",
          "created": 1700000000000,
          "buildingAt": 1700000005000,
          "ready": 1700000065500,
          "state": "READY",
          "target": "production",
          "creator": { "username": "derek" },
          "meta": { "githubCommitMessage": "Fix bug", "githubCommitRef": "meta-branch" },
          "gitSource": { "ref": "main", "type": "github" }
        }
        """)

        XCTAssertEqual(deployment.id, "dpl_1")
        XCTAssertEqual(deployment.platform, .vercel)
        XCTAssertEqual(deployment.projectName, "my-app")
        XCTAssertEqual(deployment.state, .ready)
        XCTAssertEqual(deployment.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(deployment.buildStartedAt, Date(timeIntervalSince1970: 1_700_000_005))
        XCTAssertEqual(deployment.finishedAt, Date(timeIntervalSince1970: 1_700_000_065.5))
        XCTAssertEqual(deployment.branch, "main")
        XCTAssertEqual(deployment.environment, .production)
        XCTAssertEqual(deployment.commitMessage, "Fix bug")
        XCTAssertEqual(deployment.openURL, URL(string: "https://vercel.com/team/my-app/dpl_1"))
        XCTAssertNil(deployment.sourceLabel)
        XCTAssertNil(deployment.trafficPercentage)
    }

    func testMapsEveryVercelState() throws {
        let expected: [(String, Deployment.State)] = [
            ("QUEUED", .queued),
            ("BUILDING", .building),
            ("READY", .ready),
            ("ERROR", .error),
            ("CANCELED", .canceled),
            ("INITIALIZING", .unknown),
        ]
        for (rawState, state) in expected {
            XCTAssertEqual(try convert(minimalJSON(extra: "\"state\": \"\(rawState)\"")).state, state, rawState)
        }
    }

    func testMissingBuildAndReadyTimestampsFallBack() throws {
        let deployment = try convert(minimalJSON(extra: "\"state\": \"QUEUED\""))

        XCTAssertNil(deployment.buildStartedAt)
        XCTAssertNil(deployment.finishedAt)
        XCTAssertEqual(deployment.buildStartDate, deployment.createdAt)
    }

    func testBranchFallsBackToMetaCommitRef() throws {
        let deployment = try convert(minimalJSON(extra: """
        "state": "READY", "meta": { "githubCommitRef": "feature/x" }, "gitSource": { "type": "github" }
        """))

        XCTAssertEqual(deployment.branch, "feature/x")
    }

    func testBranchIsNilWhenNoRefIsReported() throws {
        XCTAssertNil(try convert(minimalJSON(extra: "\"state\": \"READY\"")).branch)
        XCTAssertNil(try convert(minimalJSON(extra: "\"state\": \"READY\", \"gitSource\": { \"ref\": \"\" }")).branch)
    }

    func testEnvironmentFromTarget() throws {
        XCTAssertEqual(try convert(minimalJSON(extra: "\"state\": \"READY\", \"target\": \"production\"")).environment, .production)
        XCTAssertEqual(try convert(minimalJSON(extra: "\"state\": \"READY\", \"target\": \"Preview\"")).environment, .preview)
        XCTAssertEqual(try convert(minimalJSON(extra: "\"state\": \"READY\", \"target\": \"staging\"")).environment, .custom("staging"))
        XCTAssertNil(try convert(minimalJSON(extra: "\"state\": \"READY\", \"target\": null")).environment)
    }

    func testOpenURLFallsBackToDeploymentURLWithHTTPS() throws {
        let withoutInspector = try convert(minimalJSON(extra: "\"state\": \"READY\""))
        XCTAssertEqual(withoutInspector.openURL, URL(string: "https://my-app-abc.vercel.app"))

        let blankInspector = try convert(minimalJSON(extra: "\"state\": \"READY\", \"inspectorUrl\": \"  \""))
        XCTAssertEqual(blankInspector.openURL, URL(string: "https://my-app-abc.vercel.app"))
    }

    func testOpenURLKeepsExistingScheme() throws {
        let deployment = try convert("""
        {
          "uid": "dpl_2", "name": "my-app", "url": "http://localhost:3000",
          "created": 1700000000000, "state": "READY", "creator": {}
        }
        """)

        XCTAssertEqual(deployment.openURL, URL(string: "http://localhost:3000"))
    }

    private func minimalJSON(extra: String) -> String {
        """
        {
          "uid": "dpl_1",
          "name": "my-app",
          "url": "my-app-abc.vercel.app",
          "created": 1700000000000,
          "creator": {},
          \(extra)
        }
        """
    }

    private func convert(_ json: String) throws -> Deployment {
        let dto = try JSONDecoder().decode(VercelDeployment.self, from: Data(json.utf8))
        return Deployment(vercel: dto)
    }
}
