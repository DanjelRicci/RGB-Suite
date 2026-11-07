#!/bin/sh
# rgb_suite.sh - RGB Suite lifecycle daemon (the single owner of the RGB sticks).
#
# One always-on process drives /dev/ttyS5 directly from RGB Suite's own config,
# independent of muOS RGB scripts. It owns the WHOLE lifecycle for every mode:
#   - renders the selected mode (static/breathing/combo/theme/cycle/rainbow),
#   - runs the Screen React framebuffer sampler when mode = react,
#   - blanks the sticks on idle/dim/suspend and restores them on wake,
#   - applies the low-battery policy (none / dim to 50% / off / breathe red).
#
# The LOVE UI writes settings.cfg then signals us (SIGUSR1, via `rgbctl.sh
# apply`) to re-read and re-render. We are the only writer to the serial port,
# so there are no races.
#
# Launched once at boot (via /run/muos/storage/init) and left running.
# Two LED backends, auto-detected: the H700 serial protocol (/dev/ttyS5) and the
# TrimUI led_anim sysfs interface (/sys/class/led_anim). Exits on any other device.

# ---------------------------------------------------------------- config
CFG() { # CFG key default
	V="$(sed -n "s/^$1=//p" "$CONFIG" 2>/dev/null | head -n1)"
	[ -n "$V" ] && printf '%s' "$V" || printf '%s' "$2"
}
APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
CONFIG="${RGB_SUITE_CONFIG:-$APP_DIR/settings.cfg}"

# ---------------------------------------------------------------- runtime paths
MUOS_RUN_DIR="/run/muos"
IDLE_STATE="$MUOS_RUN_DIR/idle_state"        # muOS dim/suspend flag (0 = awake)
# Screen-off signals (see SCREEN_OFF_NOW). recent_wake: suspend.sh writes it as a sleep
# starts and removes it ~6 s after the wake. mux_blank: MustardOS's "panel blanked" flag
# (brightness 0, emergency reboot, sleep-timer power-off). disp/attr/sys: the Allwinner
# display driver's status, whose "lcd output" line carries the live backlight level.
RECENT_WAKE="$MUOS_RUN_DIR/recent_wake"
MUX_BLANK="/tmp/mux_blank"
DISP_SYS="/sys/class/disp/disp/attr/sys"
FG_PROC="/opt/muos/config/system/foreground_process"  # muOS foreground app; "muxcharge" = charge-only screen (full frontend not up)
STICK_FILE="/opt/muos/device/config/board/stick"
FB_DEVICE="/dev/fb0"
SERIAL_DEVICE="/dev/ttyS5"
MCU_PWR="/sys/class/power_supply/axp2202-battery/mcu_pwr"
LED_SYSFS="/sys/class/led_anim"                     # TrimUI (Brick / Smart Pro) LED interface
SYSFS_MAX=60                                         # led_anim max_scale ceiling (TG5040; soft ~80)
BACKEND=none                                         # set by DETECT_BACKEND at startup: serial | sysfs
BOARD_NAME=$(cat /opt/muos/device/config/board/name 2>/dev/null)
# muOS's own script/device/rgb.sh swaps the L/R led_anim zones to GRB byte order
# on the TrimUI Brick Pro ONLY (M / F1 / F2 stay RGB); we follow it so our colors
# match muOS's firmware on that board. 0 (= plain RGB) on every other device incl.
# all H700 serial models, so this flag is a no-op except on a real tui-brick-pro.
case "$BOARD_NAME" in tui-brick-pro) SYSFS_LR_GRB=1 ;; *) SYSFS_LR_GRB=0 ;; esac
# Battery: muOS's own normalized runtime files + its own low-battery threshold,
# so our policy fires at the exact point muOS considers the battery low.
BATT_CAP="$MUOS_RUN_DIR/battery/capacity"
BATT_CHG="$MUOS_RUN_DIR/battery/charging"           # non-zero = plugged/charging
LOWBATT_CONF="/opt/muos/config/settings/power/low_battery"
LOWBATT_FALLBACK=20                                 # only if muOS's value is unreadable
# Brightness Mode = screen: follow the screen brightness. muOS keeps the CURRENT
# level in its own settings tree (the same tree low_battery above comes from) and
# the panel's MAXIMUM in the device config - on a CubeXX that is brightness=90 out
# of bright=255, i.e. the 35% muOS itself displays. Device-confirmed 2026-09-11.
# There is NO /sys/class/backlight on H700 at all (and no lcd_bl under disp/attr),
# so the backlight-class node is only a fallback for boards that do have one.
MUOS_BRIGHT_VAL="/opt/muos/config/settings/general/brightness"
MUOS_BRIGHT_MAX="/opt/muos/device/config/screen/bright"
BACKLIGHT_DIR="/sys/class/backlight"
SCREEN_BRI_FILE=""                                  # "" = nothing to follow -> screen mode falls back to the slider
SCREEN_BRI_MAX=255
SCREEN_BRI_LAST=""                                  # last good byte, held across a torn read
# Screen % -> LED %, before the gamma curve. A 1:1 map left the sticks far too dim
# across the bottom of the range: the panel is already comfortable at 30% where the
# LEDs were barely lit. Compressing the LED range into FLOOR..100 fixes that and
# keeps a faint baseline at minimum screen. Device-tuned 2026-09-11:
#   LED% = 20 + 0.8 x screen%  ->  screen 30% lands on LED 44%, screen 100% on 100%.
# Keep in step with SCREEN_LED_FLOOR in rgbsuite/config.lua, or the Brightness row
# displays a number the daemon is not actually rendering.
# Raised 15 -> 20 on 2026-09-16 (user: same screen brightness, slightly more LED). The
# lift is strongest low down and vanishes at the top, since both ends still meet at 255:
# byte 34 -> 42 at screen 30% (1.24x), 74 -> 83 at 50%, 207 -> 212 at 90%, 255 at 100%.
# The knob deliberately chosen over BRIGHT_GAMMA, which the manual Brightness row shares.
SCREEN_LED_FLOOR=20

# ---------------------------------------------------------------- react tuning
MARGIN_PERCENT=5      # ignored screen border per side (0-50); smaller = sample closer to the frame edge
OVERLAP_PERCENT=15    # center band (% of width) fed to BOTH sticks so centered content bleeds both ways; 0 = hard split
GRID_COLS=5           # sample columns; these decide the left/right split, so they carry the real work
GRID_ROWS=6           # sample rows, fixed and EVEN: rows alternate a quarter-column left/right, so an odd
                      # count leans the whole grid one way (3 rows shifted right vs 2 left, on a 5-row panel)
SATURATION_BOOST=350  # dull color boost (100: none, 200: 2x)
VALUE_GAIN_MAX=350    # value-normalize: lift the averaged color toward full brightness, capped at this % (100: off, 350: up to 3.5x). Keeps dark-bg+bright-edge scenes vivid without blasting near-black ones.
SAMPLE_INTERVAL_MS=333
# Color smoothing: each frame closes REACT_SMOOTH / (frames per sample) % of the gap to the
# newest sample - 300 / 10 = 30%, so ~97% there by the next sample. Higher = snappier,
# lower = softer (clamped to 10..50%). User-tuned 2026-10-18: 250 felt too slow, 370 too fast.
REACT_SMOOTH=300
FRAME_INTERVAL_MS=33

# how often the idle/battery watch wakes when NOT reacting (fast enough that a
# SIGUSR1 that misses the sleep window is still picked up promptly)
POLL_SLEEP="0.3"

# Idle/battery change slowly, so re-poll them at most this often even while
# reacting - keeps the CPU-sensitive react frame from touching those files 30x/s
# (the one-shot branch already sleeps POLL_SLEEP, so it's unaffected).
STATE_INTERVAL_MS=300

# A gap at least this long between two loop passes means the device slept. A normal
# pass takes ~1.5 s at most (the blank path's 1 s sleep, a Stick React /proc sweep).
RESUME_GAP_MS=5000

# Fades (user-tuned 2026-10-18). Every full on/off - sleep and wake, idle dim, the charge
# screen, Off in the app, startup - ramps over FADE_MS. A mode switch dips through black:
# MODE_FADE_MS out, then MODE_FADE_MS in. Color and brightness changes stay instant.
# The level runs 0..FADE_MAX and the brightness byte follows its SQUARE: the LED's light
# is ~linear in the byte and the eye is not, so a squared ramp looks even.
FADE_MS=500
MODE_FADE_MS=200
FADE_MAX=1000
FADE_STEP_MS=33
FADE_STALL_MS=50   # the most one loop pass may advance a fade-in (see the fade-in block)

SERIAL_READY=0

# ---------------------------------------------------------------- serial protocol
CLAMP() { V=$1; [ "$V" -lt "$2" ] && V=$2; [ "$V" -gt "$3" ] && V=$3; printf '%d' "$V"; }


SERIAL_WRITE() { # argv = decimal bytes (checksum included by caller)
	# Each byte becomes an octal escape built with arithmetic, and one builtin printf
	# writes the lot: no fork. (The \x%02X command substitution this replaces forked
	# once per frame - 30 times a second in Screen React and Stick React.) busybox printf
	# emits \000 and \012 as raw bytes, device-checked.
	sw_f=""
	for sw_b in "$@"; do
		sw_f="$sw_f\\$(( (sw_b >> 6) & 7 ))$(( (sw_b >> 3) & 7 ))$(( sw_b & 7 ))"
	done
	printf "$sw_f" >"$SERIAL_DEVICE"
}

SERIAL_PREPARE() {
	[ -w "$MCU_PWR" ] && printf '1\n' >"$MCU_PWR"
	stty -F "$SERIAL_DEVICE" 115200 cs8 -parenb -cstopb -opost -isig -icanon -echo 2>/dev/null
	SERIAL_READY=1
}

# mode 1: solid color per stick (right 8 LEDs then left) -> [1,bri,(RGB)x8,(RGB)x8,chk]
# The senders below clamp and checksum with builtins (no fork): fades call them up to 30
# times a second. CK_SUM sets CK; BYTE_CLAMP sets BC.
CK_SUM()     { CK=0; for x in "$@"; do CK=$(((CK + x) & 255)); done; }
BYTE_CLAMP() { BC=$1; [ "$BC" -lt 0 ] && BC=0; [ "$BC" -gt 255 ] && BC=255; }

SEND_STATIC() { # bri  rr rg rb  lr lg lb
	BYTE_CLAMP "$1"; bri=$BC
	rr=$2 rg=$3 rb=$4 lr=$5 lg=$6 lb=$7
	LAST_OUT="static $rr $rg $rb $lr $lg $lb"; LAST_BRI=$bri
	set -- 1 "$bri"
	i=0; while [ "$i" -lt 8 ]; do set -- "$@" "$rr" "$rg" "$rb"; i=$((i + 1)); done
	i=0; while [ "$i" -lt 8 ]; do set -- "$@" "$lr" "$lg" "$lb"; i=$((i + 1)); done
	CK_SUM "$@"; SERIAL_WRITE "$@" "$CK"
}

# modes 2/3/4: breath fast/med/slow, single color -> [mode,bri,(RGB)x16,chk]
SEND_BREATH() { # mode bri  r g b
	m=$1; BYTE_CLAMP "$2"; bri=$BC; r=$3 g=$4 b=$5
	LAST_OUT="breath $m $r $g $b"; LAST_BRI=$bri
	set -- "$m" "$bri"
	i=0; while [ "$i" -lt 16 ]; do set -- "$@" "$r" "$g" "$b"; i=$((i + 1)); done
	CK_SUM "$@"; SERIAL_WRITE "$@" "$CK"
}

# modes 5/6: mono/multi rainbow -> [mode,bri,1,1,speed,chk]
SEND_ANIM() { # mode bri speed
	m=$1; BYTE_CLAMP "$2"; bri=$BC; BYTE_CLAMP "$3"; sp=$BC
	LAST_OUT="anim $m $sp"; LAST_BRI=$bri
	CK_SUM "$m" "$bri" 1 1 "$sp"; SERIAL_WRITE "$m" "$bri" 1 1 "$sp" "$CK"
}

# Firmware anim speed byte for modes 5/6; HIGHER = faster. Rainbow keeps the
# original 4/10/20. Color Cycle read as too fast at every setting and now has its
# own hand-picked row, device-tuned 2026-09-11 - these are chosen values, not a
# scale factor off Rainbow, so retune by editing the CYCLE row directly. Both modes
# share the mode-5/6 frame builder, so scaling at the call site would drag Rainbow
# along with it.
SPEED_BYTE()       { case "$1" in slow) echo 4 ;; fast) echo 20 ;; *) echo 10 ;; esac; }
CYCLE_SPEED_BYTE() { case "$1" in slow) echo 2 ;; fast) echo 10 ;; *) echo 6  ;; esac; }
BREATH_MODE()      { case "$1" in slow) echo 4  ;; fast) echo 2  ;; *) echo 3  ;; esac; }

RGB_OF() { printf '%s' "$1" | tr ',' ' '; } # "0,208,255" -> "0 208 255"

# ---------------------------------------------------------------- led_anim (TrimUI) backend
# Uniform per-zone color via the sysfs effect system (effect_* + effect_enable=1). We
# deliberately avoid the per-LED frame_hex path: its second-write kernel block is an
# uninterruptible hang, unsafe to drive on hardware we can't test. Every zone is
# feature-probed, so the same code lights a Smart Pro's rings and a Brick's top bar /
# FN buttons / triggers, and skips whatever a given device lacks.
SYSFS_HAS()   { [ -w "$LED_SYSFS/$1" ]; }
SYSFS_WRITE() { [ -w "$LED_SYSFS/$1" ] && printf '%s\n' "$2" >"$LED_SYSFS/$1"; }
TOHEX()       { printf '%02X%02X%02X' "$1" "$2" "$3"; }

