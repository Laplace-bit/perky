#!/bin/sh
set -eu

APP_PATH="/Applications/Perky.app"
HELPER_PATH="/Library/PrivilegedHelperTools/com.perky.app.lid-helper"
LAUNCH_DAEMON_PATH="/Library/LaunchDaemons/com.perky.app.lid-helper.plist"
SERVICE_LABEL="com.perky.app.lid-helper"
HELPER_PROCESS_PATTERN='^/Library/PrivilegedHelperTools/com\.perky\.app\.lid-helper --perky-local-admin-install$'
STATE_DIRECTORY="/Library/Application Support/Perky"
STATE_PATH="$STATE_DIRECTORY/local-install.plist"
INSTALL_PENDING_PATH="$STATE_DIRECTORY/install.pending"
RECOVERY_PATH="$STATE_DIRECTORY/lid-recovery.plist"
ROLLBACK_DIRECTORY="$STATE_DIRECTORY/upgrade-rollback"
SESSION_LOCK_PATH="$STATE_DIRECTORY/session.lock"
UNINSTALL_PENDING_PATH="$STATE_DIRECTORY/uninstall.pending"

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf '%s\n' "Run Perky's uninstaller with administrator privileges, for example: sudo /Applications/Perky.app/Contents/Resources/uninstall-local-package.sh" >&2
	exit 1
fi
if [ -L "$STATE_DIRECTORY" ] || { [ -e "$STATE_DIRECTORY" ] && [ ! -d "$STATE_DIRECTORY" ]; }; then
	printf '%s\n' "Perky's protected state directory is not a regular directory. No files were removed." >&2
	exit 1
fi
if [ ! -d "$STATE_DIRECTORY" ] \
	|| [ "$(/usr/bin/stat -f '%u' "$STATE_DIRECTORY")" -ne 0 ] \
	|| [ "$(/usr/bin/stat -f '%Lp' "$STATE_DIRECTORY")" != "700" ]; then
	printf '%s\n' "Perky's protected state directory has unexpected ownership or permissions. No files were removed." >&2
	exit 1
fi

# Serialize uninstall with startSession. The helper uses BSD flock on this
# same inode before it can create a recovery record or change system power policy.
if [ -L "$SESSION_LOCK_PATH" ] || { [ -e "$SESSION_LOCK_PATH" ] && [ ! -f "$SESSION_LOCK_PATH" ]; }; then
	printf '%s\n' "Perky's session lock is not a regular file. No files were removed." >&2
	exit 1
fi
if [ ! -e "$SESSION_LOCK_PATH" ]; then
	/usr/bin/install -o root -g wheel -m 600 /dev/null "$SESSION_LOCK_PATH"
fi
if [ "$(/usr/bin/stat -f '%u' "$SESSION_LOCK_PATH")" -ne 0 ] \
	|| [ "$(/usr/bin/stat -f '%Lp' "$SESSION_LOCK_PATH")" != "600" ]; then
	printf '%s\n' "Perky's session lock has unexpected ownership or permissions. No files were removed." >&2
	exit 1
fi

case "${1:-}" in
	"") exec /usr/bin/lockf -k "$SESSION_LOCK_PATH" /bin/sh "$0" --locked ;;
	--locked) ;;
	*) printf '%s\n' "Unexpected uninstaller argument. No files were removed." >&2; exit 1 ;;
esac

STATE_TEMP=""
PENDING_CREATED=0
SERVICE_DISABLED=0
UNINSTALL_COMPLETE=0

