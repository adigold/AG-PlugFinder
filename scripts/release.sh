#!/bin/bash
# Release AG PlugFinder: build, sign (Developer ID), notarize, staple, then make
#   dist/AG-PlugFinder-<version>.zip   the update the app downloads
#   dist/update.json                       the feed the app reads (version, size, sha256, notes)
#   dist/AG-PlugFinder.dmg              for a first install
# Usage: scripts/release.sh <version> [--skip-notarize] [--publish]
# Notarizing uploads the app to Apple (keychain profile "AU-PluginHelper").
# --publish also creates the GitHub release in $REPO (public,
# release files only, no code). Every installed copy then sees the update within 6 hours.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version> [--skip-notarize] [--publish]}"
SKIP_NOTARIZE=""; PUBLISH=""
for a in "${@:2}"; do
  case "$a" in --skip-notarize) SKIP_NOTARIZE="--skip-notarize";; --publish) PUBLISH=1;; esac
done
REPO="adigold/AG-PlugFinder"
[ -n "$PUBLISH" ] && [ -n "$SKIP_NOTARIZE" ] && { echo "Refusing to publish a build that is not notarized"; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode-27.0.app/Contents/Developer
APP_NAME="AG PlugFinder"
NOTES="release-notes/$VERSION.md"
BUILD=build/release

# Release notes: required, outcome-only, no dashes.
[ -f "$NOTES" ] || { echo "Write $NOTES first (see release-notes/README.md)"; exit 1; }
if grep -q -- '--\|—' "$NOTES"; then echo "$NOTES contains a dash pair or em dash"; exit 1; fi

DOWNLOAD_BASE="https://github.com/$REPO/releases/download/v$VERSION"

BUILDNUM=$(echo "$VERSION" | awk -F. '{print $1*1000000 + $2*1000 + $3}')
rm -rf "$BUILD" && mkdir -p "$BUILD" dist
xcodegen generate >/dev/null
# The shared plugin database key lives only in server/.env.local (gitignored), never in the repo.
AGPF_UPLOAD_KEY=$(grep "^UPLOAD_KEY=" server/.env.local 2>/dev/null | cut -d= -f2)
xcodebuild -project AGPlugFinder.xcodeproj -scheme AGPlugFinder -configuration Release \
  AGPF_UPLOAD_KEY="$AGPF_UPLOAD_KEY" -derivedDataPath "$BUILD/dd" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILDNUM" \
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

ZIP="dist/AG-PlugFinder-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SIZE=$(stat -f%z "$ZIP")
python3 - "$VERSION" "$DOWNLOAD_BASE/$(basename "$ZIP")" "$SHA" "$SIZE" "$NOTES" > dist/update.json <<'PY'
import json, sys
version, url, sha, size, notes = sys.argv[1:]
lines = [l.strip()[2:].strip() for l in open(notes) if l.strip().startswith("- ")]
print(json.dumps({"version": version, "url": url, "sha256": sha, "size": int(size),
                  "notes": lines, "minOS": "15.0"}, indent=2))
PY

# Plugin pack (BL-22): every picture and description on this Mac, so new installs can download
# them instead of capturing every plugin. Logic's own pictures are already inside the app.
PACK="$BUILD/pack" && rm -rf "$PACK" && mkdir -p "$PACK/screenshots"
SHOTS="$HOME/Library/Application Support/AG PlugFinder/Screenshots"
for f in "$SHOTS"/*.png; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in logic-*) continue;; esac
  sips -s format jpeg -s formatOptions 80 "$f" --out "$PACK/screenshots/$(basename "${f%.png}").jpg" >/dev/null
done
python3 - "$HOME/Library/Application Support/AG PlugFinder/catalog.json" > "$PACK/info.json" <<'PY2'
import json, sys
plugins = json.load(open(sys.argv[1]))
print(json.dumps({p["id"]: p["details"] for p in plugins if p.get("details")}))
PY2
rm -f dist/plugin-pack.zip && ditto -c -k "$PACK" dist/plugin-pack.zip
echo "Plugin pack: $(ls "$PACK/screenshots" | wc -l | tr -d ' ') pictures, $(du -h dist/plugin-pack.zip | cut -f1)"

STAGE="$BUILD/dmg" && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO dist/AG-PlugFinder.dmg >/dev/null
codesign --sign "Developer ID Application: Adi Goldstein (4HJV6RPCLU)" --timestamp dist/AG-PlugFinder.dmg
if [ "$SKIP_NOTARIZE" != "--skip-notarize" ]; then
  xcrun notarytool submit dist/AG-PlugFinder.dmg --keychain-profile "AU-PluginHelper" --wait
  xcrun stapler staple dist/AG-PlugFinder.dmg
fi
if [ -n "$PUBLISH" ]; then
  VIS=$(gh repo view "$REPO" --json visibility --jq .visibility 2>/dev/null || echo MISSING)
  if [ "$VIS" != "PUBLIC" ]; then
    echo "Not published: $REPO is $VIS. Installed apps can only download updates from a public repo."
    exit 1
  fi
  gh release create "v$VERSION" "$ZIP" dist/update.json dist/AG-PlugFinder.dmg dist/plugin-pack.zip \
    --repo "$REPO" --title "AG PlugFinder $VERSION" --notes-file "$NOTES" --latest
  echo "Published v$VERSION to https://github.com/$REPO/releases"
  # Homebrew: point the cask in adigold/homebrew-tap at this version's installer.
  DMG_SHA=$(shasum -a 256 dist/AG-PlugFinder.dmg | cut -d' ' -f1)
  TAP_DIR=$(mktemp -d)
  gh repo clone adigold/homebrew-tap "$TAP_DIR/tap" -- -q
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$DMG_SHA\"/" "$TAP_DIR/tap/Casks/ag-plugfinder.rb"
  git -C "$TAP_DIR/tap" commit -qam "AG PlugFinder $VERSION" && git -C "$TAP_DIR/tap" push -q
  echo "Homebrew cask updated to $VERSION"
else
  echo "Built. Nothing uploaded. Run again with --publish to release v$VERSION."
fi
