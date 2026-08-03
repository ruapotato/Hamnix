#!/usr/bin/env python3
"""_ppm_region_diff.py A.ppm B.ppm — count changed pixels in the window region.

Shared helper extracted from test_de_visual_gate.sh / test_de_office_suite.sh,
which each carried a byte-identical copy of this decoder inline.

Decodes two binary P6 PPMs (QEMU `screendump` output) and prints, on stdout,
the number of pixels inside the CENTRAL window region (middle 70% horizontally,
15%..85% vertically — skipping the top panel band and the screen edges where
the cursor and wallpaper jitter live) that differ by more than THRESH on any
channel.  Prints -1 if either file is unreadable or the geometries differ.
"""
import sys

THRESH = 24


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        return None
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


def main():
    try:
        a, b = load(sys.argv[1]), load(sys.argv[2])
    except (OSError, ValueError, IndexError):
        print(-1)
        return
    if a is None or b is None or a[0] != b[0] or a[1] != b[1]:
        print(-1)
        return
    w, h, pa = a
    _, _, pb = b
    x0, x1 = int(w * 0.15), int(w * 0.85)
    y0, y1 = int(h * 0.15), int(h * 0.85)
    changed = 0
    n = min(len(pa), len(pb))
    for y in range(y0, y1):
        base = y * w * 3
        for x in range(x0, x1):
            i = base + x * 3
            if i + 2 >= n:
                continue
            if (abs(pa[i] - pb[i]) > THRESH
                    or abs(pa[i + 1] - pb[i + 1]) > THRESH
                    or abs(pa[i + 2] - pb[i + 2]) > THRESH):
                changed += 1
    print(changed)


main()
