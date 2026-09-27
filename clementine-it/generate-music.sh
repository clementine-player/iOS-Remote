#!/bin/sh
# Generates the showcase library the screenshots show, from showcase-library.tsv: tagged Ogg
# Vorbis tracks of sine tones. The Android remote's clementine-it/generate-music.sh --showcase,
# so both apps show the same music.
#
#   generate-music.sh <dir>
#
# Needs ffmpeg.
set -eu

out=$1
# Homebrew's ffmpeg has no libvorbis; its own Vorbis encoder is experimental and stereo only,
# which is fine for a tone.
if ffmpeg -hide_banner -encoders 2> /dev/null | grep -q ' libvorbis '; then
  set -- -c:a libvorbis -q:a 0
else
  set -- -c:a vorbis -strict experimental -ac 2
fi
n=0
t=0
last_album=
grep -v '^#' "$(dirname "$0")/showcase-library.tsv" |
while IFS="$(printf '\t')" read -r artist album year title seconds; do
  n=$((n + 1))
  [ "$album" = "$last_album" ] || t=0
  last_album=$album
  t=$((t + 1))
  file="$out/$artist/$album/$(printf %02d "$t") $title.ogg"
  mkdir -p "$(dirname "$file")"
  # -nostdin: the loop reads its list on stdin, which ffmpeg would read too.
  ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=$((220 + n * 55)):duration=$seconds" \
    "$@" \
    -metadata artist="$artist" -metadata albumartist="$artist" -metadata composer="$artist" \
    -metadata album="$album" -metadata title="$title" -metadata track="$t" \
    -metadata date="$year" -metadata genre=Classical \
    "$file"
done
find "$out" -name '*.ogg' | sort
