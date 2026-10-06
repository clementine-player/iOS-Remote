#!/bin/sh
# Regenerates the Xcode project, builds the app for the simulator, and brings the String Catalog
# up to date with the app's strings (scripts/sync-strings.sh).
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project ClementineRemote.xcodeproj -scheme ClementineRemote \
    -destination "${DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}" \
    -derivedDataPath build/DerivedData "${@:-build}"
scripts/sync-strings.sh
