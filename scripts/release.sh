#!/bin/bash
# Release AU Plugin Helper: build, sign (Developer ID), notarize, staple, then make
#   dist/AU-Plugin-Helper-<version>.zip   the update the app downloads
#   dist/update.json                       the feed the app reads (version, size, sha256, notes)
#   dist/AU-Plugin-Helper.dmg              for a first install
# Usage: scripts/release.sh <version> [--skip-notarize]
# Notarizing uploads the app to Apple (keychain profile "AU-PluginHelper").
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version> [--skip-notarize]}"
SKIP_NOTARIZE="${2:-}"
export DEVELOPER_DIR=/Applications/Xcode-27.0.app/Contents/Developer
APP_NAME="AU Plugin Helper"
NOTES="release-notes/$VERSION.md"
BUILD=build/release

# Release notes: required, outcome-only, no dashes.
[ -f "$NOTES" ] || { echo "Write $NOTES first (see release-notes/README.md)"; exit 1; }
if grep -q -- '--\|—' "$NOTES"; then echo "$NOTES contains a dash pair or em dash"; exit 1; fi

FEED=$(grep -E '^\s+AUPHUpdateFeedURL:' project.yml | sed -E 's/.*: *"?([^"]*)"?/\1/')
[ -n "$FEED" ] || echo "Warning: AUPHUpdateFeedURL is empty in project.yml, this build will not check for updates."
BASE="${FEED%/*}"

BUILDNUM=$(echo "$VERSION" | awk -F. '{print $1*1000000 + $2*1000 + $3}')
rm -rf "$BUILD" && mkdir -p "$BUILD" dist
xcodegen generate >/dev/null
xcodebuild -project AUPluginHelper.xcodeproj -scheme AUPluginHelper -configuration Release \
  -derivedDataPath "$BUILD/dd" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILDNUM" \
  build | grep -E "error:|BUILD" || true
APP="$BUILD/dd/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$SKIP_NOTARIZE" != "--skip-notarize" ]; then
  ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
  xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "AU-PluginHelper" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

ZIP="dist/AU-Plugin-Helper-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SIZE=$(stat -f%z "$ZIP")
python3 - "$VERSION" "$BASE/$(basename "$ZIP")" "$SHA" "$SIZE" "$NOTES" > dist/update.json <<'PY'
import json, sys
version, url, sha, size, notes = sys.argv[1:]
lines = [l.strip()[2:].strip() for l in open(notes) if l.strip().startswith("- ")]
print(json.dumps({"version": version, "url": url, "sha256": sha, "size": int(size),
                  "notes": lines, "minOS": "15.0"}, indent=2))
PY

STAGE="$BUILD/dmg" && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO dist/AU-Plugin-Helper.dmg >/dev/null
codesign --sign "Developer ID Application: Adi Goldstein (4HJV6RPCLU)" --timestamp dist/AU-Plugin-Helper.dmg
if [ "$SKIP_NOTARIZE" != "--skip-notarize" ]; then
  xcrun notarytool submit dist/AU-Plugin-Helper.dmg --keychain-profile "AU-PluginHelper" --wait
  xcrun stapler staple dist/AU-Plugin-Helper.dmg
fi
echo "Done. Upload $ZIP and dist/update.json to $BASE/ (zip first, then update.json)."
