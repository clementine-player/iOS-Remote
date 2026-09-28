#!/bin/bash
# Starts a real Clementine on macOS with the network remote on port 5500 and <music> as its
# library and its playlist, for the screenshots (.github/workflows/screenshots.yml). Clementine
# runs in the background, logging to <log>; this returns once it's ready.
#
# Remote streaming is on (--experimental-remote-streaming and "Allow playing on remote devices"),
# so the app can offer to play on the phone, and the screenshots show where Clementine can play.
#
#   start-clementine.sh <Clementine.app> <music dir> <log>
#
# It changes Clementine's settings and library for the user running it: meant for CI runners.
set -euo pipefail

app=$1
music=$2
log=$3
binary="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")"
# Where Qt keeps Clementine's settings (its organisation domain, clementine-player.org, reversed,
# then its name) and where Clementine keeps its database.
domain=org.clementine-player.Clementine
db="$HOME/Library/Application Support/Clementine/clementine.db"

mkdir -p "$(dirname "$log")"

wait_for() {
  local what=$1 check=$2
  for _ in $(seq 600); do
    if eval "$check"; then return 0; fi
    sleep 0.2
  done
  echo "Timed out waiting for $what" >&2
  return 1
}

# Run once so Clementine creates its database, then add the music as a library directory; it's
# scanned on the next start.
"$binary" > "$log.seed" 2>&1 &
pid=$!
wait_for "database schema" \
  "[ -f '$db' ] && sqlite3 '$db' 'select 1 from directories limit 1' > /dev/null 2>&1"
sleep 2
kill "$pid"
wait "$pid" || true
sqlite3 "$db" "insert into directories (path, subdirs) values ('$music', 1);"

# The network remote on 5500, reachable from the simulator, with downloads, and no auth code.
defaults write "$domain" NetworkRemote.use_remote -bool true
defaults write "$domain" NetworkRemote.port -int 5500
defaults write "$domain" NetworkRemote.only_non_public_ip -bool false
defaults write "$domain" NetworkRemote.use_auth_code -bool false
defaults write "$domain" NetworkRemote.allow_downloads -bool true
defaults write "$domain" NetworkRemote.convert_lossless -bool false
defaults write "$domain" NetworkRemote.allow_streaming -bool true
# The remote's CHANGE_SONG plays the song rather than queueing it.
defaults write "$domain" MainWindow.doubleclick_playlist_addmode -int 1

nohup "$binary" --verbose --experimental-remote-streaming > "$log" 2>&1 &
pid=$!
echo "$pid" > "$log.pid"
if ! wait_for "the network remote" "nc -z localhost 5500"; then
  echo "Clementine's settings:" >&2
  defaults read "$domain" >&2 || true
  tail -n 100 "$log" >&2
  exit 1
fi
tracks=$(find "$music" -name '*.ogg' | wc -l | tr -d ' ')
wait_for "the library scan" \
  "[ \"\$(sqlite3 '$db' 'select count(*) from songs where unavailable = 0' 2> /dev/null)\" = $tracks ]"

# Replace the playlist with the library, in path order, and leave it stopped (loading starts
# playback).
find "$music" -name '*.ogg' -print0 | sort -z | xargs -0 "$binary" --load > /dev/null 2>&1
sleep 1
"$binary" --stop > /dev/null 2>&1
echo "Clementine ready on port 5500"
