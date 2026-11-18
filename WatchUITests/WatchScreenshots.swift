import ClementineWatch
import XCTest

/// Takes the Apple Watch app's screenshots, for the App Store: run by
/// .github/workflows/watch-screenshots.yml, on an Apple Watch simulator, as
///
///     TEST_RUNNER_SCREENSHOTS_DIR=$PWD/screenshots xcodebuild test -scheme ClementineRemoteWatch ...
///
/// The watch only talks to Clementine through the phone, which a test can't pair it with, so the
/// app shows what it's given in SHOWCASE_NOW_PLAYING (debug builds only): the song the phone's
/// screenshots play, from the showcase library (clementine-it/), as the phone would send it.
/// Screenshots are PNGs named watch_<n>_<screen>.
@MainActor
final class WatchScreenshots: XCTestCase {
    func testTakeScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"] else {
            throw XCTSkip("Needs SCREENSHOTS_DIR")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let playing = WatchNowPlaying(
            connection: .connected, hostName: "Clementine", title: "Clair de lune", artist: "Claude Debussy",
            album: "Suite bergamasque", isPlaying: true, volume: 80, length: 300, position: 94, showsLove: true)
        try take("01_now_playing", showing: playing, in: directory)
    }

    private func take(_ name: String, showing state: WatchNowPlaying, in directory: URL) throws {
        let app = XCUIApplication()
        let json = String(decoding: WatchLinkCoding.encodeData(state), as: UTF8.self)
        app.launchEnvironment["SHOWCASE_NOW_PLAYING"] = json
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        // Let the cover and the progress bar settle.
        Thread.sleep(forTimeInterval: 3)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: directory.appendingPathComponent("watch_\(name).png"))
        app.terminate()
    }
}