# static color per side (right first, matching SEND_STATIC). left -> l + f1, right ->
# r + f2, blend -> m (the centered logo / top-bar); combined lr when both sides match.
SYSFS_STATIC() { # bri  rr rg rb  lr lg lb
	sb=$(( $(CLAMP "$1" 0 255) * SYSFS_MAX / 255 ))
	rr=$(CLAMP "$2" 0 255) rg=$(CLAMP "$3" 0 255) rb=$(CLAMP "$4" 0 255)
	lr=$(CLAMP "$5" 0 255) lg=$(CLAMP "$6" 0 255) lb=$(CLAMP "$7" 0 255)
	hexL="$(TOHEX "$lr" "$lg" "$lb") "
	hexR="$(TOHEX "$rr" "$rg" "$rb") "
	mr=$(((lr + rr) / 2)); mg=$(((lg + rg) / 2)); mb=$(((lb + rb) / 2))
	hexM="$(TOHEX "$mr" "$mg" "$mb") "
	# L/R stick zones take GRB byte order on the Brick Pro (F1/F2/M stay RGB, per
	# muOS); on every other board hexLZ/hexRZ equal hexL/hexR, so this is a no-op.
	if [ "$SYSFS_LR_GRB" = 1 ]; then
		hexLZ="$(TOHEX "$lg" "$lr" "$lb") "
		hexRZ="$(TOHEX "$rg" "$rr" "$rb") "
	else
		hexLZ="$hexL" hexRZ="$hexR"
	fi

	SYSFS_WRITE max_scale "$sb"
	SYSFS_WRITE max_scale_lr "$sb"
	SYSFS_WRITE max_scale_f1f2 "$sb"

	if [ "$hexLZ" = "$hexRZ" ] && SYSFS_HAS effect_rgb_hex_lr; then
		SYSFS_WRITE effect_rgb_hex_lr "$hexLZ"
	else
		SYSFS_WRITE effect_rgb_hex_l "$hexLZ"
		SYSFS_WRITE effect_rgb_hex_r "$hexRZ"
	fi
	SYSFS_HAS effect_rgb_hex_m  && SYSFS_WRITE effect_rgb_hex_m  "$hexM"
	SYSFS_HAS effect_rgb_hex_f1 && SYSFS_WRITE effect_rgb_hex_f1 "$hexL"
	SYSFS_HAS effect_rgb_hex_f2 && SYSFS_WRITE effect_rgb_hex_f2 "$hexR"

	# static-color effect (4) on whatever zones exist, then arm the effect system.
	if SYSFS_HAS effect_lr; then SYSFS_WRITE effect_lr 4
	else SYSFS_WRITE effect_l 4; SYSFS_WRITE effect_r 4; fi
	SYSFS_HAS effect_m  && SYSFS_WRITE effect_m 4
	SYSFS_HAS effect_f1 && SYSFS_WRITE effect_f1 4
	SYSFS_HAS effect_f2 && SYSFS_WRITE effect_f2 4
	SYSFS_WRITE effect_enable 1
}

DETECT_BACKEND() {
	if [ -d "$LED_SYSFS" ]; then BACKEND=sysfs
	elif [ -c "$SERIAL_DEVICE" ]; then BACKEND=serial
	else BACKEND=none; fi
}

SERIAL_PREPARE_ONCE() { [ "$SERIAL_READY" -eq 1 ] || SERIAL_PREPARE; }

# backend-agnostic static write, used by every non-firmware render + blank + react.
PUT_STATIC() { # bri  rr rg rb  lr lg lb
	if [ "$BACKEND" = sysfs ]; then
		SYSFS_STATIC "$@"
		LAST_OUT="static $2 $3 $4 $5 $6 $7"; LAST_BRI=$1
	else SERIAL_PREPARE_ONCE; SEND_STATIC "$@"; fi
}

# Every sender records what it last put on the sticks (LAST_OUT, without the brightness)
# and at what brightness (LAST_BRI), so a fade-out can replay that exact picture dimmer -
# whatever the mode, and without the mode's own variables, which a reload may already
# have replaced with the next mode's.
REPLAY_AT() { # $1 = brightness
	rp_bri=$1
	set -- $LAST_OUT
	case "$1" in
		static) PUT_STATIC "$rp_bri" "$2" "$3" "$4" "$5" "$6" "$7" ;;
		frame)
			SERIAL_WRITE 1 "$rp_bri" $LAST_FRAME "$(( (1 + rp_bri + LAST_SUM) & 255 ))"
			LAST_BRI=$rp_bri ;;
		breath) SEND_BREATH "$2" "$rp_bri" "$3" "$4" "$5" ;;
		anim)   SEND_ANIM "$2" "$rp_bri" "$3" ;;
	esac
}

# Ramp the sticks from what they show now down to black, over $1 ms scaled by how far
# faded in they are. Blocking, so at most $1 ms; a signal that lands meanwhile is handled
# right after. Leaves FADE_T at 0, ready for the next fade-in.
FADE_OUT() { # $1 = ms for a full fade
	if [ "$FADE_T" -gt 0 ] && [ -n "$LAST_OUT" ] && [ "$LAST_BRI" -gt 0 ]; then
		fo_n=$(( $1 * FADE_T / FADE_MAX / FADE_STEP_MS ))
		[ "$fo_n" -lt 1 ] && fo_n=1
		fo_base=$LAST_BRI
		fo_k=$fo_n
		while [ "$fo_k" -gt 0 ]; do
			fo_k=$((fo_k - 1))
			REPLAY_AT $(( fo_base * fo_k * fo_k / (fo_n * fo_n) ))
			sleep 0.033
		done
	fi
	FADE_T=0; FADE_FROM=0
	LED_FRAME_RESET
}

# render the current one-shot mode at a given brightness (all modes but react).
# breathing/cycle/rainbow are H700 firmware animations; the sysfs backend has no usable
# firmware anim, so there they fall back to a static color. The UI already hides them
# on sysfs, so that path only guards a stale/imported config.
RENDER_ONESHOT() { # $1 = effective brightness
	bri=$1
	case "$MODE" in
		off)       PUT_STATIC 0 0 0 0 0 0 0 ;;
		static)    set -- $(RGB_OF "$COL");      PUT_STATIC "$bri" "$1" "$2" "$3" "$1" "$2" "$3" ;;
		combo)     set -- $(RGB_OF "$COMBO_R") $(RGB_OF "$COMBO_L"); PUT_STATIC "$bri" "$1" "$2" "$3" "$4" "$5" "$6" ;;
		theme)     set -- $(RGB_OF "$THEME_COL"); PUT_STATIC "$bri" "$1" "$2" "$3" "$1" "$2" "$3" ;;
		react)
			# Only reachable when the framebuffer sampler never came up (REACT_OK=0).
			# Before this case existed, react fell through to *) and BLANKED the
			# sticks, so a failed sampler was indistinguishable from "LEDs broken".
			set -- $(RGB_OF "$COL"); PUT_STATIC "$bri" "$1" "$2" "$3" "$1" "$2" "$3" ;;
		stickreact)
			# Reached only with no joystick node, or on the led_anim backend which has
			# no per-LED path: show the ring at rest so the mode still has its color.
			set -- $(RGB_OF "$PULSE_BG")
			sr_fb_r=$(( $1 * SR_BG_SCALE / 100 )); sr_fb_g=$(( $2 * SR_BG_SCALE / 100 )); sr_fb_b=$(( $3 * SR_BG_SCALE / 100 ))
			PUT_STATIC "$bri" "$sr_fb_r" "$sr_fb_g" "$sr_fb_b" "$sr_fb_r" "$sr_fb_g" "$sr_fb_b" ;;
		sparkle)
			# Reached only on the led_anim backend, which has no per-LED path: show the
			# resting ring, the same way Stick React falls back.
			set -- $(RGB_OF "$SPARK_BG")
			sp_fb_r=$(( $1 * SP_BG_SCALE / 100 )); sp_fb_g=$(( $2 * SP_BG_SCALE / 100 )); sp_fb_b=$(( $3 * SP_BG_SCALE / 100 ))
			PUT_STATIC "$bri" "$sp_fb_r" "$sp_fb_g" "$sp_fb_b" "$sp_fb_r" "$sp_fb_g" "$sp_fb_b" ;;
		breathing)
			if [ "$BACKEND" = serial ]; then
				SERIAL_PREPARE_ONCE; set -- $(RGB_OF "$COL"); SEND_BREATH "$(BREATH_MODE "$SPEED")" "$bri" "$1" "$2" "$3"
			else set -- $(RGB_OF "$COL"); PUT_STATIC "$bri" "$1" "$2" "$3" "$1" "$2" "$3"; fi ;;
		cycle)
			if [ "$BACKEND" = serial ]; then SERIAL_PREPARE_ONCE; SEND_ANIM 5 "$bri" "$(CYCLE_SPEED_BYTE "$SPEED")"
			else set -- $(RGB_OF "$COL"); PUT_STATIC "$bri" "$1" "$2" "$3" "$1" "$2" "$3"; fi ;;
		rainbow)
			if [ "$BACKEND" = serial ]; then SERIAL_PREPARE_ONCE; SEND_ANIM 6 "$bri" "$(SPEED_BYTE "$SPEED")"
			else set -- $(RGB_OF "$COL"); PUT_STATIC "$bri" "$1" "$2" "$3" "$1" "$2" "$3"; fi ;;
		*)         PUT_STATIC 0 0 0 0 0 0 0 ;;
	esac
}

BLANK_LEDS() { PUT_STATIC 0 0 0 0 0 0 0; }

# Low Battery = Breathe Red: while the battery is low the sticks breathe red at Medium,
# whatever the mode (LB_RED, set in the loop). It is the firmware breath, so like
# Breathing it is one frame and the MCU animates it. led_anim has no firmware breath and
# the UI doesn't offer the option there; a stale config gets solid red instead.
LB_RENDER() { # $1 = effective brightness
	if [ "$BACKEND" = serial ]; then
		SERIAL_PREPARE_ONCE; SEND_BREATH "$(BREATH_MODE med)" "$1" 255 0 0
	else PUT_STATIC "$1" 255 0 0 255 0 0; fi
}

# ---------------------------------------------------------------- react engine
BOOST_COLOR() {
	# $1-3 weighted RGB sums, $4 total weight -> BR BG BB (boosted, clamped)
	if [ "$4" -le 0 ]; then BR=0 BG=0 BB=0; return; fi

	AR=$(($1 / $4)) AG=$(($2 / $4)) AB=$(($3 / $4))

	MAX=$AR && [ "$AG" -gt "$MAX" ] && MAX=$AG
	[ "$AB" -gt "$MAX" ] && MAX=$AB
	MIN=$AR && [ "$AG" -lt "$MIN" ] && MIN=$AG
	[ "$AB" -lt "$MIN" ] && MIN=$AB

	if [ "$MAX" -gt 0 ]; then SAT=$(((MAX - MIN) * 100 / MAX)); else SAT=0; fi

	BOOST=$((100 + (100 - SAT) * (SATURATION_BOOST - 100) / 100))

	# Hue-preserving saturation boost: anchor to MAX (the value) and scale each
	# channel's gap below it. This keeps the brightest channel fixed and preserves
	# the hue ratio exactly, so a near-primary color can't drift (e.g. red stays
	# red instead of picking up a magenta cast from a tiny blue>green imbalance).
	# Anchoring on the arithmetic mean instead would amplify that imbalance.
	BR=$((MAX - (MAX - AR) * BOOST / 100))
	BG=$((MAX - (MAX - AG) * BOOST / 100))
	BB=$((MAX - (MAX - AB) * BOOST / 100))

	[ "$BR" -lt 0 ] && BR=0; [ "$BR" -gt 255 ] && BR=255
	[ "$BG" -lt 0 ] && BG=0; [ "$BG" -gt 255 ] && BG=255
	[ "$BB" -lt 0 ] && BB=0; [ "$BB" -gt 255 ] && BB=255

	# Value-normalize: scale the color up so its brightest channel reaches full,
	# preserving hue+saturation, so a dark scene with bright areas still lights the
	# sticks fully. GAIN is capped at VALUE_GAIN_MAX so a genuinely near-black scene
	# is only lifted a little, not blasted to full color. LED brightness is applied
	# separately downstream, so this only touches the *color*, never overall level.
	VMAX=$BR && [ "$BG" -gt "$VMAX" ] && VMAX=$BG
	[ "$BB" -gt "$VMAX" ] && VMAX=$BB
	if [ "$VMAX" -gt 0 ] && [ "$VALUE_GAIN_MAX" -gt 100 ]; then
		GAIN=$((255 * 100 / VMAX))
		[ "$GAIN" -gt "$VALUE_GAIN_MAX" ] && GAIN=$VALUE_GAIN_MAX
		if [ "$GAIN" -gt 100 ]; then
			BR=$((BR * GAIN / 100)); [ "$BR" -gt 255 ] && BR=255
			BG=$((BG * GAIN / 100)); [ "$BG" -gt 255 ] && BG=255
			BB=$((BB * GAIN / 100)); [ "$BB" -gt 255 ] && BB=255
		fi
	fi
}

