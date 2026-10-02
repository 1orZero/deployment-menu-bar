import XCTest
@testable import open_deployment_menu_bar

/// Paging of the Pages deployments and Workers builds lists until enough rows pass the filters. Deployment objects
/// follow https://developers.cloudflare.com/api/resources/pages/subresources/projects/subresources/deployments/methods/list/
final class CloudflarePagingTests: XCTestCase {
    private let deploymentsPath = "/client/v4/accounts/acct_1/pages/projects/site/deployments"
    private let buildsPath = "/client/v4/accounts/acct_1/builds/workers/tag_api/builds"

    override func tearDown() {
        PagingStubURLProtocol.reset()
        super.tearDown()
    }

    func testHiddenPreviewsBeforeAProductionDeploymentOnTheSamePageStillShowIt() async throws {
        stubPages { page in
            page == 1 ? (0..<5).map { self.pagesDeployment(index: $0, environment: "preview") }
                + [self.pagesDeployment(index: 5, environment: "production")] : []
        }

        let snapshot = try await service().fetchDeployments(token: "token", preferences: previewHidden)

        XCTAssertEqual(snapshot.deployments.filter(previewHidden.matches).map(\.id), ["dep_5"])
        XCTAssertEqual(PagingStubURLProtocol.pages(of: deploymentsPath), [1])
    }

    func testAFullPageOfHiddenPreviewsRequestsTheNextPage() async throws {
        stubPages { page in
            switch page {
            case 1: (0..<25).map { self.pagesDeployment(index: $0, environment: "preview") }
            case 2: [self.pagesDeployment(index: 25, environment: "production")]
            default: []
            }
        }

        let snapshot = try await service().fetchDeployments(token: "token", preferences: previewHidden)

        XCTAssertEqual(snapshot.deployments.filter(previewHidden.matches).map(\.id), ["dep_25"])
        XCTAssertEqual(PagingStubURLProtocol.pages(of: deploymentsPath), [1, 2])
        XCTAssertEqual(PagingStubURLProtocol.values(of: deploymentsPath, name: "per_page"), ["25", "25"])
    }

    func testAFirstPageWithEnoughMatchesIsTheOnlyRequest() async throws {
        stubPages { _ in (0..<25).map { self.pagesDeployment(index: $0, environment: "production") } }

        let snapshot = try await service().fetchDeployments(token: "token", preferences: .default)

        XCTAssertEqual(snapshot.deployments.count, 25)
        XCTAssertEqual(PagingStubURLProtocol.pages(of: deploymentsPath), [1])
    }

    func testHoursModeStopsAfterThePageThatReachesPastTheWindow() async throws {
        var preferences = CloudflarePreferences.default
        preferences.limitByCount = 0
        preferences.limitByHours = 2
        // One deployment every 4 minutes against a 120-minute window: page 1 ends 96 minutes ago (inside),
        // page 2 ends 196 minutes ago (outside), and page 3 is never requested.
        stubPages { page in
            (0..<25).map { offset in
                let index = (page - 1) * 25 + offset
                return self.pagesDeployment(index: index, environment: "production", minutesAgo: index * 4)
            }
        }

        _ = try await service().fetchDeployments(token: "token", preferences: preferences)

        XCTAssertEqual(PagingStubURLProtocol.pages(of: deploymentsPath), [1, 2])
    }

    func testFullPagesWithoutMatchesStopAtFourPagesAndReportPartialResults() async throws {
        stubPages { page in
            (0..<25).map { self.pagesDeployment(index: (page - 1) * 25 + $0, environment: "production") }
        }

        let snapshot = try await service().fetchDeployments(token: "token", preferences: releaseBranchOnly)

        XCTAssertEqual(PagingStubURLProtocol.pages(of: deploymentsPath), [1, 2, 3, 4])
        XCTAssertEqual(snapshot.deployments.count, 100)
        XCTAssertEqual(snapshot.issue?.message, "Partial results: stopped after 100 deployments for site")
    }

