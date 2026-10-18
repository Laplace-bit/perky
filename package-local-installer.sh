#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT_DIR"

APP_DIR=${1:-"$ROOT_DIR/.build/Perky.app"}
if [ ! -d "$APP_DIR" ]; then
	printf 'App bundle not found: %s\n' "$APP_DIR" >&2
	exit 1
fi
if xattr -lr "$APP_DIR" 2>/dev/null | grep -Fq 'com.apple.quarantine'; then
	printf '%s\n' "Refusing to package a quarantined app; review and approve its source first." >&2
	exit 1
fi

VERSION=${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")}
OUTPUT_DIR=${3:-"$ROOT_DIR/.build/packages"}
ARCHS=$(lipo -archs "$APP_DIR/Contents/MacOS/Perky" | tr ' ' '-')
PACKAGE_BASENAME="Perky-$VERSION-macos-$ARCHS-local"
PACKAGE_PATH="$OUTPUT_DIR/$PACKAGE_BASENAME.pkg"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/perky-local-pkg.XXXXXX")

cleanup() {
	if [ -d "$STAGING_DIR" ]; then
		find "$STAGING_DIR" -depth -delete
	fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

PAYLOAD_ROOT="$STAGING_DIR/payload"
SCRIPTS_DIR="$STAGING_DIR/scripts"
COMPONENT_PLIST="$STAGING_DIR/components.plist"
STAGED_APP="$PAYLOAD_ROOT/Applications/Perky.app"
mkdir -p "$STAGED_APP/Contents/Resources" "$PAYLOAD_ROOT/Library/LaunchDaemons" "$SCRIPTS_DIR"
mkdir -p "$PAYLOAD_ROOT/Library/PrivilegedHelperTools"
ditto --norsrc "$APP_DIR" "$STAGED_APP"
ditto --norsrc "$APP_DIR/Contents/MacOS/PerkyLidHelper" \
	"$PAYLOAD_ROOT/Library/PrivilegedHelperTools/com.perky.app.lid-helper"
chmod 755 "$PAYLOAD_ROOT/Library/PrivilegedHelperTools/com.perky.app.lid-helper"
ditto --norsrc "$ROOT_DIR/Scripts/uninstall-local-package.sh" \
	"$STAGED_APP/Contents/Resources/uninstall-local-package.sh"
chmod 755 "$STAGED_APP/Contents/Resources/uninstall-local-package.sh"
ditto --norsrc "$ROOT_DIR/com.perky.app.lid-helper.local.plist" \
	"$PAYLOAD_ROOT/Library/LaunchDaemons/com.perky.app.lid-helper.plist"
ditto --norsrc "$ROOT_DIR/Scripts/local-package-preinstall" "$SCRIPTS_DIR/preinstall"
ditto --norsrc "$ROOT_DIR/Scripts/local-package-postinstall" "$SCRIPTS_DIR/postinstall"
chmod 755 "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"

/usr/libexec/PlistBuddy -c 'Add :PerkyLocalAdminInstall bool true' \
	"$STAGED_APP/Contents/Info.plist"
codesign --force --sign - --identifier com.perky.app "$STAGED_APP"
plutil -lint "$STAGED_APP/Contents/Info.plist" \
	"$PAYLOAD_ROOT/Library/LaunchDaemons/com.perky.app.lid-helper.plist"
codesign --verify --deep --strict "$STAGED_APP"

pkgbuild --analyze --root "$PAYLOAD_ROOT" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$COMPONENT_PLIST"

mkdir -p "$OUTPUT_DIR"
pkgbuild \
	--root "$PAYLOAD_ROOT" \
	--component-plist "$COMPONENT_PLIST" \
	--scripts "$SCRIPTS_DIR" \
	--install-location / \
	--ownership recommended \
	--identifier com.perky.app.local-installer \
	--version "$VERSION" \
	"$PACKAGE_PATH"

(cd "$OUTPUT_DIR" && shasum -a 256 "$PACKAGE_BASENAME.pkg" > "$PACKAGE_BASENAME.pkg.sha256")
printf 'Built local-only installer %s\n' "$PACKAGE_PATH"
printf '%s\n' "No Developer ID, Apple certificate, or notarization is used."
du -h "$PACKAGE_PATH" "$PACKAGE_PATH.sha256"