SAMPLE() {
	# Read the staggered grid of pixels (FB_PTS, built by REACT_SETUP) and set the
	# TARGET colors. Vivid pixels carry more weight; sides are split for dual stick
	# devices. fb_sampler.py, when it is up, reads the pixels and does this weighting in
	# one request (no forks, and more points cost next to nothing); else a dd|od per
	# pixel and the loop below. THE PYTHON WEIGHTING MIRRORS THIS LOOP - change both.
	WR=0 WG=0 WB=0 WT=0
	WR_L=0 WG_L=0 WB_L=0 WT_L=0
	WR_R=0 WG_R=0 WB_R=0 WT_R=0

	fb_list=$FB_PTS
	if FB_REQUEST; then
		set -- $FB_LINE
		if [ "$STICK_COUNT" -eq 1 ]; then WR=$1 WG=$2 WB=$3 WT=$4
		else WR_L=$1 WG_L=$2 WB_L=$3 WT_L=$4 WR_R=$5 WG_R=$6 WB_R=$7 WT_R=$8; fi
		fb_list=""                     # sums are in: skip the shell loop
	fi

	for fb_pt in $fb_list; do
		PX=${fb_pt%%:*}
		# Framebuffer is BGRA (4 bytes per pixel)
		set -- $(dd if="$FB_DEVICE" bs=1 skip="${fb_pt#*:}" count=4 2>/dev/null | od -An -tu1)
		B=$1 G=$2 R=$3

		MAX=$R && [ "$G" -gt "$MAX" ] && MAX=$G
		[ "$B" -gt "$MAX" ] && MAX=$B
		MIN=$R && [ "$G" -lt "$MIN" ] && MIN=$G
		[ "$B" -lt "$MIN" ] && MIN=$B

		if [ "$MAX" -gt 0 ]; then
			W=$(((MAX - MIN) * 100 / MAX)); [ "$W" -lt 1 ] && W=1
		else
			W=1
		fi

		if [ "$STICK_COUNT" -eq 1 ]; then
			WR=$((WR + R * W)) WG=$((WG + G * W)) WB=$((WB + B * W)) WT=$((WT + W))
		else
			# Overlap: a pixel in the center band satisfies both tests and lands
			# in both sums. Outside the band exactly one test holds (hard split).
			if [ "$PX" -lt "$LEFT_BOUND" ]; then
				WR_L=$((WR_L + R * W)) WG_L=$((WG_L + G * W)) WB_L=$((WB_L + B * W)) WT_L=$((WT_L + W))
			fi
			if [ "$PX" -ge "$RIGHT_BOUND" ]; then
				WR_R=$((WR_R + R * W)) WG_R=$((WG_R + G * W)) WB_R=$((WB_R + B * W)) WT_R=$((WT_R + W))
			fi
		fi
	done

	if [ "$STICK_COUNT" -eq 1 ]; then
		BOOST_COLOR "$WR" "$WG" "$WB" "$WT"
		TARGET_RL=$BR TARGET_GL=$BG TARGET_BL=$BB
		TARGET_RR=$BR TARGET_GR=$BG TARGET_BR=$BB
	else
		BOOST_COLOR "$WR_L" "$WG_L" "$WB_L" "$WT_L"
		TARGET_RL=$BR TARGET_GL=$BG TARGET_BL=$BB
		BOOST_COLOR "$WR_R" "$WG_R" "$WB_R" "$WT_R"
		TARGET_RR=$BR TARGET_GR=$BG TARGET_BR=$BB
	fi
}

SMOOTH() {
	# $1 current, $2 target -> SM (moves current one step toward target)
	SM_DIFF=$(($2 - $1))
	SM_STEP=$((SM_DIFF * SMOOTHING / 100))
	[ "$SM_DIFF" -gt 0 ] && [ "$SM_STEP" -eq 0 ] && SM_STEP=1
	[ "$SM_DIFF" -lt 0 ] && [ "$SM_STEP" -eq 0 ] && SM_STEP=-1
	SM=$(($1 + SM_STEP))
}

NOW_MS() {
	read -r UP _ </proc/uptime
	FRAC=${UP#*.} && FRAC=${FRAC#0}
	NOW=$((${UP%.*} * 1000 + ${FRAC:-0} * 10))
}

REACT_SETUP() {
	REACT_OK=0
	STICK_COUNT=$(cat "$STICK_FILE" 2>/dev/null || echo 2)
	# The TrimUI led_anim zones aren't the Anbernic RGB "sticks", so a 0/unset count
	# there just means "no sticks", not "no LEDs". Both TrimUI devices have >=2 side
	# zones, so react as a 2-side device; on serial a genuine 0 disables react.
	if [ "$BACKEND" = sysfs ]; then
		case "$STICK_COUNT" in ''|*[!0-9]*|0) STICK_COUNT=2 ;; esac
	else
		[ "$STICK_COUNT" -eq 0 ] && return
	fi
	[ -r "$FB_DEVICE" ] || return

	set -- $(fbset 2>/dev/null | awk '/geometry/ { print $2, $3 }')
	FB_WIDTH=$1 FB_HEIGHT=$2
	[ -z "$FB_WIDTH" ] && return

	# Fixed grid, same on every panel shape. Deriving the rows from the aspect ratio
	# gave 5 rows on a 1:1 CubeXX but only 3 on 4:3 and 16:9, and the odd count also
	# unbalanced the quarter-column stagger. A fixed even count samples every device
	# alike. 6 rows since 2026-10-18: fb_sampler.py made extra points nearly free.
	GRID_W=$GRID_COLS
	GRID_H=$GRID_ROWS

	MARGIN_W=$((FB_WIDTH * MARGIN_PERCENT / 100))
	MARGIN_H=$((FB_HEIGHT * MARGIN_PERCENT / 100))
	SAMPLE_W=$((FB_WIDTH - MARGIN_W * 2))
	SAMPLE_H=$((FB_HEIGHT - MARGIN_H * 2))
	HALF_WIDTH=$((FB_WIDTH / 2))
	# Overlap band: pixels in [RIGHT_BOUND, LEFT_BOUND) feed both sticks. At 0% these
	# collapse back onto HALF_WIDTH, restoring the hard left/right split.
	OVERLAP_HALF=$((FB_WIDTH * OVERLAP_PERCENT / 200))
	LEFT_BOUND=$((HALF_WIDTH + OVERLAP_HALF))   # a pixel left of this counts to the LEFT
	RIGHT_BOUND=$((HALF_WIDTH - OVERLAP_HALF))  # a pixel at/right of this counts to the RIGHT

	# The sample points, worked out once: "PX:byte offset" per pixel, row by row. Rows
	# alternate a quarter column left/right (the stagger). Both samplers read exactly
	# these points, in this order. (The Screen React Sampler page mirrors this geometry.)
	COL_SPACING=$((SAMPLE_W / GRID_W))
	HALF_SPACING=$((COL_SPACING / 2))
	QUARTER_SPACING=$((HALF_SPACING / 2))
	FB_PTS=""
	ROW=0
	while [ "$ROW" -lt "$GRID_H" ]; do
		PY=$((MARGIN_H + ROW * SAMPLE_H / GRID_H + SAMPLE_H / (GRID_H * 2)))
		COL=0
		while [ "$COL" -lt "$GRID_W" ]; do
			PX=$((MARGIN_W + COL * COL_SPACING + HALF_SPACING))
			if [ "$((ROW % 2))" -eq 1 ]; then PX=$((PX - QUARTER_SPACING)); else PX=$((PX + QUARTER_SPACING)); fi
			FB_PTS="$FB_PTS $PX:$(((PY * FB_WIDTH + PX) * 4))"   # BGRA, 4 bytes per pixel
			COL=$((COL + 1))
		done
		ROW=$((ROW + 1))
	done

	# Ease toward each new sample over the frames until the next one (see REACT_SMOOTH)
	FRAMES=$((SAMPLE_INTERVAL_MS / FRAME_INTERVAL_MS))
	if [ "$FRAMES" -gt 1 ]; then
		SMOOTHING=$((REACT_SMOOTH / FRAMES))
		[ "$SMOOTHING" -lt 10 ] && SMOOTHING=10
		[ "$SMOOTHING" -gt 50 ] && SMOOTHING=50
	else
		SMOOTHING=50
	fi

	REACT_OK=1
}

REACT_RESET() {
	CURR_RL=0 CURR_GL=0 CURR_BL=0 CURR_RR=0 CURR_GR=0 CURR_BR=0
	TARGET_RL=0 TARGET_GL=0 TARGET_BL=0 TARGET_RR=0 TARGET_GR=0 TARGET_BR=0
	NEXT_SAMPLE=0
	RF_LAST=""
}

# fb_sampler.py lifecycle. Two pipes, held read-write on fd 6 (requests) and fd 7
# (replies) so no open blocks and the helper sees EOF once the daemon is gone. FB_PY is
# emptied for the rest of the session if Python is missing or the helper stops answering.
FB_PY=""
command -v python3 >/dev/null 2>&1 && [ -r "$APP_DIR/bin/fb_sampler.py" ] && FB_PY=python3
FB_REQ="$MUOS_RUN_DIR/rgb_fb.req"
FB_REP="$MUOS_RUN_DIR/rgb_fb.rep"
FB_PID=""
FB_STATE=off   # off | starting | ready
FB_MISSES=0    # replies missed in a row; three, or a dead helper, and we stop using it

FB_START() {
	[ -n "$FB_PY" ] && [ "$FB_STATE" = off ] && [ -n "$FB_PTS" ] || return 0
	rm -f "$FB_REQ" "$FB_REP"
	mkfifo "$FB_REQ" "$FB_REP" 2>/dev/null || { FB_PY=""; return 0; }
	exec 6<>"$FB_REQ" 7<>"$FB_REP"
	# shellcheck disable=SC2086 # FB_PTS is a list of "PX:offset" words
	"$FB_PY" "$APP_DIR/bin/fb_sampler.py" "$FB_DEVICE" "$FB_REQ" "$FB_REP" \
		"$STICK_COUNT" "$LEFT_BOUND" "$RIGHT_BOUND" $FB_PTS &
	FB_PID=$!
	FB_STATE=starting
	FB_MISSES=0
}

FB_STOP() {
	[ "$FB_STATE" = off ] && return 0
	[ -n "$FB_PID" ] && kill "$FB_PID" 2>/dev/null
	FB_PID=""
	exec 6<&- 7<&-
	rm -f "$FB_REQ" "$FB_REP"
	FB_STATE=off
}

# Ask the helper for this sample's weighted sums: sets FB_LINE ("WR WG WB WT" for one
# stick, "WR_L .. WT_L WR_R .. WT_R" for two - SAMPLE's own sums) and returns 0, or
# returns 1 and the caller uses the shell sampler. While the helper is still starting
# (~0.6 s at powersave) this just checks for its "R" line, without waiting: `read -t 0`
# only peeks, and the plain read after it finds the whole line already there. A short
# `read -t` would not do: busybox throws away a partly read line when the deadline hits,
# and a 1 ms poll lost the helper's ready line in 12 of 30 starts on the device.
FB_REQUEST() {
	case "$FB_STATE" in
		ready) ;;
		starting)
			fb_r=""
			read -r -t 0 <&7 && read -r fb_r <&7
			if [ "$fb_r" = R ]; then FB_STATE=ready
			elif ! kill -0 "$FB_PID" 2>/dev/null; then FB_STOP; FB_PY=""; fi   # died starting
			return 1 ;;
		*) return 1 ;;
	esac
	while read -r -t 0.001 fb_r <&7; do :; done   # a late reply would put us one behind
	printf '\n' >&6
	FB_LINE=""
	read -r -t 0.3 FB_LINE <&7
	set -- $FB_LINE
	fb_want=8; [ "$STICK_COUNT" -eq 1 ] && fb_want=4
	if [ $# -eq "$fb_want" ]; then FB_MISSES=0; return 0; fi
	# No full answer in time: the shell sampler covers this sample. A busy moment can
	# do that once (seen once right after a mode switch), so give up on the helper only
	# after three misses in a row, or at once if it has died.
	FB_MISSES=$((FB_MISSES + 1))
	if [ "$FB_MISSES" -ge 3 ] || ! kill -0 "$FB_PID" 2>/dev/null; then FB_STOP; FB_PY=""; fi
	return 1
}

REACT_FRAME() { # $1 = effective brightness
	NOW_MS; RF_START=$NOW

	if [ "$NOW" -ge "$NEXT_SAMPLE" ]; then
		SAMPLE
		NEXT_SAMPLE=$((NOW + SAMPLE_INTERVAL_MS))
	fi

	SMOOTH "$CURR_RL" "$TARGET_RL" && CURR_RL=$SM
	SMOOTH "$CURR_GL" "$TARGET_GL" && CURR_GL=$SM
	SMOOTH "$CURR_BL" "$TARGET_BL" && CURR_BL=$SM
	SMOOTH "$CURR_RR" "$TARGET_RR" && CURR_RR=$SM
	SMOOTH "$CURR_GR" "$TARGET_GR" && CURR_GR=$SM
	SMOOTH "$CURR_BR" "$TARGET_BR" && CURR_BR=$SM

	# PUT_STATIC takes right stick first, then left. Send only what changed: once the
	# colors reach their targets (SMOOTH always moves at least 1 while they differ, so an
	# unchanged frame means settled), nothing can change before the next sample - so
	# sleep until then rather than re-sending the same frame 30 times a second.
	rf_sig="$1 $CURR_RR $CURR_GR $CURR_BR $CURR_RL $CURR_GL $CURR_BL"
	rf_settled=1
	if [ "$rf_sig" != "$RF_LAST" ]; then
		PUT_STATIC "$1" "$CURR_RR" "$CURR_GR" "$CURR_BR" "$CURR_RL" "$CURR_GL" "$CURR_BL"
		RF_LAST=$rf_sig; rf_settled=0
	fi

	NOW_MS
	if [ "$rf_settled" = 1 ]; then
		SLEEP_MS=$((NEXT_SAMPLE - NOW))
		[ "$SLEEP_MS" -gt 999 ] && SLEEP_MS=999
	else
		SLEEP_MS=$((FRAME_INTERVAL_MS - (NOW - RF_START)))
	fi
	[ "$SLEEP_MS" -lt 10 ] && SLEEP_MS=10
	# SLEEP_MS is 10..999 here, so pad the fraction by hand - the printf
	# this replaces was a fork, 30 times a second, the whole time React was running.
	if [ "$SLEEP_MS" -lt 100 ]; then sleep "0.0$SLEEP_MS"; else sleep "0.$SLEEP_MS"; fi
}

