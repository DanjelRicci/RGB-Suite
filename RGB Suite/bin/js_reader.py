#!/usr/bin/env python3
# RGB Suite - Stick React joystick reader. Started by bin/rgb_suite.sh (SR_START) with the
# joystick already open on fd 3; writes "LX LY RX RY" (-127..127) to argv[1] whenever a
# value changes, then a line to the wake pipe argv[2] (if given) so a settled daemon,
# blocked on that pipe, redraws at once. See ARCHITECTURE.md -> Stick React.
#
# Why Python: since MustardOS 2606.0 build 86947bd4, js1 is MustardOS's virtual pad, which
# repeats the sticks' resting noise ~115 times a second. The shell reader forks dd + od for
# every batch, ~50 times a second even with the sticks still (~8% of a core at 480 MHz).
# This one long-lived process does the same work for ~1.5%, with no added latency.
# rgb_suite.sh falls back to its shell reader (JS_READER) if Python is missing or this
# reader dies.

import os
import struct
import sys

STATE = sys.argv[1]
OWNER = os.getppid()   # the daemon

# The daemon holds the pipe open read-write, so this open doesn't block. Non-blocking
# writes: if the pipe is ever full the daemon is awake anyway, so a lost line costs nothing.
wake = -1
if len(sys.argv) > 2:
    try:
        wake = os.open(sys.argv[2], os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        wake = -1

DEADZONE = 3           # out of 127: swallows the resting noise, far inside SR_DEADZONE

axes = [0, 0, 0, 0]
last = None

while True:
    try:
        buf = os.read(3, 512)   # 512 drains joydev's whole 64-event queue in one read
    except InterruptedError:
        continue
    except OSError:
        break
    if not buf:
        break
    # Die with the daemon: a SIGKILLed daemon never runs SR_STOP, and an orphaned reader
    # would keep the joystick open and keep writing the state file.
    if os.getppid() != OWNER:
        break
    for i in range(0, len(buf) - 7, 8):
        # struct js_event { __u32 time; __s16 value; __u8 type; __u8 number; }
        _, value, kind, number = struct.unpack_from("<IhBB", buf, i)
        if kind & 0x7F == 2 and number < 4:      # axis event (0x80 = INIT flag)
            value = int(value / 256)             # truncate toward 0, like the shell reader
            axes[number] = 0 if -DEADZONE <= value <= DEADZONE else value
    if axes != last:
        last = list(axes)
        try:
            with open(STATE, "w") as f:
                f.write("%d %d %d %d\n" % tuple(axes))
        except OSError:
            pass
        if wake >= 0:
            try:
                os.write(wake, b"\n")
            except OSError:
                pass
