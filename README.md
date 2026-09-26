# Clementine Remote for iOS

Clementine Remote controls the [Clementine](https://www.clementine-player.org/) music player on
your computer from your iPhone or iPad, over your local network. It does what the
[Android remote](https://github.com/clementine-player/Android-Remote) does: play and pause, browse
and search your library, manage playlists, read lyrics, rate songs, and download songs to your
phone.

You need Clementine 1.3 or later, with Tools → Preferences → Network Remote turned on.

The design is in [design/DESIGN.md](design/DESIGN.md).

## Building

Needs Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/build.sh          # regenerate the Xcode project and build for the simulator
scripts/build.sh test     # run the tests
```

The Xcode project is generated from `project.yml`; after changing that file, run
`xcodegen generate`. `ClementineKit` (in `Packages/`) holds everything that doesn't need a screen,
and its tests also run with `swift test`.

`scripts/generate-proto.sh` regenerates the protocol code from
`Packages/ClementineKit/Proto/remotecontrolmessages.proto`, and
`scripts/import-android-translations.py` imports the Android remote's translations.

## Licence

GNU GPL v3; see [LICENSE](LICENSE). The remote control protocol is under the Apache License 2.0.