# ---------------------------------------------------------------- state inputs
READ_IDLE() { # sets IDLE_VAL: 0 (awake) or non-zero (dim/suspend). No fork (was a
	# command-substitution before - that forked ~30x/s in react mode).
	IDLE_VAL=0
	[ -r "$IDLE_STATE" ] && read -r IDLE_VAL <"$IDLE_STATE" 2>/dev/null
	[ -z "$IDLE_VAL" ] && IDLE_VAL=0
}

# Is the panel's backlight at 0? Parses the display driver's status (builtin reads, no
# fork). Anything missing or unreadable counts as lit, so a board without this file
# simply keeps the old behavior.
BACKLIGHT_OFF() {
	[ -r "$DISP_SYS" ] || return 1
	while IFS= read -r ds_line; do
		case "$ds_line" in
			*backlight\(*)
				ds_bl=${ds_line#*backlight\(}; ds_bl=${ds_bl%%\)*}
				set -- $ds_bl                 # drop the driver's padding: "( 90)"
				[ "$1" = 0 ] && return 0
				return 1 ;;
		esac
	done <"$DISP_SYS"
	return 1
}

# Sticks follow the screen: dark whenever MustardOS has blanked the panel, and through a
# sleep from the moment it starts (seconds before the real suspend) until the screen
# lights again on wake (seconds after the kernel resumes).
#   going to sleep: recent_wake APPEARING means suspend.sh has just started a sleep - it
#                   writes the file first thing, a moment before it darkens the panel.
#                   SLEEPING holds from then on.
#   waking up:      the sleep is over once the backlight, having gone dark, is lit again
#                   (recent_wake stays ~6 s past the wake, so it can't tell us). This does
#                   not depend on how long the suspend lasted - a short one slipped under
#                   the uptime-jump check (device log 2026-10-18), which remains only as a
#                   backstop. If the backlight can't be read, the uptime jump or the file
#                   going away ends the sleep instead.
# The backlight is only read inside that window, so normal running costs two
# file-exists checks per state poll.
SCREEN_OFF_NOW() {
	if [ -e "$RECENT_WAKE" ]; then
		[ "$RW_SEEN" = 0 ] && { SLEEPING=1; SLEEP_DARK=0; }
		RW_SEEN=1
	else
		RW_SEEN=0; SLEEPING=0
	fi
	[ -e "$MUX_BLANK" ] && return 0
	[ "$RW_SEEN" = 1 ] || return 1
	if BACKLIGHT_OFF; then SLEEP_DARK=1; return 0; fi
	[ "$SLEEP_DARK" = 1 ] && SLEEPING=0      # dark, then lit again: awake
	[ "$SLEEPING" = 1 ]
}

BATTERY_LOW() { # 0 = low & discharging, 1 = not low (mirrors muOS lowpower.sh)
	[ "$LOWBATT_ACTION" = none ] && return 1
	[ -r "$BATT_CAP" ] || return 1

	# plugged in -> never low
	if [ -r "$BATT_CHG" ]; then
		read -r chg <"$BATT_CHG" 2>/dev/null
		case "$chg" in '' | *[!0-9]*) ;; *) [ "$chg" -ne 0 ] && return 1 ;; esac
	fi

	read -r cap <"$BATT_CAP" 2>/dev/null
	case "$cap" in '' | *[!0-9]*) return 1 ;; esac

	# honor muOS's own threshold; fall back only if it can't be read
	thr=""
	[ -r "$LOWBATT_CONF" ] && read -r thr <"$LOWBATT_CONF" 2>/dev/null
	case "$thr" in '' | *[!0-9]*) thr=$LOWBATT_FALLBACK ;; esac

	[ "$cap" -le "$thr" ] && return 0
	return 1
}

# Panel brightness percentage -> LED byte, on the SAME gamma-2.2 curve the UI's
# brightByte() uses for the manual slider, so "Screen at 80%" and "Direct at 80%"
# land on the identical byte (156). Perceived LED output is ~logarithmic; a linear
# map would crush all the visible change into the bottom of the range.
# Regenerate if BRIGHT_GAMMA ever moves in config.lua:
#   python3 -c "print(' '.join(['0']+[str(max(1,int(255*(p/100)**2.2+0.5))) for p in range(1,101)]))"
BRIGHT_CURVE="0 1 1 1 1 1 1 1 1 1 2 2 2 3 3 4 5 5 6 7 7 8 9 10 11 12 13 14 15 17 18 19 21 22 24 25 27 29 30 32 34 36 38 40 42 44 46 48 51 53 55 58 60 63 66 68 71 74 77 80 83 86 89 92 96 99 102 106 109 113 116 120 124 128 131 135 139 143 148 152 156 160 165 169 174 178 183 188 192 197 202 207 212 217 223 228 233 238 244 249 255"
CURVE_BYTE() { # $1 = 0..100 -> sets CURVE_OUT. No fork: set/shift are builtins.
	# `set --` inside a function only replaces the FUNCTION's positional params,
	# so $1 must be saved before it. Names are sb_-prefixed throughout this block:
	# POSIX sh has no locals, and plain sb/m/p are already used by SYSFS_STATIC
	# and FRONTEND_UP.
	sb_n=$1
	set -- $BRIGHT_CURVE
	shift "$sb_n"
	CURVE_OUT=$1
}

