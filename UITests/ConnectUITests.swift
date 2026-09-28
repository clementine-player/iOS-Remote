import XCTest

final class ConnectUITests: XCTestCase {
    func testShowsTheConnectScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-first_call", "NO", "-pref_autoconnect", "NO"]
        app.launch()
        XCTAssertTrue(app.textFields["address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connect"].exists)
    }
}
