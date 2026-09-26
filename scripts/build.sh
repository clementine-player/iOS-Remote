#!/bin/sh
# Regenerates the Xcode project and builds the app for the simulator.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project ClementineRemote.xcodeproj -scheme ClementineRemote \
    -destination "${DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}" \
    -derivedDataPath build/DerivedData "${@:-build}"
