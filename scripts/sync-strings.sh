#!/bin/sh
# Brings App/Resources/Localizable.xcstrings up to date with the strings in the app's code, as
# Xcode does when it builds, but xcodebuild doesn't: strings the code has gained are added, and
# those it no longer has are marked stale. Run by scripts/build.sh after a build, from the
# .stringsdata files the compiler wrote for the app's and the widget's sources.
#
# The catalog is what goes to Transifex for translating (see RELEASING.md), so it's committed up
# to date: CI fails when a build changes it.
set -eu
cd "$(dirname "$0")/.."
intermediates=build/DerivedData/Build/Intermediates.noindex/ClementineRemote.build
set --
# The app's and the widget's, which share the catalog. Each from its latest build's folder: a
# simulator build and a device build each have their own, and each architecture's has every
# string.
for target in ClementineRemote ClementineWidget; do
    folders=$(find "$intermediates" -path "*/$target.build/Objects-normal/*" -name '*.stringsdata' 2>/dev/null \
        | sed 's|/[^/]*$||' | sort -u)
    if [ -z "$folders" ]; then
        echo "No strings found from a build of $target: run scripts/build.sh first." >&2
        exit 1
    fi
    # shellcheck disable=SC2086 # The folders' paths have no spaces.
    objects=$(ls -td $folders | head -n 1)
    for stringsdata in "$objects"/*.stringsdata; do
        set -- "$@" --stringsdata "$stringsdata"
    done
done
xcrun xcstringstool sync App/Resources/Localizable.xcstrings "$@"