DETECT_SCREEN_BRIGHT() { # sets SCREEN_BRI_FILE / SCREEN_BRI_MAX ("" = none found)
	SCREEN_BRI_FILE=""
	SCREEN_BRI_MAX=255

	# 1. muOS's own setting. Present on every muOS board, and it is the number the
	#    brightness keys actually move - so this is the level the user sees, not a
	#    transient the panel driver is ramping through.
	if [ -r "$MUOS_BRIGHT_VAL" ]; then
		SCREEN_BRI_FILE=$MUOS_BRIGHT_VAL
		sb_m=""
		[ -r "$MUOS_BRIGHT_MAX" ] && read -r sb_m <"$MUOS_BRIGHT_MAX" 2>/dev/null
		# a board that stores a sysfs path in this key (screen/color next to it does
		# exactly that) is not a ceiling - anything but a positive integer means 0-255
		case "$sb_m" in '' | 0 | *[!0-9]*) sb_m=255 ;; esac
		SCREEN_BRI_MAX=$sb_m
		return 0
	fi

	# 2. a standard backlight class node. Unmatched glob stays literal, so the -r
	#    test doubles as the "no match" test.
	for sb_c in "$BACKLIGHT_DIR"/*/brightness; do
		[ -r "$sb_c" ] || continue
		SCREEN_BRI_FILE=$sb_c
		sb_m=""
		[ -r "${sb_c%/*}/max_brightness" ] && read -r sb_m <"${sb_c%/*}/max_brightness" 2>/dev/null
		case "$sb_m" in '' | 0 | *[!0-9]*) sb_m=255 ;; esac
		SCREEN_BRI_MAX=$sb_m
		return 0
	done
	return 1
}

# BRI_BASE = the brightness the modes render at, before the low-battery dim.
# Direct: the slider byte the UI wrote. Screen: the panel's own level, put through
# the same curve. Re-run on the state clock, so the sticks track the brightness
# keys live; falls back to the slider if the read fails or no panel was found.
RESOLVE_BRIGHT() {
	BRI_BASE=$BRI_DIRECT
	[ "$BRIGHT_MODE" = screen ] && [ -n "$SCREEN_BRI_FILE" ] || return 0
	sb_v=""
	read -r sb_v <"$SCREEN_BRI_FILE" 2>/dev/null
	case "$sb_v" in
		'' | *[!0-9]*)
			# Torn or empty read - muOS rewrites this file under a lock
			# (/run/muos/brightness.lock), so we can catch it mid-write. Hold the
			# last good byte instead of snapping back to the manual slider, which
			# would show on the sticks as a flash.
			[ -n "$SCREEN_BRI_LAST" ] && BRI_BASE=$SCREEN_BRI_LAST
			return 0
			;;
	esac
	# inline clamp, not CLAMP(): this runs on the state clock even in react mode,
	# and a command substitution there is a fork. Both operands are unsigned, so
	# only the ceiling can be exceeded (a panel reporting above its own max).
	sb_pct=$((sb_v * 100 / SCREEN_BRI_MAX))
	[ "$sb_pct" -gt 100 ] && sb_pct=100
	# remap into the LED range, then the gamma curve turns that into the byte
	sb_pct=$((SCREEN_LED_FLOOR + (100 - SCREEN_LED_FLOOR) * sb_pct / 100))
	CURVE_BYTE "$sb_pct"
	BRI_BASE=$CURVE_OUT
	SCREEN_BRI_LAST=$CURVE_OUT
}

# ---------------------------------------------------------------- stick react
# Stick React: the ring rests at PULSE_BG, and an arc of PULSE_FG points wherever the
# stick is pushed. The arc is drawn fresh each frame from where the stick points now, so
# it follows instantly and a spin sweeps a clean arc round the ring with no trail. The
# only memory is one fade level per stick: it rises when the stick leaves center (faster
# the harder the push, full color either way) and falls on release, with the arc held
# where the stick last pointed. Inspired by SilkyRGB's "Input Pulse"
# (doughn0/SilkyRGB), whose measured LED angles for this board are used below; the
# effect itself is our own. This is NOT a firmware mode - it is the same per-LED serial
# mode 1 that every static render already uses, just with 16 different colors in the
# packet.

JS_DIR="/dev/input"
JS_STATE="$MUOS_RUN_DIR/rgb_stick.axes"     # reader -> render loop, "LX LY RX RY"
# Wake pipe: the reader writes a line here after every change to JS_STATE, so a settled
# SR_FRAME can block on it (fd 4) instead of ticking 30 times a second. See SR_FRAME.
SR_WAKE="$MUOS_RUN_DIR/rgb_stick.wake"
SR_WAKE_OK=0
SR_IDLE_WAIT=0.3   # longest a settled Stick React sleeps between passes (state polls)
JS_NODE=""
JS_PID=""
SR_OK=0
# Preferred reader: bin/js_reader.py, one long-lived process (~1.5% of a core at 480 MHz
# against ~8% for JS_READER's dd|od fork per batch, on MustardOS's noisy virtual pad).
# JS_PY is emptied for the rest of the session if Python is missing or its reader dies,
# and JS_READER takes over.
JS_PY=""
command -v python3 >/dev/null 2>&1 && [ -r "$APP_DIR/bin/js_reader.py" ] && JS_PY=python3
JS_KIND=""                                   # py | sh: which reader JS_PID is

# Ring geometry, measured on real hardware (SilkyRGB's rg-cubexx profile) and rewritten
# into OUR packet order: slots 0-7 are the right stick, 8-15 the left, exactly how
# SEND_STATIC lays them out - an independent confirmation of that order. The LEDs are
# NOT evenly spaced (gaps run 70/42/43/40/60/35/35/35 degrees), so these are
# measurements, not a formula. Bearings: 0 = up, 90 = right, clockwise.
SR_ANG_R="117 75 5 330 295 260 200 160"
SR_ANG_L="5 330 295 260 200 160 117 75"

SR_FADE=80         # degrees past the LED nearest the stick over which the pulse color
                   # fades into the ring color - THE knob for how wide the arc reads.
                   # The nearest LED is full pulse color at any value; at 80 an LED 35
                   # degrees further on is 58% pulse color and one 80+ away is plain ring
                   # color. Lower is tighter, but a stick between two LEDs hands over
                   # across SR_FADE/2 degrees of travel, so far lower steps LED to LED on
                   # a spin. Device-tuned 2026-09-11: 45 read too tight; widened ~15%
                   # (70 -> 80) on 2026-09-16, which lifts the arc's shoulders and puts
                   # 4-5 LEDs in play at once instead of 3-4.
SR_DEADZONE=30     # % deflection below which the stick counts as centered
SR_DECAY=1200      # fade level lost per frame once the stick is back in the deadzone
                   # (0..10000) -> 9 frames, ~0.3s. THE knob for how quickly the arc
                   # fades out: fade seconds = 10000 / SR_DECAY / 30fps, and higher is
                   # snappier. Device-tuned 2026-09-11: 500 and 600 both trailed.
SR_BG_SCALE=50     # the ring at rest sits at this % of PULSE_BG, so the arc reads
                   # brighter against it (user-tuned 2026-09-16: 70 -> 50 -> 40 -> 50 on
                   # device; 40 was a step too far, 50 is the settled value. Level with
                   # Sparkle's SP_BG_SCALE, which took the same route.)
SR_FRAME_MS=33     # ~30fps: plenty for 8 LEDs a side

# Fade levels and LED activations run 0..10000 - a percentage with two extra decimal
# places - so the arc's falloff times the fade level keeps its precision in integer
# arithmetic. SR_GAMMA is indexed by activation/100.

# (activation/10000)^(1/2.2) -> a 0..255 blend weight; 101 entries indexed by
# activation/100. 2.2 is the exponent BRIGHT_CURVE uses, inverted. The lift keeps the
# edge of the arc and the tail of a fade visible instead of letting them sink into the
# ring color early. A lookup table for the same reason as BRIGHT_CURVE - there is no
# float pow in POSIX sh.
SR_GAMMA="0 31 43 52 59 65 71 76 81 85 90 93 97 101 104 108 111 114 117 120 123 125 128 131 133 136 138 141 143 145 148 150 152 154 156 158 160 162 164 166 168 170 172 174 176 177 179 181 183 184 186 188 189 191 193 194 196 198 199 201 202 204 205 207 208 210 211 213 214 215 217 218 220 221 222 224 225 226 228 229 230 232 233 234 236 237 238 239 241 242 243 244 246 247 248 249 250 251 253 254 255"

# atan(i/64) in whole degrees, i = 0..64 -> 0..45. Good to ~1 degree, far finer than
# 8 LEDs spread around 360 can actually show.
SR_ATAN="0 1 2 3 4 4 5 6 7 8 9 10 11 11 12 13 14 15 16 17 17 18 19 20 21 21 22 23 24 24 25 26 27 27 28 29 29 30 31 31 32 33 33 34 35 35 36 36 37 37 38 39 39 40 40 41 41 42 42 43 43 44 44 45 45"

# nth word of a list, 0-based -> SR_NTH_OUT. Same idiom as CURVE_BYTE.
SR_NTH() { sr_n=$1; shift; shift "$sr_n"; SR_NTH_OUT=$1; }

# Integer square root, Newton from above; ~8 iterations for anything in axis range.
SR_ISQRT() { # n -> SR_SQ
	sr_n=$1
	if [ "$sr_n" -le 0 ]; then SR_SQ=0; return; fi
	sr_r=181                                  # ceil(sqrt(127^2 + 127^2))
	[ "$sr_r" -gt "$sr_n" ] && sr_r=$sr_n
	sr_q=$(( (sr_r + sr_n / sr_r) / 2 ))
	while [ "$sr_q" -lt "$sr_r" ]; do
		sr_r=$sr_q
		sr_q=$(( (sr_r + sr_n / sr_r) / 2 ))
	done
	SR_SQ=$sr_r
}

# Compass bearing of a stick vector (0 = up, 90 = right, clockwise), or -1 when the
# stick is centered. The axis y is raw, i.e. down-positive, so north is -y. POSIX sh has
# no atan2, so fold the vector into the first octant, look the angle up in SR_ATAN and
# unfold it again.
SR_BEARING() { # x y -> SR_DIR
	sr_x=$1; sr_y=$(( 0 - $2 ))
	sr_ax=$sr_x; [ "$sr_ax" -lt 0 ] && sr_ax=$(( 0 - sr_ax ))
	sr_ay=$sr_y; [ "$sr_ay" -lt 0 ] && sr_ay=$(( 0 - sr_ay ))
	if [ "$sr_ax" -eq 0 ] && [ "$sr_ay" -eq 0 ]; then SR_DIR=-1; return; fi
	if [ "$sr_ax" -le "$sr_ay" ]; then
		SR_NTH $(( sr_ax * 64 / sr_ay )) $SR_ATAN; sr_a=$SR_NTH_OUT
	else
		SR_NTH $(( sr_ay * 64 / sr_ax )) $SR_ATAN; sr_a=$(( 90 - SR_NTH_OUT ))
	fi
	if [ "$sr_y" -ge 0 ]; then
		if [ "$sr_x" -ge 0 ]; then SR_DIR=$sr_a; else SR_DIR=$(( 360 - sr_a )); fi
	else
		if [ "$sr_x" -ge 0 ]; then SR_DIR=$(( 180 - sr_a )); else SR_DIR=$(( 180 + sr_a )); fi
	fi
	[ "$SR_DIR" -ge 360 ] && SR_DIR=$(( SR_DIR - 360 ))
}

# Deflection as 0..100%. 125 of the +-127 axis range counts as full travel, so a stick
# that stops just short of its limit (wear, calibration) still reads as 100%.
SR_MAG() { # x y -> SR_PCT
	SR_ISQRT $(( $1 * $1 + $2 * $2 ))
	SR_PCT=$(( SR_SQ * 100 / 125 ))
	[ "$SR_PCT" -gt 100 ] && SR_PCT=100
}

# Advance ONE stick's fade level by a frame. $1 = fade level (0..10000), $2 = the
# bearing its arc is drawn at, $3 = stick bearing now (-1 when centered),
# $4 = deflection %. Sets SR_E and SR_B.
SR_STEP() {
	SR_E=$1 SR_B=$2
	if [ "$3" -ge 0 ] && [ "$4" -gt "$SR_DEADZONE" ]; then
		SR_B=$3                                   # the arc goes where the stick is, at once
		# Ease in: close sr_rate% of the remaining gap each frame, from 5% just past the
		# deadzone to 63% at full travel. Rounded UP so it can never stall, and snapped
		# to full over the last 1%, so every push ends at exactly PULSE_FG - a harder
		# push only gets there sooner.
		sr_rate=$(( 5 + ($4 - SR_DEADZONE) * 58 / (100 - SR_DEADZONE) ))
		SR_E=$(( SR_E + ((10000 - SR_E) * sr_rate + 99) / 100 ))
		[ "$SR_E" -ge 9900 ] && SR_E=10000
	else
		SR_E=$(( SR_E - SR_DECAY ))               # fade out, the arc held where it was
		[ "$SR_E" -lt 0 ] && SR_E=0
	fi
}

# Render ONE ring. $1 = its angle list, $2 = the arc's bearing (-1 = not lit yet),
# $3 = fade level. Sets SR_RGB (24 color bytes in packet order) and SR_SUM (their
# running total, so the frame checksum costs no extra pass). Keeps no state of its own:
# the picture depends only on where the arc points and how far it has faded, which is
# why a spin leaves no trail.
SR_RING() {
	sr_angles=$1; sr_dir=$2; sr_e=$3
	sr_rgb="" sr_sum=0
	sr_lit=0
	[ "$sr_dir" -ge 0 ] && [ "$sr_e" -gt 0 ] && sr_lit=1
	# The falloff is measured from the LED NEAREST the arc's bearing, not from the
	# bearing itself, so that LED is always exactly PULSE_FG. With 8 unevenly spaced LEDs
	# the stick nearly always sits between two, and measuring from the stick left the
	# brightest LED in the widest gap at 56% - the pulse color visibly tinted by the ring
	# color (user-reported 2026-09-11). A stick between two LEDs lights both in
	# proportion, and the nearest LED's distance changes continuously as the stick turns,
	# so nothing jumps.
	sr_dmin=0
	if [ "$sr_lit" = 1 ]; then
		sr_dmin=180
		for sr_ang in $sr_angles; do
			sr_d=$(( sr_ang - sr_dir ))
			[ "$sr_d" -lt 0 ] && sr_d=$(( 0 - sr_d ))
			[ "$sr_d" -gt 180 ] && sr_d=$(( 360 - sr_d ))
			[ "$sr_d" -lt "$sr_dmin" ] && sr_dmin=$sr_d
		done
	fi
	for sr_ang in $sr_angles; do
		sr_p=0
		if [ "$sr_lit" = 1 ]; then
			sr_d=$(( sr_ang - sr_dir ))           # angular distance, shortest way round
			[ "$sr_d" -lt 0 ] && sr_d=$(( 0 - sr_d ))
			[ "$sr_d" -gt 180 ] && sr_d=$(( 360 - sr_d ))
			sr_d=$(( sr_d - sr_dmin ))            # ...measured past the nearest LED
			if [ "$sr_d" -lt "$SR_FADE" ]; then
				# Falloff SQUARED, times the fade level. Squared because SR_GAMMA lifts
				# low activations (10% is already 35% pulse color), and a linear falloff
				# let the edge of the arc glow nearly as strongly as its center.
				sr_f=$(( (SR_FADE - sr_d) * 100 / SR_FADE ))
				sr_v=$(( sr_f * sr_f * sr_e / 10000 ))
				if [ "$sr_v" -ge 100 ]; then
					SR_NTH $(( sr_v / 100 )) $SR_GAMMA; sr_p=$SR_NTH_OUT
				fi
			fi
		fi
		sr_q=$(( (255 - sr_p) * SR_BG_SCALE ))
		sr_cr=$(( (SR_FG_R * sr_p * 100 + SR_BG_R * sr_q) / 25500 ))
		sr_cg=$(( (SR_FG_G * sr_p * 100 + SR_BG_G * sr_q) / 25500 ))
		sr_cb=$(( (SR_FG_B * sr_p * 100 + SR_BG_B * sr_q) / 25500 ))
		sr_rgb="$sr_rgb $sr_cr $sr_cg $sr_cb"
		sr_sum=$(( sr_sum + sr_cr + sr_cg + sr_cb ))
	done
	SR_RGB=$sr_rgb; SR_SUM=$sr_sum
}

# The legacy joystick node. Its index is NOT stable: a CubeXX on muOS exposes js1 with
# no js0 at all (device-confirmed 2026-09-11), so take the first that exists rather
# than assuming js0 the way most reference code does.
JS_FIND() {
	JS_NODE=""
	for sr_j in "$JS_DIR"/js*; do
		[ -r "$sr_j" ] && { JS_NODE=$sr_j; break; }
	done
}

# Background axis reader. Joystick events are 8 raw bytes each - unreadable from the
# shell without od - and the read BLOCKS while the stick is still, which is precisely
# why this lives in its own process: blocking costs nothing here, and the render loop
# only ever reads a 4-number text file (no fork).
#
# THE FD MUST STAY OPEN. joydev only receives events while a client holds the device
# open, and every fresh open replays an INIT burst (13 button events THEN 6 axis
# events on this board) carrying a snapshot that is stale by then. So a per-batch
# `dd if=$JS_NODE` re-read the same 8 button events forever and never once saw an
# axis move, while polling by re-open returned a frozen snapshot. Both were confirmed
# dead on hardware 2026-09-11. Holding fd 3 for the reader's whole life fixes it: the
# driver keeps tracking, and each dd just drains what has queued up since.
#
# Streaming `dd | od | while read` instead is NOT an option: busybox od block-buffers
# its output (measured: four 1s-apart chunks all arrived together), which would lag
# the sticks by ~170 events.
JS_READER() {
	# Drop the daemon's traps first. A background subshell inherits them, so without
	# this, killing the reader could run the parent's EXIT trap from inside the CHILD
	# and delete the daemon's pidfile - after which the next `apply` would happily
	# start a second daemon. dash and bash both decline to do that, but busybox ash is
	# what actually runs here and the guard costs nothing.
	trap - EXIT INT TERM USR1
	# Wake line after every state change (see SR_WAKE). The daemon holds the pipe open
	# read-write, so this open doesn't block, and it drains often, so writes don't either.
	sr_wk=0
	if [ "$SR_WAKE_OK" = 1 ] && exec 5>"$SR_WAKE"; then sr_wk=1; fi
	sr_a0=0 sr_a1=0 sr_a2=0 sr_a3=0
	sr_old="0 0 0 0"     # what SR_START wrote to JS_STATE
	while :; do
		# Die with our daemon. A daemon killed with SIGKILL never runs its EXIT trap,
		# so SR_STOP never fires and this reader would outlive it - still holding the
		# joystick and still writing JS_STATE, which the NEXT daemon's reader also
		# writes. Device-observed: orphans accumulate across restarts. Checked at the
		# TOP so the short-read retry path below is covered too, not just the happy
		# path; we are normally parked in the dd, so it fires on the first event after
		# the daemon goes.
		kill -0 "$SR_OWNER" 2>/dev/null || exit 0
		# bs=512 drains joydev's entire 64-event buffer in one read, so a fast stick
		# cannot outrun us and overflow it. -v is REQUIRED: without it od collapses
		# runs of identical lines to "*" and the parse below silently loses events.
		set -- $(dd bs=512 count=1 2>/dev/null <&3 | od -An -tu1 -v)
		[ $# -ge 8 ] || { sleep 0.25; continue; }
		while [ $# -ge 8 ]; do
			# struct js_event { __u32 time; __s16 value; __u8 type; __u8 number; }
			sr_v=$(( $5 | ($6 << 8) ))
			[ "$sr_v" -gt 32767 ] && sr_v=$(( sr_v - 65536 ))
			# bit 0x80 is the INIT flag on each axis's first event; mask it off
			if [ $(( $7 & 127 )) -eq 2 ]; then
				sr_v=$(( sr_v / 256 ))        # +-32767 -> +-127, plenty for 8 LEDs
				# Since MustardOS 2606.0 86947bd4, js1 is its virtual pad, which repeats
				# the sticks' resting noise (up to +-2 here) ~115 times a second. Zero it,
				# so a still stick leaves the state unchanged and SR_FRAME can idle. Far
				# inside SR_DEADZONE, so nothing visible changes.
				[ "$sr_v" -ge -3 ] && [ "$sr_v" -le 3 ] && sr_v=0
				case "$8" in
					0) sr_a0=$sr_v ;; 1) sr_a1=$sr_v ;;
					2) sr_a2=$sr_v ;; 3) sr_a3=$sr_v ;;
				esac
			fi
			shift 8
		done
		sr_new="$sr_a0 $sr_a1 $sr_a2 $sr_a3"
		if [ "$sr_new" != "$sr_old" ]; then
			printf '%s\n' "$sr_new" >"$JS_STATE"
			sr_old=$sr_new
			[ "$sr_wk" = 1 ] && printf '\n' >&5
		fi
	done
}

SR_RESET() {
	SR_ER=0 SR_EL=0      # fade level per stick, 0..10000
	SR_BR=-1 SR_BL=-1    # the bearing each arc is drawn at (-1 = not lit yet)
	SR_LAST_LINE="__reset__"; SR_LAST_BRI=-1
	LED_FRAME_RESET
}

# Kill readers left behind by a previous daemon: anything running this script, or
# js_reader.py, with fd 3 open on a joystick. A daemon in Stick React holds that fd too, but we run this before
# opening our own, and the atomic pidfile claim means no other daemon is alive - so
# every match is a leftover. No other process on the system runs this script.
SR_REAP_ORPHANS() {
	# One grep picks the candidates (0.01 s); forking a tr for each of ~190 pids took
	# 0.33 s at full clock and ~1 s at powersave, and delayed every switch to Stick
	# React. busybox grep splits cmdline at its NULs, so it over-matches a little; the
	# exact checks below still decide.
	for sr_f in $(grep -l -e rgb_suite.sh -e js_reader.py -e '^dd' /proc/[0-9]*/cmdline 2>/dev/null); do
		sr_p=${sr_f%/cmdline}
		sr_n=${sr_p#/proc/}
		[ "$sr_n" = "$$" ] && continue
		case $( { tr '\0' ' ' <"$sr_p/cmdline"; } 2>/dev/null ) in
			*rgb_suite.sh*|*js_reader.py*)
				# a leftover reader (see above)
				case $(readlink "$sr_p/fd/3" 2>/dev/null) in
					*js[0-9]*|*joystick*) kill "$sr_n" 2>/dev/null ;;
				esac ;;
			dd\ *)
				# the dd that reader was parked in - killing the shell orphans it.
				# Ours cannot be running yet, so any such dd here is a leftover.
				case $(readlink "$sr_p/fd/0" 2>/dev/null) in
					*js[0-9]*|*joystick*) kill "$sr_n" 2>/dev/null ;;
				esac ;;
		esac
	done
}

