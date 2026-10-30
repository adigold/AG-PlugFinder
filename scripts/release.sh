#!/bin/bash
# Builds, signs (Developer ID), notarizes and staples AU Plugin Helper, then makes dist/AU-Plugin-Helper.dmg.
# Notarization sends the app to Apple. Uses the keychain profile "AU-PluginHelper".
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode-27.0.app/Contents/Developer
APP_NAME="AU Plugin Helper"
BUILD=build/release
rm -rf "$BUILD" dist && mkdir -p "$BUILD" dist

xcodegen generate >/dev/null
xcodebuild -project AUPluginHelper.xcodeproj -scheme AUPluginHelper -configuration Release \
  -derivedDataPath "$BUILD/dd" build | grep -E "error:|BUILD" || true
APP="$BUILD/dd/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q disable-library-validation

ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "AU-PluginHelper" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

STAGE="$BUILD/dmg" && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO dist/AU-Plugin-Helper.dmg >/dev/null
codesign --sign "Developer ID Application: Adi Goldstein (4HJV6RPCLU)" --timestamp dist/AU-Plugin-Helper.dmg
xcrun notarytool submit dist/AU-Plugin-Helper.dmg --keychain-profile "AU-PluginHelper" --wait
xcrun stapler staple dist/AU-Plugin-Helper.dmg
echo "Done: dist/AU-Plugin-Helper.dmg"