restore_service_after_abort() {
	[ "$SERVICE_DISABLED" -eq 1 ] || return 0
	/bin/launchctl enable "system/$SERVICE_LABEL" >/dev/null 2>&1 || return 1
	if ! /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 \
		&& [ -f "$LAUNCH_DAEMON_PATH" ] && [ -x "$HELPER_PATH" ]; then
		/bin/launchctl bootstrap system "$LAUNCH_DAEMON_PATH" >/dev/null 2>&1 || return 1
	fi
	attempt=0
	while [ "$attempt" -lt 10 ]; do
		if /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1 \
			&& /usr/bin/pgrep -f "$HELPER_PROCESS_PATTERN" >/dev/null 2>&1; then return 0; fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

on_exit() {
	STATUS=$?
	trap - EXIT HUP INT TERM
	if [ -n "$STATE_TEMP" ]; then /bin/rm -f "$STATE_TEMP" || true; fi
	if [ "$UNINSTALL_COMPLETE" -ne 1 ]; then
		if [ "$SERVICE_DISABLED" -eq 1 ] && ! restore_service_after_abort; then
			printf '%s\n' "Perky could not confirm that its recovery helper restarted. Keep this Mac awake and inspect its LaunchDaemon." >&2
		else
			if [ "$PENDING_CREATED" -eq 1 ]; then /bin/rm -f "$UNINSTALL_PENDING_PATH" || true; fi
		fi
	fi
	exit "$STATUS"
}
trap on_exit EXIT
trap 'exit 1' HUP INT TERM

for protected_path in \
	"$APP_PATH" \
	"$HELPER_PATH" \
	"$LAUNCH_DAEMON_PATH" \
	"$STATE_PATH" \
	"$INSTALL_PENDING_PATH" \
	"$RECOVERY_PATH" \
	"$ROLLBACK_DIRECTORY" \
	"$UNINSTALL_PENDING_PATH"; do
	if [ -L "$protected_path" ]; then
		printf 'Refusing to remove a symbolic link at %s\n' "$protected_path" >&2
		exit 1
	fi
	if [ -e "$protected_path" ] && [ "$(/usr/bin/stat -f '%u' "$protected_path")" -ne 0 ]; then
		printf 'Refusing to remove a path not owned by root: %s\n' "$protected_path" >&2
		exit 1
	fi
done

if [ -e "$INSTALL_PENDING_PATH" ] || [ -L "$INSTALL_PENDING_PATH" ]; then
	printf '%s\n' "Perky is being installed or repaired. Finish the installer before uninstalling." >&2
	exit 1
fi
if [ -e "$RECOVERY_PATH" ]; then
	printf '%s\n' "Perky still has a system recovery record. Stop the session in Perky and wait for recovery to finish before uninstalling." >&2
	exit 1
fi
if [ -e "$ROLLBACK_DIRECTORY" ]; then
	printf '%s\n' "Perky has an unfinished upgrade rollback snapshot. Reinstall or repair Perky before uninstalling." >&2
	exit 1
fi
if /usr/bin/pgrep -x Perky >/dev/null 2>&1; then
	printf '%s\n' "Quit Perky before uninstalling." >&2
	exit 1
fi

# A root-owned gate blocks sessions queued while this installer holds the lock.
if [ -e "$UNINSTALL_PENDING_PATH" ]; then
	if [ ! -f "$UNINSTALL_PENDING_PATH" ] \
		|| [ "$(/usr/bin/stat -f '%u' "$UNINSTALL_PENDING_PATH")" -ne 0 ] \
		|| [ "$(/usr/bin/stat -f '%Lp' "$UNINSTALL_PENDING_PATH")" != "600" ]; then
		printf '%s\n' "Perky's uninstall gate has unexpected ownership or permissions. No files were removed." >&2
		exit 1
	fi
else
	PENDING_CREATED=1
	STATE_TEMP=$(/usr/bin/mktemp "$STATE_DIRECTORY/.uninstall.pending.XXXXXX")
	/usr/sbin/chown root:wheel "$STATE_TEMP"
	/bin/chmod 600 "$STATE_TEMP"
	/bin/mv -f "$STATE_TEMP" "$UNINSTALL_PENDING_PATH"
	STATE_TEMP=""
fi
PENDING_CREATED=1

# Check again under the session lock and gate before stopping the recovery daemon.
if [ -e "$RECOVERY_PATH" ] || [ -L "$RECOVERY_PATH" ]; then
	printf '%s\n' "Perky has a system recovery record. No files were removed; its recovery helper will remain available." >&2
	exit 1
fi

SERVICE_DISABLED=1
if ! /bin/launchctl disable "system/$SERVICE_LABEL"; then
	printf '%s\n' "Could not disable Perky's recovery helper. No files were removed." >&2
	exit 1
fi
if /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
	if ! /bin/launchctl bootout "system/$SERVICE_LABEL"; then
		printf '%s\n' "Could not stop Perky's recovery helper. No files were removed." >&2
		exit 1
	fi
fi
if /bin/launchctl print "system/$SERVICE_LABEL" >/dev/null 2>&1; then
	printf '%s\n' "Perky's recovery helper is still loaded. No files were removed." >&2
	exit 1
fi
attempt=0
while /usr/bin/pgrep -f "$HELPER_PROCESS_PATTERN" >/dev/null 2>&1 && [ "$attempt" -lt 15 ]; do
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if /usr/bin/pgrep -f "$HELPER_PROCESS_PATTERN" >/dev/null 2>&1; then
	printf '%s\n' "Perky's recovery helper process is still exiting. No files were removed." >&2
	exit 1
fi
if [ -e "$RECOVERY_PATH" ] || [ -L "$RECOVERY_PATH" ]; then
	printf '%s\n' "A recovery record appeared while stopping Perky. No files were removed; its helper will be restarted." >&2
	exit 1
fi

for path_to_remove in "$LAUNCH_DAEMON_PATH" "$HELPER_PATH" "$STATE_PATH"; do
	if [ -e "$path_to_remove" ]; then /bin/rm -f "$path_to_remove"; fi
done
if [ -d "$APP_PATH" ]; then /bin/rm -rf "$APP_PATH"; fi
# Keep the root-owned lock inode across uninstall/reinstall cycles. A package
# installer may already be waiting on it; unlinking it would let postinstall
# lock a different inode and strand the install marker.
if [ -e "$UNINSTALL_PENDING_PATH" ]; then /bin/rm -f "$UNINSTALL_PENDING_PATH"; fi
UNINSTALL_COMPLETE=1

printf '%s\n' "Perky's app and recovery helper have been removed."