# muOS builds its OWN virtual pad - js0, minor 0 - and relocates it to
# /dev/muinput/h700-joystick during boot. We start about 5s in, so a plain
# /dev/input/js* glob can grab it mid-move, and the fd then follows the node out of
# /dev/input: the reader ends up on a device that has 6 axes but never reports the
# sticks moving, which looks exactly like "the ring lights but does not react"
# (device-observed 2026-09-11). An open fd knows where it currently lives, so ask the
# kernel rather than trusting the path we opened. Must be called from the DAEMON, not
# the reader: ash keeps $$ as the main shell's pid even inside a subshell.
SR_VALIDATE() {
	case $(readlink "/proc/$$/fd/3" 2>/dev/null) in
		/dev/input/*) return 0 ;;
	esac
	return 1
}

SR_START() {
	[ -n "$JS_PID" ] && kill -0 "$JS_PID" 2>/dev/null && return 0
	JS_FIND
	[ -n "$JS_NODE" ] || { SR_OK=0; return 1; }
	SR_REAP_ORPHANS
	# Opened here, not in the reader, so SR_VALIDATE can check it - and so the device
	# stays open across reader restarts.
	exec 3<"$JS_NODE" || { SR_OK=0; return 1; }
	SR_VALIDATE || { exec 3<&-; SR_OK=0; return 1; }
	SR_OWNER=$$
	SR_LX=0 SR_LY=0 SR_RX=0 SR_RY=0
	printf '0 0 0 0\n' >"$JS_STATE"
	# Opened read-write so neither side blocks on open, and so it never reports EOF.
	SR_WAKE_OK=0
	rm -f "$SR_WAKE"
	mkfifo "$SR_WAKE" 2>/dev/null && exec 4<>"$SR_WAKE" && SR_WAKE_OK=1
	if [ -n "$JS_PY" ]; then
		"$JS_PY" "$APP_DIR/bin/js_reader.py" "$JS_STATE" "$SR_WAKE" &   # reads the inherited fd 3
		JS_KIND=py
	else
		JS_READER &
		JS_KIND=sh
	fi
	JS_PID=$!
	SR_OK=1
}

# Killing the reader shell is not enough on its own: it is parked inside a blocking
# dd, a separate process that would be left orphaned on the joystick node until the
# next stick event killed it with SIGPIPE. Sweep /proc for it, the same way
# FRONTEND_UP looks for muxfrontend. Only ever runs on a mode change or at exit.
SR_STOP() {
	[ -n "$JS_PID" ] || { SR_OK=0; return 0; }
	kill "$JS_PID" 2>/dev/null
	JS_PID=""
	if [ -n "$JS_NODE" ]; then
		# Candidates from one grep, as in SR_REAP_ORPHANS (it over-matches; the checks
		# below decide).
		for sr_f in $(grep -l '^dd' /proc/[0-9]*/cmdline 2>/dev/null); do
			sr_p=${sr_f%/cmdline}
			# The 2>/dev/null must be INSIDE the group: redirections apply left to
			# right, so on a pid that exits mid-sweep the shell reports the failed
			# open before a trailing 2>/dev/null could suppress it. (FRONTEND_UP
			# above has the same cosmetic quirk; left alone, it is not mine to change.)
			sr_c=$( { tr '\0' ' ' <"$sr_p/cmdline"; } 2>/dev/null )
			# Our reader's dd inherits the joystick on ITS STDIN and carries no if=,
			# so match on the fd, not the arguments - React's framebuffer sampler is
			# also a bare `dd` and must never be caught by this.
			case "$sr_c" in dd\ *) ;; *) continue ;; esac
			[ "$(readlink "$sr_p/fd/0" 2>/dev/null)" = "$JS_NODE" ] && kill "${sr_p#/proc/}" 2>/dev/null
		done
	fi
	exec 3<&-
	rm -f "$JS_STATE"
	if [ "$SR_WAKE_OK" = 1 ]; then exec 4<&-; fi
	rm -f "$SR_WAKE"; SR_WAKE_OK=0
	SR_OK=0
}

# Empty the wake pipe without waiting (read -t 0 only peeks in busybox ash; 0.001 really
# reads, and costs ~1 ms once the pipe is empty). Called before a settled wait, and on
# every state poll so lines from a long stretch of movement can't pile up.
SR_DRAIN() {
	[ "$SR_WAKE_OK" = 1 ] || return 0
	while read -r -t 0.001 sr_w <&4; do :; done
}

# Send one per-LED frame, then hold the ~30 fps cadence (SR_FRAME_MS). Shared by
# Stick React and Sparkle. $1 = brightness, $2 = the 48 color bytes in packet order,
# $3 = their sum, $4 = when the frame started (NOW_MS).
#
# Only touch the serial port when the picture actually CHANGED. A centered stick, or a
# ring between glints, renders the same 48 bytes every frame, so a still picture costs
# no writes at all - the LEDs hold their own state between writes. Nothing else writes
# them while MustardOS's RGB mode is External, so there is no periodic resend.
# The brightness is part of the picture: during a fade a still ring changes only in it.
LED_FRAME_RESET() { LF_LAST=""; }
LED_FRAME_OUT() {
	if [ "$1:$2" != "$LF_LAST" ]; then
		SERIAL_PREPARE_ONCE
		# The checksum was accumulated as the colors were built, so the frame needs no
		# second pass and no CHECKSUM subshell.
		SERIAL_WRITE 1 "$1" $2 "$(( (1 + $1 + $3) & 255 ))"
		LF_LAST="$1:$2"
		LAST_OUT=frame; LAST_FRAME=$2; LAST_SUM=$3; LAST_BRI=$1
	fi
	LED_FRAME_PACE "$4"
}

# Pace to the frame deadline ($1 = when the frame started). lf_ms is 5..SR_FRAME_MS, so
# pad the fraction by hand rather than forking printf 30 times a second.
LED_FRAME_PACE() {
	NOW_MS
	lf_ms=$(( SR_FRAME_MS - (NOW - $1) ))
	[ "$lf_ms" -lt 5 ] && lf_ms=5
	if [ "$lf_ms" -lt 10 ]; then sleep "0.00$lf_ms"
	elif [ "$lf_ms" -lt 100 ]; then sleep "0.0$lf_ms"
	else sleep "0.$lf_ms"; fi
}

SR_FRAME() { # $1 = effective brightness
	sr_bri=$1
	[ "$sr_bri" -lt 0 ] && sr_bri=0
	[ "$sr_bri" -gt 255 ] && sr_bri=255
	NOW_MS; sr_t0=$NOW

	# Axes, written by the reader as "LX LY RX RY". A torn or missing line reuses the
	# last good one rather than snapping the ring back to center for a frame.
	sr_line=""
	[ -r "$JS_STATE" ] && read -r sr_line <"$JS_STATE" 2>/dev/null
	set -- $sr_line
	# AXIS ORDER. Axes 0/1 are the left stick and 2/3 the right, x then y, with y
	# down-positive - the near-universal gamepad layout, and what the CubeXX reports
	# (measured 2026-09-11). If a device ever disagrees, this single line is the whole
	# fix: swap the pairs for crossed sticks, or negate a value for an inverted axis.
	if [ $# -eq 4 ]; then SR_LX=$1 SR_LY=$2 SR_RX=$3 SR_RY=$4; fi

	# Nothing moved, the brightness held, and both rings sit at a fixed point (faded out,
	# or fully lit on a held push): this frame would come out identical to the last one,
	# so skip computing it. At rest that is nearly every frame. An empty LF_LAST means
	# the last frame was reset (a wake, a mode start) and must be sent.
	if [ "$sr_line" = "$SR_LAST_LINE" ] && [ "$sr_bri" = "$SR_LAST_BRI" ] && [ -n "$LF_LAST" ] &&
		{ [ "$SR_ER" = 0 ] || [ "$SR_ER" = 10000 ]; } && { [ "$SR_EL" = 0 ] || [ "$SR_EL" = 10000 ]; }; then
		# Settled: sleep until the reader reports a change (or SR_IDLE_WAIT passes, so
		# the loop still polls idle, battery and screen state). Drain first, then look
		# at the axes once more: a change that landed before the drain would otherwise
		# have its wake line eaten and wait out the whole timeout. A signal (an apply
		# from the app) breaks the wait at once (device-checked).
		if [ "$SR_WAKE_OK" = 1 ]; then
			SR_DRAIN
			sr_now=""
			[ -r "$JS_STATE" ] && read -r sr_now <"$JS_STATE" 2>/dev/null
			[ "$sr_now" = "$sr_line" ] && read -r -t "$SR_IDLE_WAIT" sr_w <&4
		else
			LED_FRAME_PACE "$sr_t0"
		fi
		return
	fi
	SR_LAST_LINE=$sr_line; SR_LAST_BRI=$sr_bri

	SR_BEARING "$SR_RX" "$SR_RY"; SR_MAG "$SR_RX" "$SR_RY"
	SR_STEP "$SR_ER" "$SR_BR" "$SR_DIR" "$SR_PCT"; SR_ER=$SR_E SR_BR=$SR_B
	SR_RING "$SR_ANG_R" "$SR_BR" "$SR_ER"
	sr_frame=$SR_RGB; sr_ck=$SR_SUM

	SR_BEARING "$SR_LX" "$SR_LY"; SR_MAG "$SR_LX" "$SR_LY"
	SR_STEP "$SR_EL" "$SR_BL" "$SR_DIR" "$SR_PCT"; SR_EL=$SR_E SR_BL=$SR_B
	SR_RING "$SR_ANG_L" "$SR_BL" "$SR_EL"
	sr_frame="$sr_frame $SR_RGB"; sr_ck=$(( sr_ck + SR_SUM ))

	LED_FRAME_OUT "$sr_bri" "$sr_frame" "$sr_ck" "$sr_t0"
}

# ---------------------------------------------------------------- sparkle
# Sparkle: the rings rest at SPARK_BG and single LEDs glint in SPARK_FG at random, like
# glitter - each glint a short rise and a quicker fall. Speed sets both how often glints
# appear and how long each one lasts. Inspired by the "Shimmer" effect in SilkyRGB
# (Knulli's RGB daemon); this implementation is our own. It sends the same per-LED
# serial mode 1 frames as Stick React, through LED_FRAME_OUT, and borrows SR_NTH.

SP_BG_SCALE=50     # the ring between glints sits at this % of SPARK_BG, so a glint at
                   # full SPARK_FG reads brighter as well as a different color
                   # (user-tuned 2026-09-12: 70 -> 50, for more contrast; 40 tried on
                   # device 2026-09-16 and reverted - 50 is the settled value)

# One glint, as blend weights toward SPARK_FG (0..255), one entry per ~33 ms frame: a
# short rise to full, then a fall that lets go fast and trails off. The table's length IS
# the glint's duration, and it is the same at every speed - Speed drives the interval
# below, not the glint itself. Generated as 255*(k/2)^0.7 up, 255*(1 - j/8)^1.6 down.
SP_ENV="157 255 206 161 120 84 53 28 9"   # 9 frames, ~0.3 s

# Frames from one glint to the next: 0.6 / 0.4 / 0.2 s at ~30 fps, each bent by SP_JITTER
# so the rhythm breathes without wandering. With two sticks the rings take turns, except
# SP_STAY% of the time - the occasional pair on one ring is what keeps the alternation
# from reading as a pattern. At Fast the interval is shorter than a glint, so glints
# overlap: usually one per ring, sometimes two on one (user-tuned 2026-09-12).
SP_INTERVAL_SLOW=18
SP_INTERVAL_MED=12
SP_INTERVAL_FAST=6
SP_JITTER=30       # % either side of the interval
SP_STAY=20         # % chance the next glint stays on this ring instead of swapping

# POSIX sh has no RANDOM (busybox ash happens to, but nothing guarantees it), so a small
# LCG with the ANSI C constants. It returns the top 15 bits - an LCG's low bits repeat
# quickly. -> SP_R in 0..32767
SP_RAND() {
	SP_SEED=$(( (SP_SEED * 1103515245 + 12345) % 2147483648 ))
	SP_R=$(( SP_SEED / 65536 ))
}

# On every (re)entry to the mode, including a wake from the idle blank: clear the
# glints, and pick up the speed's shape and rate.
SP_RESET() {
	SP_AGES="-1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1"   # per LED, packet order
	case "$SPEED" in
		slow) SP_INTERVAL=$SP_INTERVAL_SLOW ;;
		fast) SP_INTERVAL=$SP_INTERVAL_FAST ;;
		*)    SP_INTERVAL=$SP_INTERVAL_MED ;;
	esac
	set -- $SP_ENV; SP_LEN=$#
	# Two sticks take turns. A board with one ring mirrors each glint into both halves
	# of the packet instead: the packet always carries 16 LEDs and nothing tells us
	# which half is the real one. SP_RECENT remembers the last picks - half the LEDs in
	# play - so glints keep moving around the ring instead of favoring a corner.
	if [ "${STICK_COUNT:-2}" -ge 2 ]; then
		SP_TWO=1 SP_RECENT_N=8
	else
		# One ring takes EVERY glint rather than every other one, so double its interval:
		# otherwise it would glint twice as often as a ring on a two-stick board, and it
		# is the per-ring rhythm that Speed is set by (user, 2026-09-12).
		SP_TWO=0 SP_RECENT_N=4 SP_INTERVAL=$(( SP_INTERVAL * 2 ))
	fi
	SP_RECENT=""
	# The ring color between glints, worked out once. x70/100 is exactly what the
	# blend below gives at weight 0, so a glint ends on the very color it started from.
	sp_r=$(( SP_BG_R * SP_BG_SCALE / 100 )); sp_g=$(( SP_BG_G * SP_BG_SCALE / 100 ))
	sp_b=$(( SP_BG_B * SP_BG_SCALE / 100 ))
	SP_REST="$sp_r $sp_g $sp_b"; SP_REST_SUM=$(( sp_r + sp_g + sp_b ))
	NOW_MS; SP_SEED=$(( ($$ * 7919 + NOW) % 2147483648 ))
	SP_RAND; SP_SIDE=$(( SP_R % 2 )); [ "$SP_TWO" = 0 ] && SP_SIDE=0
	SP_RAND; SP_WAIT=$(( SP_R % SP_INTERVAL + 1 ))   # don't always glint on frame one
	LED_FRAME_RESET
}