    func testLimitReachedOnTheLastAllowedPageIsNotPartial() async throws {
        stubPages { page in
            (0..<25).map { offset in
                let index = (page - 1) * 25 + offset
                return self.pagesDeployment(index: index, environment: page == 4 && offset >= 20 ? "production" : "preview")
            }
        }

        let snapshot = try await service().fetchDeployments(token: "token", preferences: previewHidden)

        XCTAssertEqual(PagingStubURLProtocol.pages(of: deploymentsPath), [1, 2, 3, 4])
        XCTAssertEqual(snapshot.deployments.filter(previewHidden.matches).count, 5)
        XCTAssertNil(snapshot.issue)
    }

    func testPagesEnvironmentIsFilteredServerSideWhenOnlyOneIsShown() async throws {
        stubPages { _ in [self.pagesDeployment(index: 0, environment: "production")] }
        var productionOnly = CloudflarePreferences.default
        productionOnly.showPreview = false
        _ = try await service().fetchDeployments(token: "token", preferences: productionOnly)
        XCTAssertEqual(PagingStubURLProtocol.values(of: deploymentsPath, name: "env"), ["production"])

        stubPages { _ in [self.pagesDeployment(index: 0, environment: "production")] }
        _ = try await service().fetchDeployments(token: "token", preferences: .default)
        XCTAssertEqual(PagingStubURLProtocol.values(of: deploymentsPath, name: "env"), [])
        XCTAssertEqual(PagingStubURLProtocol.pages(of: deploymentsPath), [1])

        stubPages { _ in [self.pagesDeployment(index: 0, environment: "production")] }
        var neither = productionOnly
        neither.showProduction = false
        let snapshot = try await service().fetchDeployments(token: "token", preferences: neither)
        XCTAssertEqual(PagingStubURLProtocol.pages(of: deploymentsPath), [])
        XCTAssertTrue(snapshot.deployments.isEmpty)
    }

    func testBuildsPermissionIssueAndPartialResultsShareOneMessage() async throws {
        PagingStubURLProtocol.stub { path, page in
            switch path {
            case "/client/v4/accounts": [["id": "acct_1", "name": "Account"]]
            case "/client/v4/accounts/acct_1/workers/scripts": [["id": "api", "tag": "tag_api"]]
            case "/client/v4/accounts/acct_1/workers/scripts/api/deployments": ["deployments": []]
            case "/client/v4/accounts/acct_1/builds/builds/latest": PagingStubFailure(status: 401)
            case "/client/v4/accounts/acct_1/pages/projects": [["name": "site"]]
            case self.deploymentsPath:
                (0..<25).map { self.pagesDeployment(index: (page - 1) * 25 + $0, environment: "production") }
            default: nil
            }
        }

        let snapshot = try await service().fetchDeployments(token: "token", preferences: releaseBranchOnly)

        XCTAssertEqual(
            snapshot.issue?.message,
            "Workers build status needs a user API token with Workers CI Read"
                + " · Partial results: stopped after 100 deployments for site"
        )
    }

    func testPartialResultsNamesThreeListsThenTheRest() {
        XCTAssertEqual(
            CloudflareService.partialResultsMessage(truncatedLists: ["e", "b", "d", "a", "c"]),
            "Partial results: stopped after 100 deployments for a, b, c +2 more"
        )
        XCTAssertNil(CloudflareService.partialResultsMessage(truncatedLists: []))
    }

    func testAFullPageOfHiddenPreviewBuildsRequestsTheNextPage() async throws {
        PagingStubURLProtocol.stub { path, page in
            switch path {
            case "/client/v4/accounts": [["id": "acct_1", "name": "Account"]]
            case "/client/v4/accounts/acct_1/workers/scripts": [["id": "api", "tag": "tag_api"]]
            case "/client/v4/accounts/acct_1/workers/scripts/api/deployments": ["deployments": []]
            case "/client/v4/accounts/acct_1/builds/builds/latest":
                ["builds": ["tag_api": self.build(index: 0, deployCommand: "npx wrangler versions upload")]]
            case self.buildsPath:
                switch page {
                case 1: (0..<25).map { self.build(index: $0, deployCommand: "npx wrangler versions upload") }
                case 2: [self.build(index: 25, deployCommand: "npx wrangler deploy")]
                default: []
                }
            case "/client/v4/accounts/acct_1/pages/projects": []
            default: nil
            }
        }

        let snapshot = try await service().fetchDeployments(token: "token", preferences: previewHidden)

        XCTAssertNil(snapshot.issue)
        XCTAssertEqual(snapshot.deployments.filter(previewHidden.matches).map(\.id), ["build_25"])
        XCTAssertEqual(PagingStubURLProtocol.pages(of: buildsPath), [1, 2])
    }

