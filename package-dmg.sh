#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT_DIR"

APP_DIR=${1:-"$ROOT_DIR/.build/Perky.app"}
if [ ! -d "$APP_DIR" ]; then
    printf 'App bundle not found: %s\n' "$APP_DIR" >&2
    exit 1
fi

VERSION=${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")}
OUTPUT_DIR=${3:-"$ROOT_DIR/.build/release"}
ARCHS=$(lipo -archs "$APP_DIR/Contents/MacOS/Perky" | tr ' ' '-')
PACKAGE_BASENAME="Perky-$VERSION-macos-$ARCHS"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/perky-dmg.XXXXXX")

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$PACKAGE_BASENAME.dmg" \
    "$OUTPUT_DIR/$PACKAGE_BASENAME.zip" \
    "$OUTPUT_DIR/$PACKAGE_BASENAME.sha256"

ditto "$APP_DIR" "$STAGING_DIR/Perky.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Perky $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT_DIR/$PACKAGE_BASENAME.dmg"

ditto -c -k --sequesterRsrc --keepParent \
    "$APP_DIR" "$OUTPUT_DIR/$PACKAGE_BASENAME.zip"
(cd "$OUTPUT_DIR" && shasum -a 256 "$PACKAGE_BASENAME.dmg" "$PACKAGE_BASENAME.zip" > "$PACKAGE_BASENAME.sha256")

printf 'Packaged %s\n' "$PACKAGE_BASENAME"
du -h "$OUTPUT_DIR/$PACKAGE_BASENAME.dmg" \
    "$OUTPUT_DIR/$PACKAGE_BASENAME.zip" \
    "$OUTPUT_DIR/$PACKAGE_BASENAME.sha256"
