#!/usr/bin/env python3
"""_crop_new_window.py PRE.ppm POST.ppm OUT.png [--min-area N]

Crops POST to the bounding box of the pixels that CHANGED between PRE and
POST — i.e. to the window that appeared — and writes it as a PNG.

Why this exists
---------------
The release capture launches every app into one long-lived DE session.
Windows cannot be torn down from the driver: `kill <pid>` does not unmap a
scene app's window, and the `free <wid>` verb on /dev/wsys/ctl is behind the
hostowner gate that a serial-console hamsh does not pass.  So by app 20 the
desktop is a pile of 20 overlapping windows and a full-frame screenshot is
useless as documentation.

The newest window is always on TOP and fully visible, so the changed-pixel
bounding box IS that window.  Cropping to it yields a clean, single-window
image without needing any cooperation from the guest.

The top panel band and the bottom taskbar are excluded from the bbox search:
a launch adds a taskbar button and bumps the clock/CPU applet, which would
otherwise stretch the box across the whole screen.
"""
import os
import sys

# Per-channel delta that counts a pixel as "changed". 10, not 24: at 24 the
# window CHROME of an app drawn over a similarly-dark window behind it fell
# below threshold and the crop kept only the app's bright content area
# (Minesweeper came out as a bare grid with no title bar).
THRESH = int(os.environ.get("CROP_THRESH", "10"))
PANEL_H = 26          # top panel, excluded
TASKBAR_H = 34        # bottom taskbar, excluded
MARGIN = 2
BLK = 4               # mask block size for connected-component search


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        raise ValueError("not a P6 PPM: %s" % path)
    idx, toks = 2, []
    while len(toks) < 3:
        while idx < len(data) and data[idx:idx + 1].isspace():
            idx += 1
        if data[idx:idx + 1] == b"#":
            while idx < len(data) and data[idx:idx + 1] != b"\n":
                idx += 1
            continue
        s = idx
        while idx < len(data) and not data[idx:idx + 1].isspace():
            idx += 1
        toks.append(int(data[s:idx]))
    idx += 1
    w, h, _ = toks
    return w, h, data[idx:idx + w * h * 3]


def component_bbox(w, h, pa, pb, thresh):
    # Build a coarse changed-block mask, then take the bbox of the LARGEST
    # CONNECTED COMPONENT rather than of all changed pixels.
    #
    # A plain bbox-of-everything is wrong here: launching an app also
    # REPAINTS THE TITLE BAR of whatever window just lost focus, so the box
    # stretched across both windows (the calculator crop came out containing
    # the whole browser).  The new window is one solid contiguous block; a
    # defocused neighbour's title bar is a separate thin block.
    y0b, y1b = PANEL_H, h - TASKBAR_H
    bw, bh = (w + BLK - 1) // BLK, (y1b - y0b + BLK - 1) // BLK
    mask = bytearray(bw * bh)
    n = min(len(pa), len(pb))
    for y in range(y0b, y1b):
        base = y * w * 3
        by = (y - y0b) // BLK
        rowoff = by * bw
        for x in range(w):
            i = base + x * 3
            if i + 2 >= n:
                continue
            if (abs(pa[i] - pb[i]) > thresh
                    or abs(pa[i + 1] - pb[i + 1]) > thresh
                    or abs(pa[i + 2] - pb[i + 2]) > thresh):
                mask[rowoff + x // BLK] = 1

    best = None
    seen = bytearray(bw * bh)
    for start in range(bw * bh):
        if not mask[start] or seen[start]:
            continue
        stack = [start]
        seen[start] = 1
        cells = 0
        cminx, cminy, cmaxx, cmaxy = bw, bh, -1, -1
        while stack:
            c = stack.pop()
            cy, cx = divmod(c, bw)
            cells += 1
            if cx < cminx:
                cminx = cx
            if cx > cmaxx:
                cmaxx = cx
            if cy < cminy:
                cminy = cy
            if cy > cmaxy:
                cmaxy = cy
            if cx > 0 and mask[c - 1] and not seen[c - 1]:
                seen[c - 1] = 1
                stack.append(c - 1)
            if cx < bw - 1 and mask[c + 1] and not seen[c + 1]:
                seen[c + 1] = 1
                stack.append(c + 1)
            if cy > 0 and mask[c - bw] and not seen[c - bw]:
                seen[c - bw] = 1
                stack.append(c - bw)
            if cy < bh - 1 and mask[c + bw] and not seen[c + bw]:
                seen[c + bw] = 1
                stack.append(c + bw)
        if best is None or cells > best[0]:
            best = (cells, cminx, cminy, cmaxx, cmaxy)

    if best is None:
        return None
    _, cminx, cminy, cmaxx, cmaxy = best
    minx = cminx * BLK
    maxx = min(w - 1, (cmaxx + 1) * BLK - 1)
    miny = y0b + cminy * BLK
    maxy = min(h - 1, y0b + (cmaxy + 1) * BLK - 1)
    return minx, miny, maxx, maxy


def main():
    pre_path, post_path, out_path = sys.argv[1:4]
    min_area = 4000
    if "--min-area" in sys.argv:
        min_area = int(sys.argv[sys.argv.index("--min-area") + 1])

    w, h, pa = load(pre_path)
    w2, h2, pb = load(post_path)
    if (w, h) != (w2, h2):
        print("geometry mismatch", file=sys.stderr)
        return 2

    # Try progressively LOWER thresholds and keep the largest box that is
    # still plausibly one window (< 60% of the screen). A single fixed
    # threshold cannot work for every app: at 24 an app drawn over a
    # similarly-coloured window behind it loses its chrome (Minesweeper
    # cropped to a bare grid, the Video Player to its canvas), while at 3
    # a bright app over the wallpaper can bleed into its own drop shadow.
    box = None
    limit = 0.60 * w * h
    for thr in (int(os.environ["CROP_THRESH"]),) if "CROP_THRESH" in os.environ \
            else (12, 8, 5, 3):
        cand = component_bbox(w, h, pa, pb, thr)
        if cand is None:
            continue
        area = (cand[2] - cand[0]) * (cand[3] - cand[1])
        if area > limit:
            break
        if box is None or area > (box[2] - box[0]) * (box[3] - box[1]):
            box = cand

    if box is None:
        print("no change found", file=sys.stderr)
        return 1
    minx, miny, maxx, maxy = box
    if (maxx - minx) * (maxy - miny) < min_area:
        print("no window-sized change found", file=sys.stderr)
        return 1

    minx = max(0, minx - MARGIN)
    miny = max(0, miny - MARGIN)
    maxx = min(w - 1, maxx + MARGIN)
    maxy = min(h - 1, maxy + MARGIN)

    from PIL import Image
    img = Image.frombytes("RGB", (w, h), bytes(pb[:w * h * 3]))
    img.crop((minx, miny, maxx + 1, maxy + 1)).save(out_path)
    print("%s %dx%d+%d+%d" % (out_path, maxx - minx + 1, maxy - miny + 1,
                              minx, miny))
    return 0


sys.exit(main())
