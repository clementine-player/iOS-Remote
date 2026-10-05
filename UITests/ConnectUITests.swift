import XCTest

final class ConnectUITests: XCTestCase {
    func testShowsTheConnectScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-pref_autoconnect", "NO"]
        app.launch()
        XCTAssertTrue(app.textFields["address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connect"].exists)
    }
}
