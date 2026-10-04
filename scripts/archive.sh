#!/usr/bin/env bash
# Builds the app for App Store Connect: an archive, exported as an .ipa signed for distribution.
# Run by .github/workflows/testflight.yml and release.yml:
#
#   scripts/archive.sh <version> <build number> <output dir>
#
# It writes <output dir>/ClementineRemote.ipa, and the archive beside it.
#
# There's no certificate on the runner. The archive is built unsigned, and signed as it's
# exported by Xcode's cloud signing (-allowProvisioningUpdates), with a distribution certificate
# Apple keeps. Signing the archive itself would need a development certificate: a new one on
# every run. Exporting keeps the entitlements the bundles were signed with, though, and unsigned
# they have none, so first the app and the widget are signed ad hoc with their own (the app
# group they share).
#
# With ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (an App Store Connect API key, as on CI),
# Xcode signs in with that key; without them, with the Apple account signed in to Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$1
build=$2
out=$3
archive="$out/ClementineRemote.xcarchive"

auth=(-allowProvisioningUpdates)
if [ -n "${ASC_KEY_ID:-}" ]; then
  auth+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

xcodegen generate --quiet
rm -rf "$archive"
mkdir -p "$out"
xcodebuild archive -project ClementineRemote.xcodeproj -scheme ClementineRemote \
  -destination generic/platform=iOS -archivePath "$archive" \
  -derivedDataPath build/DerivedData-archive \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" CODE_SIGNING_ALLOWED=NO

# Each bundle's entitlements, with the build settings they use filled in: the extension first,
# as signing the app seals what's inside it.
settings=$(xcodebuild -project ClementineRemote.xcodeproj -scheme ClementineRemote \
  -configuration Release -showBuildSettings 2> /dev/null)
app_group=$(sed -n 's/^ *APP_GROUP = //p' <<< "$settings" | head -n 1)
[ -n "$app_group" ] || { echo "Couldn't read APP_GROUP from the build settings" >&2; exit 1; }
app="$archive/Products/Applications/Clementine Remote.app"
sign() {
  local bundle=$1 entitlements=$2
  sed "s/\$(APP_GROUP)/$app_group/g" "$entitlements" > "$out/entitlements.plist"
  codesign --force --sign - --entitlements "$out/entitlements.plist" "$bundle"
}
sign "$app/PlugIns/ClementineWidget.appex" Widget/ClementineWidget.entitlements
sign "$app" App/ClementineRemote.entitlements
rm "$out/entitlements.plist"

cat > "$out/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$(sed -n 's/^ *DEVELOPMENT_TEAM = //p' <<< "$settings" | head -n 1)</string>
  <!-- The version and build number are this script's. -->
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
EOF
rm -rf "$out/export"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions.plist" \
  -exportPath "$out/export" "${auth[@]}"
mv "$out/export/"*.ipa "$out/ClementineRemote.ipa"
rm -rf "$out/export"
echo "Built $out/ClementineRemote.ipa: $version ($build)"
