#!/bin/bash
#
# Builds Siiv and puts it in a disk image ready to publish.
# Usage: scripts/package.sh [output-directory]
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Siiv"
OUT_DIR="${1:-dist}"
BUILD_DIR="$(mktemp -d)"
STAGE_DIR="$(mktemp -d)"
APP=""

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/\
LaunchServices.framework/Support/lsregister

cleanup() {
    # macOS registers every app bundle it notices, this throwaway build
    # included. Left behind, those registrations outlive the folder and can
    # shadow the copy you actually installed, which shows up as an old icon
    # or an old build launching. Drop them before the folder goes.
    for stray in "$APP" "$STAGE_DIR/$APP_NAME.app"; do
        [ -n "$stray" ] && [ -d "$stray" ] && "$LSREGISTER" -u "$stray" 2>/dev/null
    done
    rm -rf "$BUILD_DIR" "$STAGE_DIR"
}
trap cleanup EXIT

# Xcode proper is needed; the command line tools alone cannot build an app.
if ! xcodebuild -version > /dev/null 2>&1; then
    if [ -d /Applications/Xcode.app ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        echo "Xcode is needed to build Siiv. Install it from the App Store." >&2
        exit 1
    fi
fi

VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' \
    "$APP_NAME.xcodeproj/project.pbxproj" | head -1)"
VERSION="${VERSION:-0.0.0}"
DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"

echo "Building ${APP_NAME} ${VERSION}…"
# Signed ad-hoc: enough for the app to run, no Apple developer account needed.
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
    build > "$BUILD_DIR/build.log" 2>&1 ||
    { echo "Build failed:" >&2; tail -20 "$BUILD_DIR/build.log" >&2; exit 1; }

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

echo "Packing the disk image…"
mkdir -p "$OUT_DIR"
cp -R "$APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" \
    -ov -format UDZO "$DMG" > /dev/null

echo "Done: $DMG"
