#!/usr/bin/env bash
# Decides what the next App Store release is. Run by .github/workflows/release.yml, and
# runnable locally to see what the next release would be:
#
#   scripts/plan_release.sh [notes directory]
#
# A release is of main as it is now, and releases every commit since the last release (the
# newest v* tag before it). Its notes are those commits' "Release-note:" trailers: one line
# for users each, as in the Android remote. When none has one, the note is "Fixes and
# improvements."; with no commit at all since the last release, there's nothing to release.
#
# With TAG set (such as v1.1), plans that existing release again, to publish it after a failure.
#
# Prints key=value lines (for $GITHUB_OUTPUT):
#   release  true, or false when there's nothing to release
#   name     the version (scripts/version.sh)
#   build    the build number: the odd number after the commit's TestFlight builds
#   commit   the commit released
#   last     the previous release's tag; first=true when there's none
#   notes    the notes directory
# and writes, into the notes directory (default: a new temporary one):
#   notes.md           every note, for the GitHub release
#   release_notes.txt  the App Store's "What's New", cut to its 4000 characters
set -euo pipefail

cd "$(dirname "$0")/.."
notes_dir=${1:-$(mktemp -d)}
mkdir -p "$notes_dir"

if [ -n "${TAG:-}" ]; then
  git rev-parse -q --verify "refs/tags/$TAG" > /dev/null || { echo "::error::There's no tag $TAG." >&2; exit 1; }
  commit=$(git rev-parse "$TAG^{commit}")
  name=${TAG#v}
  since="$commit^"
else
  commit=$(git rev-parse "${MAIN:-origin/main}")
  since=$commit
fi
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$since" 2> /dev/null || true)
echo "last=$last"
[ -n "$last" ] || echo "first=true"

if [ -z "$(git rev-list ${last:+"$last.."}"$commit")" ]; then
  echo "release=false"
  exit 0
fi
[ -n "${name:-}" ] || name=$(scripts/version.sh "$commit" | sed -n 's/^name=//p')
build=$(( $(scripts/version.sh "$commit" | sed -n 's/^build=//p') + 1 ))

# The notes of every commit since then, oldest first, each once: the nightly translations
# commits (translations.yml) all have the same one.
notes=$(git log --reverse --format='%(trailers:key=Release-note,valueonly,separator=%x0A)' \
  ${last:+"$last.."}"$commit" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++')
[ -n "$notes" ] || notes="Fixes and improvements."

printf '%s\n' "$notes" | sed 's/^/- /' > "$notes_dir/notes.md"
# The App Store takes at most 4000 characters: whole notes, as many as fit, then a note that
# there's more.
more="- And more fixes and improvements."
: > "$notes_dir/release_notes.txt"
while IFS= read -r note; do
  line="- $note"
  if [ $(( $(wc -m < "$notes_dir/release_notes.txt") + ${#line} + ${#more} + 2 )) -gt 4000 ]; then
    echo "$more" >> "$notes_dir/release_notes.txt"
    break
  fi
  echo "$line" >> "$notes_dir/release_notes.txt"
done <<< "$notes"

echo "release=true"
echo "name=$name"
echo "build=$build"
echo "commit=$commit"
echo "notes=$notes_dir"
