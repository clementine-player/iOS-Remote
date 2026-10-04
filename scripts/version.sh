#!/usr/bin/env bash
# The version and build number of a commit's upload to App Store Connect. Run by
# .github/workflows/testflight.yml and scripts/plan_release.sh:
#
#   scripts/version.sh [commit]    (default HEAD)
#
# Prints key=value lines (for $GITHUB_OUTPUT):
#   name   the version of the next App Store release: project.yml's MARKETING_VERSION (1.0),
#          or once that's released (tagged v1.0), the next unreleased of 1.1, 1.2, ... App Store
#          Connect takes no more builds of a version once it's released, so TestFlight builds carry
#          the version they'll be released as. For a major version, change MARKETING_VERSION to 2.0.
#   build  twice the commit's count of commits. TestFlight builds take it, and App Store releases
#          the odd number after it, so the two never collide and each upload's is higher than
#          the last, as in the Android remote.
set -euo pipefail

cd "$(dirname "$0")/.."
commit=${1:-HEAD}

base=$(git show "$commit:project.yml" | sed -n 's/^ *MARKETING_VERSION: "\{0,1\}\([0-9.]*\)"\{0,1\}$/\1/p')
[ -n "$base" ] || { echo "::error::Couldn't read MARKETING_VERSION from project.yml." >&2; exit 1; }
major=${base%%.*}
minor=0
[ "$base" = "$major" ] || minor=${base#*.}
name=$base
while git rev-parse -q --verify "refs/tags/v$name" > /dev/null; do
  minor=$((minor + 1))
  name="$major.$minor"
done

echo "name=$name"
echo "build=$(( 2 * $(git rev-list --count "$commit") ))"
