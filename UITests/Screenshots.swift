import XCTest

/// Takes screenshots of every main screen, with the app connected to a real Clementine playing
/// the showcase library (clementine-it/). Runs only when given Clementine's host and a directory
/// for the screenshots, as .github/workflows/screenshots.yml does, once with the simulator light
/// and once dark:
///
///     xcrun simctl ui booted appearance dark
///     TEST_RUNNER_CLEMENTINE_HOST=127.0.0.1 TEST_RUNNER_SCREENSHOTS_DIR=$PWD/screenshots \
///         TEST_RUNNER_SCREENSHOTS_PREFIX=dark_ \
///         scripts/build.sh test -only-testing:ClementineRemoteUITests/Screenshots
///
/// xcodebuild passes TEST_RUNNER_ variables to the tests without the prefix. The screenshots
/// are PNGs named in the order they're taken, after SCREENSHOTS_PREFIX. On a failure,
/// failure.png and failure.txt (after the prefix too) keep the screen and its elements.
///
/// The simulator's appearance is set from outside: set from the test (XCUIDevice.appearance),
/// the app stayed light.
final class Screenshots: XCTestCase {
    private static let timeout: TimeInterval = 30
    /// Downloading and indexing the library takes a while on a simulator.
    private static let libraryTimeout: TimeInterval = 120
    /// Long enough for a screen or sheet to animate in.
    private static let settle: TimeInterval = 1.5

    private var app: XCUIApplication!
    private var directory: URL!
    private var prefix = ""

