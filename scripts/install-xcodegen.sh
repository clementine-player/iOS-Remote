#!/bin/sh
# Installs the XcodeGen release CI generates the Xcode project with, and puts it on the PATH of
# the job's later steps. Pinned, because a new XcodeGen can change what it generates (2.47 changed
# the default LastUpgradeCheck and schemes' buildArchitectures), and the committed project has to
# match. To move to another release, change both lines below, run that XcodeGen locally, and commit
# the regenerated project with it.
set -eu
version=2.48.0
sha256=620c9f0dc10849f94728ab5df52d225ebab8187439dd6fee1925e59e80dff892

dir="${RUNNER_TEMP:-$(mktemp -d)}/xcodegen-$version"
mkdir -p "$dir"
curl --fail --silent --show-error --location --retry 3 --output "$dir/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
echo "$sha256  $dir/xcodegen.zip" | shasum -a 256 -c -
unzip -q -o "$dir/xcodegen.zip" -d "$dir"
"$dir/xcodegen/bin/xcodegen" --version
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$dir/xcodegen/bin" >> "$GITHUB_PATH"
fi
