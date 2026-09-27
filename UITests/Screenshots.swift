import XCTest

/// Takes screenshots of every main screen, light and dark, with the app connected to a real
/// Clementine playing the showcase library (clementine-it/). Runs only when given Clementine's
/// host and a directory for the screenshots, as .github/workflows/screenshots.yml does:
///
///     TEST_RUNNER_CLEMENTINE_HOST=127.0.0.1 TEST_RUNNER_SCREENSHOTS_DIR=$PWD/screenshots \
///         scripts/build.sh test -only-testing:ClementineRemoteUITests/Screenshots
///
/// xcodebuild passes TEST_RUNNER_ variables to the tests without the prefix. The screenshots
/// are PNGs named in the order they're taken; the dark theme's start with dark_. On a failure,
/// failure.png and failure.txt keep the screen and its elements.
final class Screenshots: XCTestCase {
    private static let timeout: TimeInterval = 30
    /// Downloading and indexing the library takes a while on a simulator.
    private static let libraryTimeout: TimeInterval = 120
    /// Long enough for a screen or sheet to animate in.
    private static let settle: TimeInterval = 1.5

    private var app: XCUIApplication!
    private var directory: URL!

    func testTakeScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["CLEMENTINE_HOST"], let path = environment["SCREENSHOTS_DIR"] else {
            throw XCTSkip("Needs CLEMENTINE_HOST and SCREENSHOTS_DIR")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCUIDevice.shared.appearance = .light
        // Back to the light theme, which the other tests expect.
        defer { XCUIDevice.shared.appearance = .light }
        app = XCUIApplication()
        // Skip the welcome message, and fill in Clementine's address.
        app.launchArguments = ["-first_call", "NO", "-save_clementine_ip", host]
        do {
            try takeScreenshots()
        } catch {
            // What the screen showed, to see why.
            try? save(XCUIScreen.main.screenshot(), as: "failure")
            try? app.debugDescription.write(
                to: directory.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
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
        // The library isn't on the phone yet: download it from Clementine.
        try waitFor(app.buttons["downloadLibrary"], timeout: Self.libraryTimeout).tap()
        try waitFor(item("Frédéric Chopin"), timeout: Self.libraryTimeout)
        pause(Self.settle)
        try screenshot("06_library")
        item("Frédéric Chopin").tap()
        try waitFor(item("Nocturnes, Op. 9")).tap()
        try waitFor(item(startingWith: "Nocturne in"))
        pause(Self.settle)
        try screenshot("07_library_album")

        try showTab("Search")
        try search("Gymnopédie")
        let tracks = item(startingWith: "Gymnopédie No.")
        try openSearchResults(until: tracks)
        pause(Self.settle)
        try screenshot("08_search")

        // The same screens in the dark theme, each where the light pass left it.
        XCUIDevice.shared.appearance = .dark
        pause(Self.settle)
        try waitFor(tracks)
        try screenshot("dark_08_search")

        try showTab("Library")
        try waitFor(item(startingWith: "Nocturne in"))
        try screenshot("dark_07_library_album")
        // Up from the album's songs to Chopin's albums, then to the artists.
        try goBack()
        try waitFor(item("Nocturnes, Op. 9"))
        try goBack()
        try waitFor(item("Frédéric Chopin"))
        pause(Self.settle)
        try screenshot("dark_06_library")

        try showTab("Queue")
        try waitFor(queueRow("Clair de lune"))
        try screenshot("dark_02_queue")
        try openPlayer()
        try screenshot("dark_03_player")
        try closePlayer()

        try openConnectionSheet()
        try waitFor(app.buttons["Settings"]).tap()
        try waitFor(app.navigationBars["Settings"])
        pause(Self.settle)
        try screenshot("dark_05_settings")
        try goBack(in: "Settings")
        try waitFor(app.buttons["disconnect"])
        pause(Self.settle)
        try screenshot("dark_04_connection")
        // Disconnecting goes back to the connect screen.
        app.buttons["disconnect"].tap()
        try waitFor(app.buttons["connect"])
        pause(Self.settle)
        try screenshot("dark_01_connect")
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

    /// A row whose name starts with [prefix].
    private func item(startingWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %lu OR elementType == %lu) AND label BEGINSWITH %@",
            XCUIElement.ElementType.staticText.rawValue, XCUIElement.ElementType.button.rawValue, prefix
        )).firstMatch
    }

    /// A song in the queue, by its title; not the mini player, which may show the same title.
    private func queueRow(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'song-' AND label CONTAINS %@", title))
            .firstMatch
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

    /// Search results are grouped by source, then artist and album: opens the entry at each level
    /// down to the songs.
    private func openSearchResults(until tracks: XCUIElement) throws {
        for _ in 0..<4 {
            if tracks.waitForExistence(timeout: 5) {
                return
            }
            // The album, else the artist, else the first entry: the source. Each level below the
            // top starts with a header naming what was opened, so rows are matched by name first.
            let album = item("Gymnopédies")
            let artist = item("Erik Satie")
            if album.exists {
                album.tap()
            } else if artist.exists {
                artist.tap()
            } else {
                try waitFor(app.cells.firstMatch).tap()
            }
            pause(Self.settle)
        }
        try waitFor(tracks)
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
        try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        // Also in the test results, to see alongside the log.
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
