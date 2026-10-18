#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT_DIR"

swift build --configuration release --product Perky
swift build --configuration release --product PerkyLidHelper

APP_DIR="$ROOT_DIR/.build/Perky.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

mkdir -p "$MACOS_DIR"
mkdir -p "$CONTENTS_DIR/Library/LaunchDaemons"
cp "$ROOT_DIR/.build/release/Perky" "$MACOS_DIR/Perky"
cp "$ROOT_DIR/.build/release/PerkyLidHelper" "$MACOS_DIR/PerkyLidHelper"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/com.perky.app.lid-helper.plist" "$CONTENTS_DIR/Library/LaunchDaemons/com.perky.app.lid-helper.plist"

if [ -n "${PERKY_CODESIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$PERKY_CODESIGN_IDENTITY" --identifier com.perky.app.lid-helper "$MACOS_DIR/PerkyLidHelper"
    codesign --force --options runtime --timestamp --sign "$PERKY_CODESIGN_IDENTITY" "$APP_DIR"
else
    printf '%s\n' "Warning: this ad-hoc build can run Perky's basic mode, but macOS will not authorize its privileged lid helper." >&2
    printf '%s\n' "Set PERKY_CODESIGN_IDENTITY to an Apple-trusted signing identity before registering the helper." >&2
    codesign --force --sign - --identifier com.perky.app.lid-helper "$MACOS_DIR/PerkyLidHelper"
    codesign --force --sign - "$APP_DIR"
fi

printf 'Built %s\n' "$APP_DIR"
