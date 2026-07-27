#!/usr/bin/env python3
"""scripts/hb_checkradio_probe.py — pixel probe for <input type=checkbox|radio>
SHAPES in the native browser's real pixel painter (lib/htmlpage + lib/htmlpaint).

Reads a P6 PPM (rendered by user/hambrowse_host_gfx.ad) and inspects the LEFT
widget column where the form controls paint. Each control is a small box drawn
at the start of its line. We cluster the ink pixels in that column into rows and,
per control (top to bottom), report:

  CTRL i=<n> y=<top> shape=<SQUARE|CIRCLE> checked=<0|1> w=<px> h=<px>

  * shape: a checkbox is a (rounded) SQUARE — its top edge is a horizontal border
    line several px wide; a radio is a CIRCLE — the top of the arc is ~1px wide.
    We classify by the ink width along the box's TOP row.
  * checked: the accent fill colour rgb(26,115,232) is present inside the box
    (a filled checkbox, or a radio's centre dot).

Exit status is always 0; the calling gate parses these lines and asserts.

USAGE
  hb_checkradio_probe.py FILE.ppm
"""
import sys


ACCENT = (26, 115, 232)


def _read_ppm(path):
    f = open(path, "rb")
    magic = f.readline().strip()
    if magic != b"P6":
        sys.stderr.write("not a P6 PPM\n")
        sys.exit(2)
    # skip comment lines
    dims = f.readline()
    while dims.startswith(b"#"):
        dims = f.readline()
    w, h = map(int, dims.split())
    f.readline()  # maxval
    data = f.read()
    return w, h, data


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: hb_checkradio_probe.py FILE.ppm\n")
        sys.exit(2)
    w, h, data = _read_ppm(sys.argv[1])

    def px(x, y):
        i = (y * w + x) * 3
        return (data[i], data[i + 1], data[i + 2])

    def ink(x, y):
        p = px(x, y)
        return not all(c > 225 for c in p)

    def is_accent(x, y):
        p = px(x, y)
        return all(abs(p[i] - ACCENT[i]) <= 45 for i in range(3))

    # The controls paint in the left column; scan a narrow x window for ink and
    # cluster into control row-bands (rows separated by a vertical gap). The
    # window stops before the text label so a wide glyph run can't be mistaken
    # for a control box.
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
        # split on ANY blank row: consecutive controls in this fixture are only
        # ~4 blank rows apart, so the old >5 threshold merged all four into one
        # over-tall band that the size filter then discarded (0 controls found).
        # A control's own side borders ink every one of its rows, so a single
        # blank row is always a real inter-control gap.
        if cur and y - cur[-1] > 1:
            bands.append(cur)
            cur = []
        cur.append(y)
    if cur:
        bands.append(cur)

    i = 0
    for b in bands:
        y0, y1 = b[0], b[-1]
        # bbox of ink in the widget window over this band
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
        # a control box is a small square/circle; ignore stray text glyph runs.
        if bw < 9 or bw > 20 or bh < 9 or bh > 20:
            continue
        # top-edge ink run width -> SQUARE (wide) vs CIRCLE (narrow apex)
        top_w = sum(1 for x in range(bx0, bx1 + 1) if ink(x, y0))
        shape = "SQUARE" if top_w >= 5 else "CIRCLE"
        # accent present anywhere inside the box?
        checked = 0
        for y in range(y0, y1 + 1):
            for x in range(bx0, bx1 + 1):
                if is_accent(x, y):
                    checked = 1
                    break
            if checked:
                break
        print("CTRL i=%d y=%d shape=%s checked=%d w=%d h=%d"
              % (i, y0, shape, checked, bw, bh))
        i += 1


if __name__ == "__main__":
    main()
