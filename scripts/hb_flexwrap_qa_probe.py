#!/usr/bin/env python3
"""scripts/hb_flexwrap_qa_probe.py — on-device-QA regression probe for three real
hambrowse flex/whitespace layout defects, asserted on a RENDERED PNG (not just the
SEG text dump). Runs the host harness on the QA fixture, renders the shared
parse+layout+colour dump to a real image via render_hambrowse_png.py, then LOOKS at
the pixels:

  (1) CARD WRAP  — each `flex:1` card's body text must reflow onto multiple rows
                   INSIDE the card and never bleed into the inter-card gutter
                   (pre-fix the sentence ran one line past the card's right edge).
  (2) NAV GAP    — a `display:flex; gap:20px` nav (no justify-content) must PACK
                   its links at flex-start with the ~20px gutter between them, not
                   spread edge-to-edge across the row (pre-fix the gap was ignored).
  (3) BLOCK GAP  — two margin-less <div>s separated only by whitespace must stack
                   directly adjacent, with NO phantom blank row between them.

USAGE
  hb_flexwrap_qa_probe.py BIN FIX.html WIDTH OUT.png
Prints measurement lines the calling gate asserts on; exit status always 0.
"""
import os
import subprocess
import sys

from PIL import Image

# fixture background colours (must match tests/fixtures/hambrowse_flexwrapqa.html)
C_CARD1 = (0xff, 0x88, 0xcc)   # pink   card 1
C_CARD2 = (0x88, 0xff, 0xcc)   # mint   card 2
C_NAV   = (0xff, 0xee, 0x00)   # nav link ink (yellow on navy bar)
C_W1    = (0xff, 0x44, 0x44)   # red    first whitespace-block
C_W2    = (0x44, 0x66, 0xff)   # blue   second whitespace-block
C_DARK  = (16, 16, 16)         # default body text ink


def _close(a, b, tol=40):
    return all(abs(a[i] - b[i]) <= tol for i in range(3))


def _bbox(px, W, H, c, x0=0, x1=None, y0=0, y1=None, tol=40):
    x1 = W if x1 is None else x1
    y1 = H if y1 is None else y1
    mnx = mny = 10 ** 9
    mxx = mxy = -1
    n = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            if _close(px[x, y], c, tol):
                n += 1
                mnx = min(mnx, x); mny = min(mny, y)
                mxx = max(mxx, x); mxy = max(mxy, y)
    if n == 0:
        return None
    return (mnx, mny, mxx, mxy, n)


def main():
    if len(sys.argv) < 5:
        sys.stderr.write("usage: hb_flexwrap_qa_probe.py BIN FIX WIDTH OUT.png\n")
        sys.exit(2)
    binp, fix, width, outpng = sys.argv[1:5]
    here = os.path.dirname(os.path.abspath(__file__))
    render = os.path.join(here, "render_hambrowse_png.py")
    dump = subprocess.run([binp, fix, str(width)],
                          capture_output=True, text=True).stdout
    subprocess.run([sys.executable, render, outpng], input=dump, text=True, check=True)

    img = Image.open(outpng).convert("RGB")
    px = img.load()
    W, H = img.size

    # ---- (1) card wrap + no bleed --------------------------------------------
    c1 = _bbox(px, W, H, C_CARD1)
    c2 = _bbox(px, W, H, C_CARD2)
    if c1 and c2:
        l1, t1, r1, b1, _ = c1
        # rows of card-1 body ink (dark) within the card's own x/y band.
        rows = set()
        for y in range(t1, b1 + 1):
            for x in range(l1, r1 + 1):
                if _close(px[x, y], C_DARK, 60):
                    rows.add(y // 8)          # coarse row bucket
                    break
        # leftmost dark ink of card 2 (its text start) — the gutter ends there.
        c2_text_l = 10 ** 9
        for y in range(c2[1], c2[3] + 1):
            for x in range(c2[0], c2[2] + 1):
                if _close(px[x, y], C_DARK, 60):
                    c2_text_l = min(c2_text_l, x)
        # bleed = card-1 dark ink in the gutter strip (right of card1 bg, left of
        # card2's text). Contained text leaves this strip empty.
        gl, gr = r1 + 1, min(c2_text_l - 1, c2[0] + (c2[2] - c2[0]) // 4)
        bleed = 0
        for y in range(t1, b1 + 1):
            for x in range(gl, gr + 1):
                if _close(px[x, y], C_DARK, 60):
                    bleed += 1
        print("CARD1 ink_rows=%d bleed_px=%d gutter=%d-%d" %
              (len(rows), bleed, gl, gr))
    else:
        print("CARD1 ink_rows=0 bleed_px=-1 gutter=0-0")

    # ---- (2) nav gap: read the ITEMS off the engine's own display list --------
    # This used to cluster yellow ink columns in the PREVIEW png. That render
    # draws PROPORTIONAL glyphs at the engine's 8px-char-grid x positions, so an
    # item's ink is narrower than the cell run it was laid out in and the leftover
    # slack lands in the inter-item gutter — two neighbours merged into one
    # "item" and the measured gutters came out as 16/20 instead of 20/20/20.
    # (Same host-preview trap the framediff docs warn about.) The flex `gap` is a
    # LAYOUT property, so assert it on the layout: each nav link is its own SEG
    # at the link ink colour, and the gap is the distance from one segment's
    # mono-grid right edge to the next segment's left edge.
    # Chrome (`getBoundingClientRect`) puts the four links at x = 8 / 67.1 /
    # 127.1 / 178.2 — i.e. a 20px gutter between adjacent border boxes, exactly
    # what the engine lays out at 8 / 60 / 120 / 172 with its narrower mono runs.
    CELL_W = 8
    nav_hex = "#%02x%02x%02x" % C_NAV
    items = []
    for ln in dump.splitlines():
        if not ln.startswith("SEG "):
            continue
        t = ln.split(" ", 4)
        if len(t) < 5 or t[3].lower() != nav_hex:
            continue
        bar = ln.find("|")
        if bar < 0 or not ln.endswith("|"):
            continue
        text = ln[bar + 1:-1]
        try:
            x = int(t[2])
        except ValueError:
            continue
        items.append((x, x + len(text) * CELL_W))
    items.sort()
    gaps = [items[i + 1][0] - items[i][1] for i in range(len(items) - 1)]
    print("NAV items=%d gaps=%s" % (len(items), ",".join(str(g) for g in gaps)))

    # ---- (3) whitespace blocks: adjacency ------------------------------------
    w1 = _bbox(px, W, H, C_W1)
    w2 = _bbox(px, W, H, C_W2)
    if w1 and w2:
        print("BLOCKS red_bot=%d blue_top=%d gap=%d" %
              (w1[3], w2[1], w2[1] - w1[3]))
    else:
        print("BLOCKS red_bot=-1 blue_top=-1 gap=-1")


if __name__ == "__main__":
    main()
