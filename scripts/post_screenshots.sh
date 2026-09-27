#!/usr/bin/env bash
# Uploads a screenshots run's screenshots to the R2 bucket and, for a pull request, posts them
# on it next to main's. Run by .github/workflows/screenshots.yml; one comment per pull request,
# updated in place. The Android remote's scripts/post_screenshots.sh does the same for its app.
#
# Usage: post_screenshots.sh <screenshots dir> <pull request number | main>
#
# With main, the screenshots become main's, which later pull requests are compared with: the
# bucket's ios/main/latest names the folder they're in. Everything is under ios/, so the bucket
# can be the Android remote's.
#
# Needs: R2_ACCOUNT_ID, R2_BUCKET, R2_PUBLIC_URL, AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
# (the bucket-scoped R2 token), GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT,
# GITHUB_SERVER_URL, GH_TOKEN, and the AWS and GitHub CLIs.
set -euo pipefail
# Names in the order the screenshots were taken.
export LC_ALL=C

dir=$1
target=$2
marker='<!-- screenshots -->'

shopt -s nullglob
shots=("$dir"/*.png)
if [ ${#shots[@]} -eq 0 ]; then
  echo "No screenshots to post"
  exit 0
fi

r2() {
  AWS_DEFAULT_REGION=auto \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
  AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    aws s3 "$@" --endpoint-url "https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" --only-show-errors
}
public=${R2_PUBLIC_URL%/}

# Only a complete run replaces main's screenshots: a failure's would be missing screens.
if [ "$target" = main ] && { [ -e "$dir/failure.png" ] || [ -e "$dir/dark_failure.png" ]; }; then
  echo "Not replacing main's screenshots: the run failed"
  exit 0
fi

# A new folder per run, so GitHub's image cache never shows an earlier run's images. They're
# kept, so old comments keep their images.
if [ "$target" = main ]; then
  prefix="ios/main/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
else
  prefix="ios/pr-$target/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
fi
r2 cp "$dir" "s3://$R2_BUCKET/$prefix/" --recursive --exclude '*' --include '*.png' \
  --content-type image/png --cache-control 'public, max-age=2592000, immutable'
base="$public/$prefix"

if [ "$target" = main ]; then
  printf '%s\n' "$prefix" > "$RUNNER_TEMP/latest"
  r2 cp "$RUNNER_TEMP/latest" "s3://$R2_BUCKET/ios/main/latest" \
    --content-type text/plain --cache-control 'no-cache'
  echo "main's screenshots are now $base"
  exit 0
fi

# main's screenshots, if there are any yet.
main=
if latest=$(curl -fsS "$public/ios/main/latest?run=$GITHUB_RUN_ID" 2> /dev/null) && [ -n "$latest" ]; then
  main="$public/$latest"
fi
run="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

{
  echo "$marker"
  echo "### Screenshots"
  echo
  echo "From [run $GITHUB_RUN_ID]($run), against a real Clementine. Left: main. Right: this pull request, light and dark."
  echo
  echo "| Screen | main | This PR | This PR, dark |"
  echo "| --- | --- | --- | --- |"
  failures=()
  for shot in "${shots[@]}"; do
    name=$(basename "$shot" .png)
    case $name in
      # What a failing test left: the screen at the failure, in either appearance.
      failure | dark_failure)
        failures+=("$shot")
        continue
        ;;
      dark_*) continue ;;
    esac
    before="–"
    if [ -n "$main" ] && curl -fsSI "$main/$name.png" > /dev/null 2>&1; then
      before="<img src=\"$main/$name.png\" width=\"240\">"
    fi
    # The same screen in the dark theme, when the run took it (dark_<name>.png).
    if [ -f "$dir/dark_$name.png" ]; then
      dark="<img src=\"$base/dark_$name.png\" width=\"240\">"
    else
      dark="–"
    fi
    echo "| \`$name\` | $before | <img src=\"$base/$name.png\" width=\"240\"> | $dark |"
  done
  if [ ${#failures[@]} -gt 0 ]; then
    echo
    echo "#### Screens at a failure"
    echo
    for shot in "${failures[@]}"; do
      name=$(basename "$shot" .png)
      echo "\`$name\`<br><img src=\"$base/$name.png\" width=\"240\">"
      echo
    done
  fi
} > "$RUNNER_TEMP/screenshots-comment.md"

existing=$(gh api "repos/$GITHUB_REPOSITORY/issues/$target/comments" --paginate \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$marker\"))) | .id" \
  | head -n 1)
if [ -n "$existing" ]; then
  gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$existing" \
    -F "body=@$RUNNER_TEMP/screenshots-comment.md" > /dev/null
else
  gh api "repos/$GITHUB_REPOSITORY/issues/$target/comments" \
    -F "body=@$RUNNER_TEMP/screenshots-comment.md" > /dev/null
fi