# Choose the LED for the next glint: in whichever ring's turn it is, skipping the ones
# still glinting and the SP_RECENT_N most recently used. -> SP_NEW, or -1 when the whole
# ring is busy. The turn then passes to the other ring.
SP_PICK() {
	SP_NEW=-1
	sp_base=$(( SP_SIDE * 8 ))
	sp_cand="" sp_n=0 sp_k=0
	for sp_a in $SP_AGES; do
		if [ "$sp_k" -ge "$sp_base" ] && [ "$sp_k" -lt $(( sp_base + 8 )) ] && [ "$sp_a" -lt 0 ]; then
			case " $SP_RECENT " in
				*" $sp_k "*) ;;
				*) sp_cand="$sp_cand $sp_k"; sp_n=$(( sp_n + 1 )) ;;
			esac
		fi
		sp_k=$(( sp_k + 1 ))
	done
	if [ "$sp_n" -eq 0 ]; then
		# Every resting LED here was used recently: take one anyway rather than drop the
		# beat - a steady rhythm matters more than the spacing rule.
		sp_k=0
		for sp_a in $SP_AGES; do
			if [ "$sp_k" -ge "$sp_base" ] && [ "$sp_k" -lt $(( sp_base + 8 )) ] && [ "$sp_a" -lt 0 ]; then
				sp_cand="$sp_cand $sp_k"; sp_n=$(( sp_n + 1 ))
			fi
			sp_k=$(( sp_k + 1 ))
		done
	fi
	[ "$sp_n" -eq 0 ] && return
	SP_RAND; set -- $sp_cand; shift $(( SP_R % sp_n )); SP_NEW=$1
	set -- $SP_RECENT $SP_NEW
	while [ $# -gt "$SP_RECENT_N" ]; do shift; done
	SP_RECENT="$*"
	if [ "$SP_TWO" = 1 ]; then
		# Hand the turn to the other ring, except SP_STAY% of the time.
		SP_RAND
		if [ $(( SP_R % 100 )) -ge "$SP_STAY" ]; then SP_SIDE=$(( 1 - SP_SIDE )); fi
	fi
}

SP_FRAME() { # $1 = effective brightness
	sp_bri=$1
	[ "$sp_bri" -lt 0 ] && sp_bri=0
	[ "$sp_bri" -gt 255 ] && sp_bri=255
	NOW_MS; sp_t0=$NOW
	# One glint per interval, not one per ring: the rings take turns inside SP_PICK, so
	# every glint is its own beat. Slots 0-7 are the right ring and 8-15 the left.
	sp_nr=-1 sp_nl=-1
	SP_WAIT=$(( SP_WAIT - 1 ))
	if [ "$SP_WAIT" -le 0 ]; then
		SP_PICK
		sp_nr=$SP_NEW
		if [ "$SP_NEW" -lt 0 ]; then
			SP_WAIT=1                  # the whole ring was busy: try again next frame
		else
			[ "$SP_TWO" = 0 ] && sp_nl=$(( SP_NEW + 8 ))       # one ring: mirror it
			SP_RAND
			# +50 rounds rather than floors: flooring alone shaved about half a frame
			# off every interval, which measured as 0.58 s where 0.6 s was asked for.
			SP_WAIT=$(( (SP_INTERVAL * (100 - SP_JITTER + SP_R % (2 * SP_JITTER + 1)) + 50) / 100 ))
			[ "$SP_WAIT" -lt 1 ] && SP_WAIT=1
		fi
	fi
	sp_ages="" sp_frame="" sp_ck=0 sp_i=0
	for sp_a in $SP_AGES; do
		if [ "$sp_a" -ge 0 ]; then
			sp_a=$(( sp_a + 1 )); [ "$sp_a" -ge "$SP_LEN" ] && sp_a=-1
		elif [ "$sp_i" -eq "$sp_nr" ] || [ "$sp_i" -eq "$sp_nl" ]; then
			sp_a=0
		fi
		if [ "$sp_a" -lt 0 ]; then
			sp_frame="$sp_frame $SP_REST"; sp_ck=$(( sp_ck + SP_REST_SUM ))
		else
			SR_NTH "$sp_a" $SP_ENV; sp_p=$SR_NTH_OUT
			sp_q=$(( (255 - sp_p) * SP_BG_SCALE ))
			sp_cr=$(( (SP_FG_R * sp_p * 100 + SP_BG_R * sp_q) / 25500 ))
			sp_cg=$(( (SP_FG_G * sp_p * 100 + SP_BG_G * sp_q) / 25500 ))
			sp_cb=$(( (SP_FG_B * sp_p * 100 + SP_BG_B * sp_q) / 25500 ))
			sp_frame="$sp_frame $sp_cr $sp_cg $sp_cb"
			sp_ck=$(( sp_ck + sp_cr + sp_cg + sp_cb ))
		fi
		sp_ages="$sp_ages $sp_a"; sp_i=$(( sp_i + 1 ))
	done
	SP_AGES=$sp_ages
	LED_FRAME_OUT "$sp_bri" "$sp_frame" "$sp_ck" "$sp_t0"
}

# ---------------------------------------------------------------- config load
LOAD_CONFIG() {
	# A torn read must NEVER be taken at face value. The UI rewrites settings.cfg in
	# place, so a signal landing mid-rewrite hands us an empty or half-written file:
	# CFG then falls back to its default and we read mode=off, blank the sticks and
	# exit - or read a truncated id like "stickrea", fall through RENDER_ONESHOT to
	# its catch-all, and blank them anyway. Either way the user sees "the LEDs went
	# off until I changed the mode again". Device-reported 2026-09-11. The UI now
	# writes atomically, so this should never fire; it is the belt to that braces,
	# and it costs one sed on a path we already only take on a signal.
	lc_try=0
	while :; do
		lc_mode=$(CFG mode '')
		case "$lc_mode" in
			off|static|breathing|combo|theme|cycle|rainbow|react|stickreact|sparkle) break ;;
		esac
		lc_try=$((lc_try + 1))
		[ "$lc_try" -ge 5 ] && return 0   # keep running whatever we already had
		sleep 0.05
	done
	MODE=$lc_mode
	BRI_DIRECT=$(CLAMP "$(CFG brightness 200)" 0 255)
	BRIGHT_MODE=$(CFG bright_mode screen)   # RESOLVE_BRIGHT falls back to Direct without a backlight
	SPEED=$(CFG speed med)
	COL=$(CFG color 0,208,255)
	COMBO_R=$(CFG combo_r 255,94,19)
	COMBO_L=$(CFG combo_l 138,43,226)
	THEME_COL=$(CFG theme_color 255,170,50)
	LOWBATT_ACTION=$(CFG lowbatt_action none)
	# Stick React: a = the ring at rest, b = the directional pulse (default Cyberpunk).
	PULSE_BG=$(CFG pulse_bg 0,255,255)
	PULSE_FG=$(CFG pulse_fg 255,0,180)
	set -- $(RGB_OF "$PULSE_BG"); SR_BG_R=$1 SR_BG_G=$2 SR_BG_B=$3
	set -- $(RGB_OF "$PULSE_FG"); SR_FG_R=$1 SR_FG_G=$2 SR_FG_B=$3
	# Sparkle: a = the ring at rest, b = the glints (default Galaxy).
	SPARK_BG=$(CFG spark_bg 72,0,255)
	SPARK_FG=$(CFG spark_fg 255,0,200)
	set -- $(RGB_OF "$SPARK_BG"); SP_BG_R=$1 SP_BG_G=$2 SP_BG_B=$3
	set -- $(RGB_OF "$SPARK_FG"); SP_FG_R=$1 SP_FG_G=$2 SP_FG_B=$3
	case "$MODE" in react) IS_REACT=1 ;; *) IS_REACT=0 ;; esac
	case "$MODE" in stickreact) IS_SREACT=1 ;; *) IS_SREACT=0 ;; esac
	case "$MODE" in sparkle) IS_SPARKLE=1 ;; *) IS_SPARKLE=0 ;; esac
	# Both per-LED modes need the serial MCU. The UI hides them on the led_anim backend,
	# but an imported or hand-edited config can still name one - and then SR_START would
	# hold a joystick open and SERIAL_WRITE would push 30 frames a second at a port that
	# isn't there. This one guard keeps the reader, its retry loop and the render
	# dispatch honest; RENDER_ONESHOT paints the mode's static fallback instead.
	[ "$BACKEND" = serial ] || { IS_SREACT=0; IS_SPARKLE=0; }
	RESOLVE_BRIGHT
}

# ---------------------------------------------------------------- daemon setup
# Wait for a supported LED backend to appear (either the serial node or the led_anim
# sysfs tree can be a touch late right after boot), then pick it. Unsupported hardware
# simply falls through and exits.
i=0
while [ ! -d "$LED_SYSFS" ] && [ ! -c "$SERIAL_DEVICE" ] && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
DETECT_BACKEND
[ "$BACKEND" = none ] && exit 0

PID_FILE="$MUOS_RUN_DIR/rgb_suite.pid"

# Only ever delete OUR pidfile. A daemon on its way out used to remove it
# unconditionally, so it could delete the pidfile of the daemon that had just replaced
# it - which then ran untracked, and the next apply would start a second one beside it.
RELEASE_PID() {
	rp=""; read -r rp 2>/dev/null <"$PID_FILE"
	[ "$rp" = "$$" ] && rm -f "$PID_FILE"
}
# Clean up on exit. INT/TERM must EXIT explicitly: a trapped signal does NOT terminate a
# POSIX shell on its own, so without this `kill` would only run the handler and the
# daemon would keep looping (spawning a 2nd instance on the next start). exit here fires
# the EXIT trap.
trap 'SR_STOP; FB_STOP; RELEASE_PID' EXIT
trap 'exit 0' INT TERM

# The UI pokes us to re-read the config and re-render on the next tick. Trapped BEFORE
# we claim the pidfile: once our pid is in it an apply may signal us, and an untrapped
# USR1 kills a shell outright.
NEED_RENDER=1
trap 'NEED_RENDER=1' USR1

# Single instance. The claim is atomic - noclobber only creates the file if it does not
# exist yet - so two daemons started at the same moment (two quick presses while none
# was running) cannot both win.
CLAIM_PID() { ( set -C; echo "$$" >"$PID_FILE" ) 2>/dev/null; }
if ! CLAIM_PID; then
	OLD_PID=""; read -r OLD_PID 2>/dev/null <"$PID_FILE"
	# empty = another daemon is between creating the file and writing its pid
	[ -z "$OLD_PID" ] && { sleep 0.2; read -r OLD_PID 2>/dev/null <"$PID_FILE"; }
	[ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ] && kill -0 "$OLD_PID" 2>/dev/null && exit 0
	rm -f "$PID_FILE"                  # stale: its daemon was killed without cleaning up
	CLAIM_PID || exit 0
fi

# Leave for Off without ever swallowing the next mode. The next press can land while
# we are still on our way out - from Stick React that takes ~1.5s (reader shutdown,
# joystick release) - and `rgbctl apply` then signaled a daemon that was about to exit,
# so the new mode never started: sticks dark, the app showing Stick React
# (device-reproduced 2026-09-11). Every apply writes settings.cfg BEFORE it looks for
# our pid, so finish the slow cleanup, give the pidfile up, and only then read the mode
# one last time. An apply that still saw our pid changed the mode before the rm, and
# that read catches it; one that runs after the rm finds no pidfile and starts a fresh
# daemon itself.
OFF_EXIT() {
	FADE_OUT "$FADE_MS"
	BLANK_LEDS
	FADE_IN_MS=$FADE_MS          # if a mode is picked on the way out, it lights from black
	SR_STOP
	FB_STOP
	rm -f "$PID_FILE"
	[ "$(CFG mode off)" = off ] && exit 0
	# A mode was picked on our way out: stay, unless a fresh daemon has already claimed
	# the pidfile - then it has the job.
	CLAIM_PID || exit 0
	NEED_RENDER=1
}

DETECT_SCREEN_BRIGHT
LOAD_CONFIG
[ "$BACKEND" = serial ] && { SERIAL_PREPARE; sleep 0.1; }
REACT_SETUP
REACT_RESET

