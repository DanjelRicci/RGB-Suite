#!/bin/sh
# rgbctl.sh - RGB Suite control CLI.
#
# Thin front-end to the rgb_suite daemon, which is the single owner of the RGB
# sticks. The LOVE UI writes settings.cfg then calls `rgbctl.sh apply` to have
# the daemon re-read the config and re-render. The daemon (not this script)
# talks to the serial port, so there is never more than one writer.
#
#   rgbctl.sh apply     re-render the current config (starts the daemon if down)
#   rgbctl.sh start     start the daemon if it is not already running
#   rgbctl.sh stop      stop the daemon (leaves the LEDs in their last state)
#   rgbctl.sh restart   stop then start
#   rgbctl.sh status    report whether the daemon is running
#   rgbctl.sh set K V    upsert a key into settings.cfg (does not re-render)
#   rgbctl.sh off       set mode=off and re-render

APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
CONFIG="${RGB_SUITE_CONFIG:-$APP_DIR/settings.cfg}"
DAEMON="$APP_DIR/bin/rgb_suite.sh"
PID_FILE="/run/muos/rgb_suite.pid"

DAEMON_PID() { # echo the live daemon PID, or nothing
	p=$(cat "$PID_FILE" 2>/dev/null)
	[ -n "$p" ] && kill -0 "$p" 2>/dev/null && printf '%s' "$p"
}

START() {
	[ -x "$DAEMON" ] || { printf 'rgbctl: daemon not found: %s\n' "$DAEMON" >&2; return 1; }
	[ -n "$(DAEMON_PID)" ] && return 0
	if command -v setsid >/dev/null 2>&1; then
		setsid "$DAEMON" >/dev/null 2>&1 &
	else
		nohup "$DAEMON" >/dev/null 2>&1 &
	fi
}

STOP() { # stop the daemon, verifying it actually died (escalate to KILL if not)
	p=$(DAEMON_PID); [ -n "$p" ] || return 0
	kill "$p" 2>/dev/null
	i=0; while kill -0 "$p" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
	kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
	rm -f "$PID_FILE" 2>/dev/null
}

APPLY() { # poke a running daemon, or start one (which renders on startup)
	p=$(DAEMON_PID)
	if [ -n "$p" ]; then kill -USR1 "$p" 2>/dev/null; else START; fi
}

SET() { # SET key value  -> atomic upsert into CONFIG
	key=$1 val=$2
	tmp="$CONFIG.tmp.$$"
	if [ -f "$CONFIG" ] && grep -q "^$key=" "$CONFIG" 2>/dev/null; then
		sed "s|^$key=.*|$key=$val|" "$CONFIG" >"$tmp" && mv -f "$tmp" "$CONFIG"
	else
		{ [ -f "$CONFIG" ] && cat "$CONFIG"; printf '%s=%s\n' "$key" "$val"; } >"$tmp" && mv -f "$tmp" "$CONFIG"
	fi
}

case "${1:-apply}" in
	apply)   APPLY ;;
	start)   START ;;
	stop)    STOP ;;
	restart) STOP; sleep 0.2; START ;;
	status)  p=$(DAEMON_PID); [ -n "$p" ] && printf 'running (%s)\n' "$p" || printf 'stopped\n' ;;
	set)     shift; [ -n "$1" ] && SET "$1" "$2" ;;
	off)     SET mode off; APPLY ;;
	*)       printf 'usage: %s {apply|start|stop|restart|status|set K V|off}\n' "$0" >&2; exit 1 ;;
esac