    func testTakeScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CLEMENTINE_HOST"], let path = environment["SCREENSHOTS_DIR"] else {
            throw XCTSkip("Needs CLEMENTINE_HOST and SCREENSHOTS_DIR")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        prefix = environment["SCREENSHOTS_PREFIX"] ?? ""
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        app = XCUIApplication()
        // Skip the welcome message, stay on the connect screen, and fill in Clementine's address.
        app.launchArguments = ["-first_call", "NO", "-pref_autoconnect", "NO", "-save_clementine_ip", host]
        do {
            try takeScreenshots()
        } catch {
            // What the screen showed, to see why.
            try? save(XCUIScreen.main.screenshot(), as: "failure")
            try? app.debugDescription.write(
                to: directory.appendingPathComponent(prefix + "failure.txt"), atomically: true, encoding: .utf8)
            throw error
        }
    }

    private func takeScreenshots() throws {
        app.launch()
        try waitFor(app.buttons["connect"])
        pause(Self.settle)
        try screenshot("01_connect")

        app.buttons["connect"].tap()
        // Connected: the queue shows.
        try waitFor(app.buttons["connectionChip"])
        try waitFor(queueRow("Clair de lune"))
        pause(Self.settle)
        try screenshot("02_queue")

        try play("Clair de lune")
        // Let playback move along the seek bar.
        pause(8)
        try screenshot("03_player")
        try closePlayer()

        try openConnectionSheet()
        try screenshot("04_connection")
        // The settings, from the sheet.
        try waitFor(app.buttons["Settings"]).tap()
        try waitFor(app.navigationBars["Settings"])
        pause(Self.settle)
        try screenshot("05_settings")
        try closeConnectionSheet()

        try showTab("Library")
        try openLibrary()
        pause(Self.settle)
        try screenshot("06_library")
        item("Frédéric Chopin").tap()
        try waitFor(item("Nocturnes, Op. 9")).tap()
        try waitFor(item(startingWith: "Nocturne in"))
        pause(Self.settle)
        try screenshot("07_library_album")

        // Clementine's internet services, before searching, which hides the other tabs.
        try showTab("Internet")
        try waitFor(app.navigationBars["Internet"])
        try waitFor(app.descendants(matching: .any)["internetNode"])
        pause(Self.settle)
        try screenshot("10_internet")
        // The radio streams saved in it (clementine-it/start-clementine.sh), the last service.
        try scrollTo(item(startingWith: "Your radio streams")).tap()
        try waitFor(item(startingWith: "Groove Salad"))
        pause(Self.settle)
        try screenshot("11_internet_radio")

        try showTab("Search")
        try search("Gymnopédie")
        // Songs matched by title are listed straight away.
        try waitFor(item(startingWith: "Gymnopédie No."))
        pause(Self.settle)
        try screenshot("08_search")

        // Where Clementine can play (remote streaming), from the mini player.
        try waitFor(app.buttons["outputs"]).tap()
        try waitFor(app.navigationBars["Play on"])
        pause(Self.settle)
        try screenshot("09_outputs")
        try waitFor(app.navigationBars["Play on"].buttons["Done"]).tap()
    }

    // MARK: - Screens

    /// A row of the library or search results, or its header, by its name: the text, or a row's
    /// button, whose label is its texts together.
    private func item(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %lu AND label == %@) OR (elementType == %lu AND label BEGINSWITH %@)",
            XCUIElement.ElementType.staticText.rawValue, name, XCUIElement.ElementType.button.rawValue, name + ","
        )).firstMatch
    }

    /// A row whose name starts with [start].
    private func item(startingWith start: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %lu OR elementType == %lu) AND label BEGINSWITH %@",
            XCUIElement.ElementType.staticText.rawValue, XCUIElement.ElementType.button.rawValue, start
        )).firstMatch
    }

    /// A song in the queue, by its title; not the mini player, which may show the same title.
    private func queueRow(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'song-' AND label CONTAINS %@", title))
            .firstMatch
    }

    /// The library's artists. The library isn't on the phone the first time: it's downloaded from
    /// Clementine then.
    private func openLibrary() throws {
        let artist = item("Frédéric Chopin")
        let download = app.buttons["downloadLibrary"]
        let deadline = Date.now.addingTimeInterval(Self.libraryTimeout)
        while !artist.exists, Date.now < deadline {
            if download.exists {
                download.tap()
            }
            pause(1)
        }
        try waitFor(artist, timeout: Self.libraryTimeout)
    }

    /// Scrolls the list shown down until [element] is on screen, and returns it: a list only has
    /// the rows in sight.
    private func scrollTo(_ element: XCUIElement) throws -> XCUIElement {
        // Other tabs' lists stay loaded, so the swipe is on the screen, not a list found.
        for _ in 0..<15 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return try waitFor(element)
    }

    private func showTab(_ name: String) throws {
        try waitFor(app.tabBars.buttons[name]).tap()
        pause(Self.settle)
    }

    /// Back up the navigation stack, in the navigation bar titled [bar], else the one shown.
    private func goBack(in bar: String? = nil) throws {
        let bars = app.navigationBars
        try waitFor((bar.map { bars[$0] } ?? bars.firstMatch).buttons.element(boundBy: 0)).tap()
        pause(Self.settle)
    }

    private func openPlayer() throws {
        try waitFor(app.buttons["miniPlayer"]).tap()
        try waitFor(app.buttons["Close player"])
        pause(Self.settle)
    }

    private func closePlayer() throws {
        app.buttons["Close player"].tap()
        try waitFor(app.buttons["miniPlayer"])
        pause(Self.settle)
    }

    /// The connection sheet, dragged up until its buttons show: it opens at half height, and its
    /// list only makes the rows it shows.
    private func openConnectionSheet() throws {
        try waitFor(app.buttons["connectionChip"]).tap()
        try waitFor(app.navigationBars["Clementine"])
        pause(Self.settle)
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Clementine on'")).firstMatch
        let disconnect = app.buttons["disconnect"]
        for _ in 0..<4 where !(disconnect.exists && disconnect.isHittable) {
            // Grows the sheet, or scrolls its list once it's full height. From the title, else just
            // below the sheet's navigation bar once the title has scrolled away.
            let start = title.exists
                ? title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.navigationBars["Clementine"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 3))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
            pause(Self.settle)
        }
        try waitFor(disconnect)
    }

    /// From the settings in the connection sheet, back to the tab below.
    private func closeConnectionSheet() throws {
        try goBack(in: "Settings")
        try waitFor(app.navigationBars["Clementine"].buttons["Done"]).tap()
        try waitFor(app.buttons["miniPlayer"])
        pause(Self.settle)
    }

    /// Plays a song by tapping it in the queue, and opens the player. Clementine sometimes
    /// starts another song instead, so this checks and tries again.
    private func play(_ title: String) throws {
        let playing = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'songInfo' AND label BEGINSWITH %@", title))
            .firstMatch
        for attempt in 1...3 {
            if attempt > 1 {
                try closePlayer()
            }
            try waitFor(queueRow(title)).tap()
            try openPlayer()
            if playing.waitForExistence(timeout: 10) {
                return
            }
        }
        throw Failure("Could not play \(title)")
    }

    private func search(_ text: String) throws {
        let field = try waitFor(app.searchFields.firstMatch)
        field.tap()
        field.typeText(text + "\n")
    }

    // MARK: - Helpers

    private struct Failure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    @discardableResult
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = timeout) throws -> XCUIElement {
        guard element.waitForExistence(timeout: timeout) else {
            throw Failure("Not shown: \(element)")
        }
        return element
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func screenshot(_ name: String) throws {
        try save(XCUIScreen.main.screenshot(), as: name)
    }

    private func save(_ screenshot: XCUIScreenshot, as name: String) throws {
        try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(prefix + name + ".png"))
        // Also in the test results, to see alongside the log.
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = prefix + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
