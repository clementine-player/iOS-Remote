# Clementine Remote for iOS

Clementine Remote controls the [Clementine](https://www.clementine-player.org/) music player on
your computer from your iPhone or iPad, over your local network. It does what the
[Android remote](https://github.com/clementine-player/Android-Remote) does: play and pause, browse
and search your library, browse Clementine's internet services (radio stations, Jamendo, Subsonic,
Plex and the rest), manage playlists, read lyrics, rate songs, download songs to your phone, and
play Clementine's music on your phone instead of your computer (remote streaming).

You need Clementine 1.3 or later, with Tools → Preferences → Network Remote turned on.

The design is in [design/DESIGN.md](design/DESIGN.md).

## Translating

The app is translated on [Transifex](https://explore.transifex.com/davidsansome/clementine-remot/),
together with the Android remote: sign in with a GitHub account, or make a Transifex one, and
join a language. Translations made there come back into the app by themselves, every night, and
go out with the next release. Please don't translate in pull requests: the next night's
translations would replace them.

## Building

Needs Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/build.sh          # regenerate the Xcode project, build for the simulator, sync the strings
scripts/build.sh test     # run the tests
```

The Xcode project is generated from `project.yml`; after changing that file, run
`xcodegen generate`. `ClementineKit` (in `Packages/`) holds everything that doesn't need a screen,
and its tests also run with `swift test`.

To build to your own iPhone without being on the project's team, copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team, bundle identifier
and app group there. It overrides `Config/Signing.xcconfig` and isn't committed. Then:

```sh
DESTINATION="id=<your device's UDID>" scripts/build.sh -allowProvisioningUpdates build
```

## Screenshots

On pull requests that change the app, `.github/workflows/screenshots.yml` takes screenshots of
every main screen, light and dark, and posts them on the pull request next to main's, as the
Android remote does. The app runs on a simulator against a real Clementine: its latest macOS
release, playing the showcase library in `clementine-it/`. `UITests/Screenshots.swift` drives the
app; without Clementine's address it skips itself, so `scripts/build.sh test` doesn't run it. To
run it locally, with a Clementine set up by `clementine-it/start-clementine.sh`:

```sh
TEST_RUNNER_CLEMENTINE_HOST=127.0.0.1 TEST_RUNNER_SCREENSHOTS_DIR=$PWD/screenshots \
    scripts/build.sh test -only-testing:ClementineRemoteUITests/Screenshots
```

For the dark screenshots, run it again with the simulator dark (`xcrun simctl ui booted appearance
dark`) and `TEST_RUNNER_SCREENSHOTS_PREFIX=dark_`.

The comment needs a Cloudflare R2 bucket to host the images: the workflow's header says which
secrets and variables to set. Without them, the screenshots are only the run's artifact.

## Releasing

Every change to the app on `main` goes to TestFlight, and App Store releases are made by running
the release workflow, which also takes the App Store's screenshots. See
[RELEASING.md](RELEASING.md).

## Scripts

`scripts/generate-proto.sh` regenerates the protocol code from
`Packages/ClementineKit/Proto/remotecontrolmessages.proto`, and
`scripts/merge-transifex-translations.py` merges translations pulled from Transifex (see
[RELEASING.md](RELEASING.md#translations)). `scripts/import-android-translations.py` imported the
Android remote's translations, before the app was on Transifex.

## Licence

GNU GPL v3; see [LICENSE](LICENSE). The remote control protocol is under the Apache License 2.0.
