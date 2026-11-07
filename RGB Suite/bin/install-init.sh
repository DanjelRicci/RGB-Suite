#!/bin/sh
# install-init.sh - arm (or remove) RGB Suite's boot persistence.
#
# Writes a tiny boot hook into muOS's user-init dir that starts the always-on
# rgb_suite daemon at boot, then starts it now so no reboot is needed. The hook
# points back at THIS install's rgbctl.sh (single source of truth), so app
# updates take effect automatically. Idempotent - safe to run on every launch
# (e.g. from mux_launch.sh).
#
#   install-init.sh          install the boot hook + start the daemon
#   install-init.sh remove   remove the boot hook + stop the daemon
#
# NOTE: muOS only runs these at boot when the "User init scripts" advanced
# setting is enabled.

APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"

# Resolve muOS's ACTUAL user-init dir. muOS's own user_init.sh scans
# "$MUOS_STORE_DIR/init", and Storage Options bind that path to whichever card
# (SD1/SD2) the user relocated it to - so writing here always lands where muOS
# looks, regardless of the SD choice. Resolve MUOS_STORE_DIR in a SUBSHELL so
# func.sh's side effects can't leak into this installer. Fall back to the
# well-known path.
STORE="$( . /opt/muos/script/var/func.sh 2>/dev/null; printf '%s' "${MUOS_STORE_DIR:-/run/muos/storage}" )"
[ -n "$STORE" ] || STORE="/run/muos/storage"
INIT_DIR="$STORE/init"
INIT_HOOK="$INIT_DIR/rgb_suite.sh"

case "${1:-install}" in
	remove)
		rm -f "$INIT_HOOK"
		"$APP_DIR/bin/rgbctl.sh" stop
		;;
	install)
		mkdir -p "$INIT_DIR" 2>/dev/null

		# Bake this install's absolute path into the hook (works on mmc or sd).
		cat >"$INIT_HOOK" <<EOF
#!/bin/sh
# RGB Suite - start the always-on RGB daemon at boot. Auto-generated; edits lost.
APP="$APP_DIR"
[ -x "\$APP/bin/rgbctl.sh" ] && "\$APP/bin/rgbctl.sh" start
EOF
		chmod +x "$INIT_HOOK" 2>/dev/null

		# Run now so the daemon is live this session, no reboot required.
		"$APP_DIR/bin/rgbctl.sh" start
		;;
	*)
		printf 'usage: %s {install|remove}\n' "$0" >&2
		exit 1
		;;
esac
