import XCTest
@testable import open_deployment_menu_bar

final class MenuBarDisplayTests: XCTestCase {
    func testProjectLabelAbbreviatesShortestLengthAndCutsLongerOnes() {
        var display = MenuBarDisplay.default
        XCTAssertEqual(display.projectLabel(for: "chat-everywhere"), "CHA")

        display.projectNameLength = 10
        XCTAssertEqual(display.projectLabel(for: "chat-everywhere"), "chat-every…")
        XCTAssertEqual(display.projectLabel(for: "web"), "web")

        display.projectNameLength = 0
        XCTAssertEqual(display.projectLabel(for: "chat-everywhere"), "chat-everywhere")
    }

    func testSettingsWithoutMenuBarKeyGetCurrentLook() throws {
        let decoded = try JSONDecoder().decode(GeneralPreferences.self, from: Data(#"{"menuLayout":"byPlatform"}"#.utf8))

        XCTAssertEqual(decoded.menuLayout, .byPlatform)
        XCTAssertEqual(decoded.menuBar, .default)
    }

    func testPartialOrEmptyMenuBarSettingsFallBackToDefaults() throws {
        let partial = try JSONDecoder().decode(
            MenuBarDisplay.self,
            from: Data(#"{"showsPlatformIcon":false,"buildTimeStyle":"seconds"}"#.utf8)
        )
        XCTAssertFalse(partial.showsPlatformIcon)
        XCTAssertEqual(partial.buildTimeStyle, .full)
        XCTAssertEqual(partial.projectNameLength, 3)

        let nothingVisible = try JSONDecoder().decode(
            MenuBarDisplay.self,
            from: Data(#"{"showsPlatformIcon":false,"showsStatusIcon":false,"showsProjectName":false,"showsBuildTime":false}"#.utf8)
        )
        XCTAssertEqual(nothingVisible, .default)
    }
}
