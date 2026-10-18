#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT_DIR"

swift run --configuration release -Xswiftc -Osize PerkyFeatureChecks

if [ -n "${PERKY_BUILD_TRIPLE:-}" ]; then
    swift build --configuration release -Xswiftc -Osize \
        --triple "$PERKY_BUILD_TRIPLE" --product Perky
    swift build --configuration release -Xswiftc -Osize \
        --triple "$PERKY_BUILD_TRIPLE" --product PerkyLidHelper
    BIN_DIR=$(swift build --configuration release --triple "$PERKY_BUILD_TRIPLE" --show-bin-path)
else
    swift build --configuration release -Xswiftc -Osize --product Perky
    swift build --configuration release -Xswiftc -Osize --product PerkyLidHelper
    BIN_DIR=$(swift build --configuration release --show-bin-path)
fi

APP_DIR="$ROOT_DIR/.build/Perky.app"
TEMP_DIR=$(mktemp -d "$ROOT_DIR/.build/Perky-build.XXXXXX")
STAGING_APP="$TEMP_DIR/Perky.app"
CONTENTS_DIR="$STAGING_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPER_PLIST_DIR="$CONTENTS_DIR/Library/LaunchDaemons"
BACKUP_APP="$TEMP_DIR/previous.app"

cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        find "$TEMP_DIR" -depth -delete
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$MACOS_DIR" "$HELPER_PLIST_DIR"
cp "$BIN_DIR/Perky" "$MACOS_DIR/Perky"
cp "$BIN_DIR/PerkyLidHelper" "$MACOS_DIR/PerkyLidHelper"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/com.perky.app.lid-helper.plist" \
    "$HELPER_PLIST_DIR/com.perky.app.lid-helper.plist"

if [ -n "${PERKY_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PERKY_VERSION" \
        "$CONTENTS_DIR/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${PERKY_BUILD_NUMBER:-$PERKY_VERSION}" \
        "$CONTENTS_DIR/Info.plist"
fi

# -Osize plus strip -x was measured on the final arm64 package and produces the
# smallest bundle. Keep Swift runtime symbols; strip only distributable copies.
strip -x "$MACOS_DIR/Perky" "$MACOS_DIR/PerkyLidHelper"

if [ -n "${PERKY_CODESIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$PERKY_CODESIGN_IDENTITY" \
        --identifier com.perky.app.lid-helper "$MACOS_DIR/PerkyLidHelper"
    codesign --force --options runtime --timestamp \
        --sign "$PERKY_CODESIGN_IDENTITY" "$STAGING_APP"
else
	printf '%s\n' "Warning: this ad-hoc app bundle cannot register its helper through Login Items." >&2
	printf '%s\n' "Use package-local-installer.sh to create a local admin-authorized installer for lid mode." >&2
    codesign --force --sign - \
        --identifier com.perky.app.lid-helper "$MACOS_DIR/PerkyLidHelper"
    codesign --force --sign - "$STAGING_APP"
fi

plutil -lint "$CONTENTS_DIR/Info.plist"
plutil -lint "$HELPER_PLIST_DIR/com.perky.app.lid-helper.plist"
codesign --verify --deep --strict "$STAGING_APP"

APP_ARCH=$(lipo -archs "$MACOS_DIR/Perky")
HELPER_ARCH=$(lipo -archs "$MACOS_DIR/PerkyLidHelper")
if [ "$APP_ARCH" != "$HELPER_ARCH" ]; then
    printf 'Architecture mismatch: app=%s helper=%s\n' "$APP_ARCH" "$HELPER_ARCH" >&2
    exit 1
fi

if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$BACKUP_APP"
fi
if ! mv "$STAGING_APP" "$APP_DIR"; then
    if [ -e "$BACKUP_APP" ]; then mv "$BACKUP_APP" "$APP_DIR"; fi
    exit 1
fi

printf 'Built %s (%s)\n' "$APP_DIR" "$APP_ARCH"
stat -f '%z bytes %N' "$APP_DIR/Contents/MacOS/Perky" \
    "$APP_DIR/Contents/MacOS/PerkyLidHelper"
du -sk "$APP_DIR"