# Charge-only boot gate: when the device powers on straight into the charger (was
# off + USB), muOS runs the muxcharge screen, NOT the full frontend - but our init
# hook already started us early, so without this the sticks flash on until muxcharge
# claims the foreground. Blank from the very first frame of such a boot until the
# real frontend (muxfrontend) takes over. boot_mode stays 1 the whole session, so we
# only ARM the gate when muxfrontend isn't already up (guards a mid-session restart),
# and RELEASE it for good once muxcharge has handed off.
FRONTEND_UP() {
	for p in /proc/[0-9]*; do
		c=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
		case "$c" in *muxfrontend*) return 0 ;; esac
	done
	return 1
}
BM_PATH=""
[ -r /opt/muos/device/config/battery/boot_mode ] && read -r BM_PATH </opt/muos/device/config/battery/boot_mode 2>/dev/null
BOOT_CHARGE=0
[ -n "$BM_PATH" ] && [ -r "$BM_PATH" ] && { read -r bm <"$BM_PATH" 2>/dev/null; [ "$bm" = 1 ] && BOOT_CHARGE=1; }
CHARGE_GATE=0
[ "$BOOT_CHARGE" = 1 ] && ! FRONTEND_UP && CHARGE_GATE=1
SEEN_MUXCHARGE=0

LAST_SIG="__init__"
IS_SREACT=0
IS_SPARKLE=0
SR_NEXT_TRY=0
WAS_BLANK=0
NEXT_STATE=0
IDLE=0
LOW=0
CHARGE_SCREEN=0
LB_RED=0       # 1 = low battery with Breathe Red: the red breath replaces the mode
LOOP_LAST=0
WARM_UP=0      # 1 = the MCU may have lost power (a sleep): warm it up before drawing
SCREEN_OFF=0
SLEEPING=0
SLEEP_DARK=0
PREV_MODE=""
FADE_T=0       # current fade level, 0..FADE_MAX (0 at startup: the first light fades in)
FADE_FROM=0    # 1 = a fade-in is running (0 = start one on the next render)
FADE_LAST=0    # when the running fade-in last advanced
FADE_IN_MS=$FADE_MS
LAST_OUT=""; LAST_BRI=0; LAST_FRAME=""; LAST_SUM=0
# Started inside a wake window (e.g. restarted just after a sleep)? Then the file is not
# a new sleep starting.
RW_SEEN=0; [ -e "$RECENT_WAKE" ] && RW_SEEN=1

# ---------------------------------------------------------------- lifecycle loop
while :; do
	if [ "$NEED_RENDER" = 1 ]; then
		NEED_RENDER=0
		LOAD_CONFIG
		# Off = zero footprint: blank the sticks and exit so no daemon lingers.
		# rgbctl apply/start (re)starts us when the app picks a non-Off mode (APPLY
		# starts the daemon when it's down); at boot the init hook starts us, we
		# read Off, blank and exit again. With MustardOS's RGB mode on External nothing
		# else touches the LEDs, so they stay dark. OFF_EXIT returns only
		# when a new mode was picked while we were on our way out.
		if [ "$MODE" = off ]; then OFF_EXIT; PREV_MODE=off; continue; fi
		# A new mode dips through black: the old picture fades out (replayed, so the
		# reload replacing the old mode's variables doesn't matter), the new one fades in.
		# Any other change (color, speed, brightness) applies at once. While the
		# low-battery breath stands in for the mode the picture doesn't change: no dip.
		if [ "$LB_RED" = 0 ] && [ -n "$PREV_MODE" ] && [ "$MODE" != "$PREV_MODE" ] && [ "$FADE_T" -gt 0 ]; then
			FADE_OUT "$MODE_FADE_MS"
			FADE_IN_MS=$MODE_FADE_MS
		fi
		PREV_MODE=$MODE
		LAST_SIG="__reload__"          # force the next render to actually send
		[ "$IS_REACT" = 1 ] && REACT_RESET
		if [ "$IS_REACT" = 1 ] && [ "$REACT_OK" = 1 ]; then FB_START; else FB_STOP; fi
		if [ "$IS_SREACT" = 1 ]; then SR_START; SR_RESET; else SR_STOP; fi
		[ "$IS_SPARKLE" = 1 ] && SP_RESET
	fi

	# Re-poll the slow-changing idle/battery state at most every STATE_INTERVAL_MS.
	# NOW_MS is a builtin read (no fork); the cached IDLE/LOW are reused between checks.
	NOW_MS
	# /proc/uptime counts time spent suspended, so a big jump since the last pass means
	# the device slept. MustardOS doesn't set idle_state for a power-button sleep, and
	# the board may have dropped the LED MCU's power meanwhile, so take the
	# wake-from-blank path: re-power the MCU and redraw. Costs no extra read.
	if [ "$LOOP_LAST" -gt 0 ] && [ $((NOW - LOOP_LAST)) -ge "$RESUME_GAP_MS" ]; then
		WAS_BLANK=1; WARM_UP=1; SLEEPING=0; NEXT_STATE=0
	fi
	LOOP_LAST=$NOW
	if [ "$NOW" -ge "$NEXT_STATE" ]; then
		READ_IDLE; IDLE=$IDLE_VAL
		if SCREEN_OFF_NOW; then SCREEN_OFF=1; else SCREEN_OFF=0; fi
		[ "$IS_SREACT" = 1 ] && SR_DRAIN
		if BATTERY_LOW; then LOW=1; else LOW=0; fi
		RESOLVE_BRIGHT
		# Charge screen active right now? (foreground == muxcharge). Combined with
		# CHARGE_GATE below - which also covers the pre-muxcharge boot ramp - this
		# mirrors muOS's own charge.sh (LED off) -> frontend.sh (LED restore).
		CHARGE_SCREEN=0; fg=""
		[ -r "$FG_PROC" ] && read -r fg <"$FG_PROC" 2>/dev/null
		[ "$fg" = muxcharge ] && CHARGE_SCREEN=1
		# Release the charge-boot gate for good once muxcharge has handed off to a
		# real frontend (we saw muxcharge, and foreground is now something else).
		if [ "$CHARGE_GATE" = 1 ]; then
			[ "$CHARGE_SCREEN" = 1 ] && SEEN_MUXCHARGE=1
			[ "$SEEN_MUXCHARGE" = 1 ] && [ "$CHARGE_SCREEN" = 0 ] && [ -n "$fg" ] && CHARGE_GATE=0
		fi
		# Stick React: keep trying until a real joystick is up, and keep checking the
		# one we hold hasn't been relocated out from under us. Both happen during the
		# boot window, and without this the mode sits on its static fallback until the
		# user changes mode by hand. Throttled to 2s - SR_START scans /proc.
		if [ "$IS_SREACT" = 1 ] && [ "$NOW" -ge "$SR_NEXT_TRY" ]; then
			if [ "$SR_OK" = 1 ]; then
				# Two ways to lose the sticks without noticing: the reader dies (killed,
				# OOM, a stray sweep) or the node moves out from under us. Neither shows
				# up as an error - the render loop just keeps drawing the last axes it
				# saw, so the ring freezes mid-pulse and stays there. Check both.
				# A dead Python reader means Python can't do the job here: stay on the
				# shell reader for the rest of the session rather than respawn it.
				if ! kill -0 "$JS_PID" 2>/dev/null && [ "$JS_KIND" = py ]; then JS_PY=""; fi
				if ! kill -0 "$JS_PID" 2>/dev/null || ! SR_VALIDATE; then
					SR_STOP; SR_START && SR_RESET
				fi
			else
				SR_START && SR_RESET
			fi
			SR_NEXT_TRY=$((NOW + 2000))
		fi
		NEXT_STATE=$((NOW + STATE_INTERVAL_MS))
	fi

	# gross on/off: idle, screen off & the charge screen/boot-gate always win, then battery=off
	BLANK=0
	if [ "$IDLE" != 0 ] || [ "$SCREEN_OFF" = 1 ] || [ "$CHARGE_SCREEN" = 1 ] || [ "$CHARGE_GATE" = 1 ]; then
		BLANK=1
	elif [ "$LOW" = 1 ] && [ "$LOWBATT_ACTION" = off ]; then
		BLANK=1
	fi

	if [ "$BLANK" = 1 ]; then
		if [ "$LAST_SIG" != "blank" ]; then
			FADE_OUT "$FADE_MS"
			BLANK_LEDS; LAST_SIG="blank"
			FADE_IN_MS=$FADE_MS
		fi
		WAS_BLANK=1
		[ "$SCREEN_OFF" = 1 ] && WARM_UP=1   # a sleep may cut the MCU's power
		# Through a sleep, poll at the normal pace so the sticks relight with the screen
		# rather than up to a second after it.
		if [ "$SCREEN_OFF" = 1 ]; then sleep "$POLL_SLEEP"; else sleep 1; fi
		continue
	fi

	# effective brightness (battery=dim halves it)
	EFF_BRI=$BRI_BASE
	[ "$LOW" = 1 ] && [ "$LOWBATT_ACTION" = dim ] && EFF_BRI=$((BRI_BASE / 2))

	# battery=breathe: the red breath takes over from the mode and hands it back on
	# charge. Either way it dips through black like a mode switch; after a blank (FADE_T
	# at 0) the new picture just fades in. The mode's helpers keep running meanwhile, as
	# they do through a blank, and its effect restarts fresh, as after a wake.
	LB_NOW=0
	[ "$LOW" = 1 ] && [ "$LOWBATT_ACTION" = breathe ] && LB_NOW=1
	if [ "$LB_NOW" != "$LB_RED" ]; then
		if [ "$FADE_T" -gt 0 ]; then FADE_OUT "$MODE_FADE_MS"; FADE_IN_MS=$MODE_FADE_MS; fi
		LB_RED=$LB_NOW
		LAST_SIG="__reload__"
		if [ "$LB_RED" = 0 ]; then
			[ "$IS_REACT" = 1 ] && REACT_RESET
			[ "$IS_SREACT" = 1 ] && SR_RESET
			[ "$IS_SPARKLE" = 1 ] && SP_RESET
		fi
	fi

	# resuming from a blank: re-assert the MCU (serial only), debounce React wakes
	if [ "$WAS_BLANK" = 1 ]; then
		# re-power the MCU; after a sleep it may have lost power, so give it its warm-up
		[ "$BACKEND" = serial ] && { SERIAL_PREPARE; [ "$WARM_UP" = 1 ] && sleep 0.1; }
		WARM_UP=0
		if [ "$IS_REACT" = 1 ]; then
			# muOS briefly wakes then re-idles on the first input after dimming;
			# confirm the wake is sustained so the sticks don't flash for a frame
			sleep 0.2
			READ_IDLE
			# re-idled: refresh the cached state so the next pass blanks directly
			if [ "$IDLE_VAL" != 0 ]; then IDLE=$IDLE_VAL; NEXT_STATE=0; continue; fi
			NEXT_STATE=0          # sustained wake: force a fresh state read next iteration
			REACT_RESET
		fi
		# Same idea for Stick React: come back from a blank with a cold ring rather
		# than whatever was lit when the screen dimmed.
		[ "$IS_SREACT" = 1 ] && SR_RESET
		[ "$IS_SPARKLE" = 1 ] && SP_RESET
		WAS_BLANK=0
		LAST_SIG="__reload__"
	fi

	# Fade-in: after startup, a blank or a mode switch FADE_T is 0, and it climbs to full
	# over FADE_IN_MS by the clock. Each pass counts at most FADE_STALL_MS, so a pass that
	# stalls (a Stick React restart, a busy CPU) slows the fade down rather than skipping
	# it - with a 200 ms mode-switch fade, one slow pass used to jump straight to full.
	# Every mode draws at OUT_BRI, so the live picture brightens - React keeps reacting.
	if [ "$FADE_T" -lt "$FADE_MAX" ]; then
		NOW_MS
		[ "$FADE_FROM" = 0 ] && { FADE_FROM=1; FADE_LAST=$NOW; }   # starts at 0 this pass
		fd_ms=$((NOW - FADE_LAST)); [ "$fd_ms" -gt "$FADE_STALL_MS" ] && fd_ms=$FADE_STALL_MS
		FADE_T=$(( FADE_T + fd_ms * FADE_MAX / FADE_IN_MS ))
		FADE_LAST=$NOW
		[ "$FADE_T" -ge "$FADE_MAX" ] && { FADE_T=$FADE_MAX; FADE_FROM=0; }
	fi
	OUT_BRI=$(( EFF_BRI * FADE_T / FADE_MAX * FADE_T / FADE_MAX ))

	if [ "$LB_RED" = 0 ] && [ "$IS_REACT" = 1 ] && [ "$REACT_OK" = 1 ]; then
		REACT_FRAME "$OUT_BRI"
		LAST_SIG="react"
	elif [ "$LB_RED" = 0 ] && [ "$IS_SREACT" = 1 ] && [ "$SR_OK" = 1 ]; then
		SR_FRAME "$OUT_BRI"
		LAST_SIG="stick"
	elif [ "$LB_RED" = 0 ] && [ "$IS_SPARKLE" = 1 ]; then
		SP_FRAME "$OUT_BRI"
		LAST_SIG="sparkle"
	else
		# Static colors, firmware animations and the low-battery breath hold on their
		# own once sent, and nothing else writes the LEDs while MustardOS's RGB mode is
		# External, so send only when the picture changes: a config reload, a wake or a
		# low-battery switch (all set LAST_SIG to __reload__) or a new output brightness
		# (fade step, battery dim, Screen mode). A brightness-only change replays the
		# last picture instead of re-rendering it, which saves RENDER_ONESHOT's forks on
		# every fade step.
		oneshot_sig="live:$OUT_BRI"
		if [ "$LAST_SIG" != "$oneshot_sig" ]; then
			case "$LAST_SIG" in
				live:*) REPLAY_AT "$OUT_BRI" ;;
				*) if [ "$LB_RED" = 1 ]; then LB_RENDER "$OUT_BRI"; else RENDER_ONESHOT "$OUT_BRI"; fi ;;
			esac
			LAST_SIG=$oneshot_sig
		fi
		if [ "$FADE_T" -lt "$FADE_MAX" ]; then sleep 0.033; else sleep "$POLL_SLEEP"; fi
	fi
done
