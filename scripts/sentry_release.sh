#!/usr/bin/env bash
# Creates the Sentry release of an archived build, with the commits it adds since the previous
# release. Run by .github/workflows/testflight.yml and release.yml, after the upload:
#
#   scripts/sentry_release.sh <archive>
#
# The release is named as Sentry's SDK names it in the app's crash reports: the bundle ID, version
# and build number, as in org.clementine-player.remote@1.0+322, read from the archive. A commit
# whose message says "Fixes CLEMENTINE-REMOTE-IOS-12" then resolves that issue in the first
# release with the commit, and Sentry reopens it if it crashes again in a later one. With Sentry's
# GitHub integration, issues also show the commits that might have caused them; without it,
# sentry-cli reads the commits from this checkout, which needs its whole history.
#
# Uses sentry-cli's SENTRY_AUTH_TOKEN, SENTRY_ORG and SENTRY_PROJECT. Without a token or a
# project it only says so, so builds without the repository's secrets still pass.
set -euo pipefail

archive=$1

if [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
  echo "::notice::No Sentry token or project, so no release in Sentry."
  exit 0
fi

plist="$archive/Info.plist"
property() { /usr/libexec/PlistBuddy -c "Print :ApplicationProperties:$1" "$plist"; }
release="$(property CFBundleIdentifier)@$(property CFBundleShortVersionString)+$(property CFBundleVersion)"
echo "Release: $release"

sentry() { uv run --only-group sentry sentry-cli "$@"; }
sentry releases new "$release"
# --ignore-missing: if the previous release's commit isn't in this history any more, take the
# last 20 commits rather than fail.
sentry releases set-commits "$release" --auto --ignore-missing
sentry releases finalize "$release"
