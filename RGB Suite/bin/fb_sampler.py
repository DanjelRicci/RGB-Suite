#!/usr/bin/env python3
# RGB Suite - Screen React pixel fetcher. Started by bin/rgb_suite.sh (FB_START) while
# Screen React runs:
#
#   fb_sampler.py <framebuffer> <request fifo> <reply fifo> <sticks> <left bound>
#                 <right bound> <px:offset> [<px:offset> ...]
#
# Writes "R" to the reply pipe once it is up, then for every request line reads the
# 4-byte BGRA pixel at each point and replies with the weighted sums SAMPLE needs, on one
# line: "WR WG WB WT" for one stick, "WR_L WG_L WB_L WT_L WR_R WG_R WB_R WT_R" for two.
# The daemon keeps the geometry (REACT_SETUP) and the colour boost (BOOST_COLOUR).
#
# THE WEIGHTING BELOW MIRRORS SAMPLE's SHELL PATH IN rgb_suite.sh - integer maths included.
# Change one, change both; they were checked to give identical targets on the device.
# See ARCHITECTURE.md -> Screen React.
#
# Why Python: the shell sampler forks a subshell + dd + od per pixel, ~180 processes a
# second for 20 points 3 times a second (~0.18 s of CPU per second), and then weighs each
# pixel in shell arithmetic. This does both in well under a millisecond, so more sample
# points cost the daemon next to nothing. rgb_suite.sh falls back to the shell sampler if
# Python is missing or this helper stops answering.

import os
import sys

# Drop every descriptor inherited from the daemon - its read-write ends of our pipes
# among them, which would keep the request pipe "written to" after the daemon dies.
os.closerange(3, 256)

fb = os.open(sys.argv[1], os.O_RDONLY)
# The daemon holds both pipes open read-write, so neither open blocks. When the daemon
# goes, nothing holds the request pipe for writing any more and the read below ends.
req = os.open(sys.argv[2], os.O_RDONLY)
rep = os.open(sys.argv[3], os.O_WRONLY)
sticks = int(sys.argv[4])
left_bound = int(sys.argv[5])
right_bound = int(sys.argv[6])
points = []
for arg in sys.argv[7:]:
    px, off = arg.split(":")
    points.append((int(px), int(off)))
owner = os.getppid()

# One write, so the whole line is in the pipe before the daemon's peek sees it.
os.write(rep, b"R\n")

while True:
    try:
        data = os.read(req, 64)
    except InterruptedError:
        continue
    except OSError:
        break
    if not data or os.getppid() != owner:
        break
    s = [0] * 8   # WR_L WG_L WB_L WT_L WR_R WG_R WB_R WT_R (only the first 4 for one stick)
    for x, off in points:
        p = os.pread(fb, 4, off)
        if len(p) < 3:
            p = b"\0\0\0"
        b, g, r = p[0], p[1], p[2]        # BGRA
        hi = max(r, g, b)
        lo = min(r, g, b)
        w = (hi - lo) * 100 // hi if hi > 0 else 1   # saturation weight, as in SAMPLE
        if w < 1:
            w = 1
        if sticks == 1:
            s[0] += r * w; s[1] += g * w; s[2] += b * w; s[3] += w
        else:
            # the centre band [right_bound, left_bound) counts toward both sticks
            if x < left_bound:
                s[0] += r * w; s[1] += g * w; s[2] += b * w; s[3] += w
            if x >= right_bound:
                s[4] += r * w; s[5] += g * w; s[6] += b * w; s[7] += w
    out = s[:4] if sticks == 1 else s
    try:
        os.write(rep, (" ".join(str(v) for v in out) + "\n").encode())
    except OSError:
        break