    // MARK: - Fixtures

    private var previewHidden: CloudflarePreferences {
        var preferences = CloudflarePreferences.default
        preferences.showPreview = false
        return preferences
    }

    private var releaseBranchOnly: CloudflarePreferences {
        var preferences = CloudflarePreferences.default
        preferences.gitBranches = "release"
        return preferences
    }

    /// One account with no Workers and one Pages project `site` whose deployment pages come from `deployments`.
    private func stubPages(_ deployments: @escaping (Int) -> [[String: Any]]) {
        PagingStubURLProtocol.stub { path, page in
            switch path {
            case "/client/v4/accounts": [["id": "acct_1", "name": "Account"]]
            case "/client/v4/accounts/acct_1/workers/scripts": []
            case "/client/v4/accounts/acct_1/pages/projects": [["name": "site"]]
            case self.deploymentsPath: deployments(page)
            default: nil
            }
        }
    }

    private func service() -> CloudflareService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagingStubURLProtocol.self]
        return CloudflareService(session: URLSession(configuration: configuration))
    }

    /// Newest first: a higher index is older.
    private func pagesDeployment(index: Int, environment: String, minutesAgo: Int? = nil) -> [String: Any] {
        let createdOn = date(minutesAgo: minutesAgo ?? index)
        return [
            "id": "dep_\(index)",
            "created_on": createdOn,
            "environment": environment,
            "is_skipped": false,
            "latest_stage": ["name": "deploy", "status": "success", "started_on": createdOn, "ended_on": createdOn],
            "stages": [],
            "deployment_trigger": ["metadata": ["branch": "main", "commit_message": "Change \(index)"]],
        ]
    }

    private func build(index: Int, deployCommand: String) -> [String: Any] {
        [
            "build_uuid": "build_\(index)",
            "status": "stopped",
            "build_outcome": "success",
            "created_on": date(minutesAgo: index),
            "stopped_on": date(minutesAgo: index),
            "build_trigger_metadata": ["branch": "main", "commit_message": "Change \(index)", "deploy_command": deployCommand],
            "trigger": ["external_script_id": "tag_api", "deploy_command": deployCommand],
        ]
    }

    private func date(minutesAgo: Int) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)))
    }
}

/// Serves the `result` of each request from a closure of URL path and `page` query item, and records every request.
private final class PagingStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((String, Int) -> Any?)?
    private static var requests: [URLComponents] = []

    static func stub(_ handler: @escaping (_ path: String, _ page: Int) -> Any?) {
        lock.withLock {
            self.handler = handler
            requests = []
        }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            requests = []
        }
    }

    static func pages(of path: String) -> [Int] {
        values(of: path, name: "page").compactMap { Int($0) }.sorted()
    }

    static func values(of path: String, name: String) -> [String] {
        lock.withLock {
            requests.filter { $0.path == path }.compactMap { components in
                components.queryItems?.first { $0.name == name }?.value
            }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let page = components.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
        let result = Self.lock.withLock {
            Self.requests.append(components)
            return Self.handler?(components.path, page)
        }
        let (status, body): (Int, Any) = switch result {
        case let failure as PagingStubFailure:
            (failure.status, ["errors": [["code": 12006, "message": "Invalid token"]], "result": NSNull(), "success": false])
        case let result?:
            (200, ["errors": [], "messages": [], "result": result, "success": true])
        case nil:
            (404, ["errors": [["code": 7003, "message": "Not found"]]])
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A handler result that makes the stub answer with this error status.
private struct PagingStubFailure {
    let status: Int
}
