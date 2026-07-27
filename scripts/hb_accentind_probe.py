#!/usr/bin/env python3
"""scripts/hb_accentind_probe.py — pixel probe for CSS `accent-color` +
`:indeterminate` on <input type=checkbox|radio> in the native browser's real
pixel painter (lib/htmlpage + lib/htmlpaint).

Reads a P6 PPM (rendered by user/hambrowse_host_gfx.ad), clusters the LEFT
widget column into per-control row-bands (same method as hb_checkradio_probe.py)
and, per control top-to-bottom, reports:

  CTRL i=<n> y=<top> shape=<SQUARE|CIRCLE> fill=<#rrggbb|none> dash=<0|1>

  * shape: SQUARE (checkbox) vs CIRCLE (radio), from the top-edge ink width.
  * fill: the dominant SATURATED colour inside the box (the accent fill of a
    checked box / indeterminate box / radio dot), reported as #rrggbb, else none
    for an unchecked/empty control. This is what proves accent-color took effect
    (red vs the UA default blue rgb(26,115,232)).
  * dash: 1 when the box is accent-filled AND its vertical-centre row carries a
    horizontal WHITE run (the `:indeterminate` dash), distinguishing it from a
    plain checked box (whose white ink is a diagonal tick, not a centre bar).

Exit status is always 0; the calling gate parses these lines and asserts.

USAGE
  hb_accentind_probe.py FILE.ppm
"""
import sys


def _read_ppm(path):
    f = open(path, "rb")
    magic = f.readline().strip()
    if magic != b"P6":
        sys.stderr.write("not a P6 PPM\n")
        sys.exit(2)
    dims = f.readline()
    while dims.startswith(b"#"):
        dims = f.readline()
    w, h = map(int, dims.split())
    f.readline()  # maxval
    data = f.read()
    return w, h, data


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: hb_accentind_probe.py FILE.ppm\n")
        sys.exit(2)
    w, h, data = _read_ppm(sys.argv[1])

    def px(x, y):
        i = (y * w + x) * 3
        return (data[i], data[i + 1], data[i + 2])

    def ink(x, y):
        p = px(x, y)
        return not all(c > 225 for c in p)

    def is_white(x, y):
        return all(c > 225 for c in px(x, y))

    def is_saturated(x, y):
        # a strong colour: not near-white, not near-black, and not near-grey
        # (channels far apart OR one channel clearly dominant).
        r, g, b = px(x, y)
        if r > 225 and g > 225 and b > 225:
            return False
        if r < 30 and g < 30 and b < 30:
            return False
        return (max(r, g, b) - min(r, g, b)) > 40

    # Control COLUMN auto-detection. This window used to be pinned to a fixed
    # x range that dated from the old centred-strip page origin (the ~128px
    # "readable measure" gutter that commit 6491eebd removed) — once plain prose
    # rendered full-width from the UA 8px body margin like Chrome, the window sat
    # entirely to the RIGHT of the widgets and the probe classified LABEL GLYPHS
    # instead of controls. Derive the column from the render instead: the form
    # controls are the LEFTMOST ink on the page, so anchor the window on the
    # smallest inked x and take the ~22px the widget occupies. Verified against
    # `chromium --headless`: Chrome paints these inputs at x=12..25 (body margin
    # 8 + the UA 3px/4px control margin); the engine paints them at x=8..21.
    xmin = None
    for y in range(h):
        for x in range(w):
            if ink(x, y):
                if xmin is None or x < xmin:
                    xmin = x
                break
    if xmin is None:
        xmin = 0
    # narrow window for ROW-band detection (must exclude the label glyphs,
    # else every text row inks and the bands merge); wider window for the
    # per-band x extent, which the contiguous-cluster cut below trims.
    XLO, XHI = max(0, xmin - 2), min(w, xmin + 18)
    XWIDE = min(w, xmin + 40)
    rows_with_ink = []
    for y in range(h):
        for x in range(XLO, XHI):
            if ink(x, y):
                rows_with_ink.append(y)
                break

    bands = []
    cur = []
    for y in rows_with_ink:
        if cur and y - cur[-1] > 5:
            bands.append(cur)
            cur = []
        cur.append(y)
    if cur:
        bands.append(cur)

    i = 0
    for b in bands:
        y0, y1 = b[0], b[-1]
        xs = []
        for y in range(y0, y1 + 1):
            for x in range(XLO, XWIDE):
                if ink(x, y):
                    xs.append(x)
        if not xs:
            continue
        # The window is generous enough to also catch the first LABEL glyph, so
        # keep only the contiguous ink cluster that starts at the leftmost column
        # (the widget); a gap of more than 3 blank columns ends it.
        cols = sorted(set(xs))
        bx0 = cols[0]
        bx1 = cols[0]
        for c in cols[1:]:
            if c - bx1 > 3:
                break
            bx1 = c
        bw = bx1 - bx0 + 1
        bh = y1 - y0 + 1
        if bw < 9 or bw > 20 or bh < 9 or bh > 20:
            continue
        top_w = sum(1 for x in range(bx0, bx1 + 1) if ink(x, y0))
        shape = "SQUARE" if top_w >= 5 else "CIRCLE"
        # dominant saturated colour inside the box
        counts = {}
        for y in range(y0, y1 + 1):
            for x in range(bx0, bx1 + 1):
                if is_saturated(x, y):
                    c = px(x, y)
                    counts[c] = counts.get(c, 0) + 1
        if counts:
            c = max(counts, key=counts.get)
            fill = "#%02x%02x%02x" % c
        else:
            fill = "none"
        # indeterminate dash: a filled box whose vertical-centre row has a
        # horizontal white run flanked above+below by fill.
        dash = 0
        if fill != "none":
            ymid = (y0 + y1) // 2
            white_run = 0
            for yy in (ymid - 1, ymid, ymid + 1):
                run = 0
                best = 0
                for x in range(bx0 + 1, bx1):
                    if is_white(x, yy):
                        run += 1
                        best = max(best, run)
                    else:
                        run = 0
                white_run = max(white_run, best)
            if white_run >= 4:
                dash = 1
        print("CTRL i=%d y=%d shape=%s fill=%s dash=%d"
              % (i, y0, shape, fill, dash))
        i += 1


if __name__ == "__main__":
    main()
