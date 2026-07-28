#!/usr/bin/env bash
# scripts/test_hambrowse_ptrevents_host.sh — COORDINATE-driven gate for the
# EVENT-TYPE half of pointer reachability.
#
# WHAT IT CATCHES
# ===============
# The engine decides which elements a pointer press can reach by asking
# _el_has_handler() (lib/web/dom/canvas.ad) whether the element carries a
# handler; only those get wrapped in the synthetic "#__evt_N" link the
# coordinate hit-test resolves. That predicate matched CLICK and nothing else,
# so an element whose only listener is `mousedown` / `mouseover` /
# `pointerdown` — a menu button, a drag handle, a custom slider, an
# outside-click dismisser — was invisible to the hit-test: a press on its
# pixels resolved to HITLINK -1 and no handler ever ran.
#
# The other half of the same gap (an element whose only handler is an inline
# on<evt>="" attribute never getting a DOM record) was fixed earlier by
# _build_handler_els(); this gate covers the event TYPE.
#
# THE ORACLE IS CHROMIUM, NOT US
# ==============================
# Two chromium measurements back the expectations, both reproduced below when
# chromium (and python3 websocket-client) are present, and both SKIPped — never
# failed — when they are not:
#
#   1. WHAT A CLICK DELIVERS. Driving chromium over CDP
#      (Input.dispatchMouseEvent mousePressed+mouseReleased at an element's
#      centre, with the element listening for every candidate type) shows ONE
#      left click delivering NINE events, in this order:
#           pointerover pointerenter mouseover mouseenter
#           pointerdown mousedown pointerup mouseup click
#      We used to deliver only the last of the nine.
#   2. THE SAME FIXTURE. A real click at the same coordinates in chromium runs
#      the mousedown / mouseover / pointerdown handlers of this fixture and
#      leaves the same RAN-* strings in #log that we assert against.
#
# The clicks below run the real native chain a pointer press runs in
# user/hambrowse.ad: htmlpage_hit_link -> he_link_evt_index ->
# he_dom_click_index (the `clickxy X Y` verb of user/hambrowse_host_gfx.ad),
# and the click coordinates are taken from the RENDERED PIXELS (each chip's
# unique flat background colour, then the chip's own ink), never from
# engine-reported geometry.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hambrowse_gfx_pe"
FIX="tests/fixtures/hambrowse_ptrevents.html"
W=640
fail=0

echo "[hb-pe] compiling host gfx driver (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$BIN" 2>"$OUT/pe_compile.log"; then
    echo "[hb-pe] FAIL: host gfx driver did not compile"; cat "$OUT/pe_compile.log"; exit 1
fi
echo "[hb-pe] PASS host gfx driver compiled"

check() {  # check <label> <got> <op: eq|ne|ge> <expected>
    local label="$1" got="$2" op="$3" exp="$4" ok=1
    case "$op" in
        eq) [ "$got" = "$exp" ] || ok=0 ;;
        ne) [ "$got" != "$exp" ] || ok=0 ;;
        ge) [ "${got:-x}" -ge "$exp" ] 2>/dev/null || ok=0 ;;
    esac
    if [ "$ok" = 1 ]; then
        echo "[hb-pe] PASS $label (got $got)"
    else
        echo "[hb-pe] FAIL $label (got '$got', expected $op '$exp')"; fail=1
    fi
}

"$BIN" "$FIX" "$OUT/pe.ppm" "$W" >/dev/null 2>&1
[ -s "$OUT/pe.ppm" ] || { echo "[hb-pe] FAIL: fixture did not render"; exit 1; }

# ---------------------------------------------------------------------------
# Recover each chip's painted rect from its unique flat background colour, then
# the DARK INK inside that band (the chip's own label glyphs) — the pixels a
# user actually aims at. Prints "name inkx inky" per chip.
# ---------------------------------------------------------------------------
chip_ink() {   # chip_ink <ppm> <name>=<rrggbb> ...
    python3 - "$@" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
i, toks = 0, []
while len(toks) < 4:
    m = re.match(rb'\s*(#[^\n]*\n|\S+)', d[i:]); t = m.group(1); i += m.end()
    if not t.startswith(b'#'): toks.append(t)
w, h = int(toks[1]), int(toks[2]); px = d[i:]
for spec in sys.argv[2:]:
    name, hx = spec.split('=')
    r, g, b = int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16)
    c = bytes([b, r, g])                       # the host driver writes B,R,G
    ys = [y for y in range(h) if c in px[y*w*3:(y+1)*w*3]]
    if not ys:
        print(name, -1, -1); continue
    y0, y1 = min(ys), max(ys)
    # dark ink inside the chip band: every channel well below the pastel bg.
    ink = [(x, y) for y in range(y0, y1 + 1) for x in range(w)
           if px[(y*w+x)*3] < 110 and px[(y*w+x)*3+1] < 110 and px[(y*w+x)*3+2] < 110]
    if not ink:
        print(name, -1, -1); continue
    xs = sorted(set(x for x, _ in ink)); ys2 = sorted(set(y for _, y in ink))
    print(name, xs[len(xs)//2], ys2[len(ys2)//2])
PY
}

hit()  { "$BIN" "$FIX" "$OUT/pe_c.ppm" "$W" clickxy "$1" "$2" 2>/dev/null \
             | awk '/^HITLINK /{ print $2; exit }'; }
ran()  { "$BIN" "$FIX" "$OUT/pe_c.ppm" "$W" clickxy "$1" "$2" 2>/dev/null \
             | grep -c "^SEGTXT $3\$"; }

declare -A INKX INKY
while read -r nm ix iy; do
    [ -n "${nm:-}" ] || continue
    INKX[$nm]="$ix"; INKY[$nm]="$iy"
done < <(chip_ink "$OUT/pe.ppm" md=c8dcf0 ov=f0d2c8 pd=d2f0c8 no=f0e6c8)

for nm in md ov pd no; do
    check "chip $nm painted its label ink" "${INKX[$nm]:--1}" ge 0
done
[ "$fail" = 0 ] || { echo "[hb-pe] RESULT: FAIL (fixture did not paint)"; exit 1; }

# ---------------------------------------------------------------------------
# (1) REACHABILITY: a press on the pixels of an element whose ONLY listener is
#     mousedown / mouseover / pointerdown must resolve to a live target.
# ---------------------------------------------------------------------------
for nm in md ov pd; do
    check "press on the '$nm' chip's pixels resolves to a live target" \
          "$(hit "${INKX[$nm]}" "${INKY[$nm]}")" ge 0
done

# NEGATIVE CONTROL: the chip with no listener at all must stay dead, so this
# gate cannot go green by the engine wrapping every element on the page.
check "the listener-less chip stays dead" \
      "$(hit "${INKX[no]}" "${INKY[no]}")" eq -1

# ---------------------------------------------------------------------------
# (2) DELIVERY: reaching the element is not enough — the press must deliver the
#     event TYPE the listener asked for, so the handler runs and its DOM
#     mutation is painted. Each handler writes "RAN-<chip>" into #log.
# ---------------------------------------------------------------------------
for nm in md ov pd; do
    check "press on '$nm' RAN its ${nm} handler (RAN-$nm painted)" \
          "$(ran "${INKX[$nm]}" "${INKY[$nm]}" "RAN-$nm")" ge 1
done
check "no handler runs for the listener-less chip" \
      "$(ran "${INKX[no]}" "${INKY[no]}" "RAN-md")" eq 0

# ---------------------------------------------------------------------------
# (3) CHROMIUM CROSS-CHECK — a REAL browser, a REAL mouse press, this fixture.
#     Skipped (never failed) without chromium or python3 websocket-client.
# ---------------------------------------------------------------------------
CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
if [ -n "$CHROMIUM" ] && python3 -c "import websocket" 2>/dev/null; then
    XREF="$(python3 - "$CHROMIUM" "$FIX" <<'PY'
import json, os, subprocess, sys, tempfile, time, urllib.request
import websocket

chromium, page = sys.argv[1], os.path.abspath(sys.argv[2])
port = 9331 + (os.getpid() % 400)
prof = tempfile.mkdtemp()
proc = subprocess.Popen([chromium, "--headless=new", "--no-sandbox", "--disable-gpu",
                         f"--remote-debugging-port={port}", f"--user-data-dir={prof}",
                         "--remote-allow-origins=*", "--window-size=640,900",
                         "--hide-scrollbars", "--force-device-scale-factor=1",
                         "about:blank"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    ws_url = None
    for _ in range(200):
        try:
            for t in json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json")):
                if t.get("type") == "page":
                    ws_url = t["webSocketDebuggerUrl"]; break
            if ws_url: break
        except Exception: pass
        time.sleep(0.05)
    if not ws_url: print("SKIP"); sys.exit(0)
    ws = websocket.create_connection(ws_url, timeout=30)
    n = [0]
    def send(method, **params):
        n[0] += 1
        ws.send(json.dumps({"id": n[0], "method": method, "params": params}))
        while True:
            m = json.loads(ws.recv())
            if m.get("id") == n[0]:
                if "error" in m: raise RuntimeError(m["error"])
                return m.get("result", {})
    def ev(expr):
        return send("Runtime.evaluate", expression=expr, returnByValue=True)["result"].get("value")
    send("Page.enable"); send("Runtime.enable")

    # (a) the nine-event order one left click delivers.
    probe = os.path.join(prof, "order.html")
    with open(probe, "w") as fh:
        fh.write("<body style='margin:0'><div id=t style='width:200px;height:60px'>t</div>"
                 "<" + "script>window.L=[];"
                 "['pointerover','pointerenter','mouseover','mouseenter','pointerdown',"
                 "'mousedown','pointerup','mouseup','click'].forEach(function(k){"
                 "document.getElementById('t').addEventListener(k,function(){L.push(k)})})"
                 "</" + "script>")
    send("Page.navigate", url="file://" + probe)
    time.sleep(0.6)
    send("Input.dispatchMouseEvent", type="mousePressed", x=100, y=30, button="left", clickCount=1)
    send("Input.dispatchMouseEvent", type="mouseReleased", x=100, y=30, button="left", clickCount=1)
    time.sleep(0.3)
    order = ev("L.join(',')") or ""

    # (b) the fixture itself: click each chip's centre, read #log back.
    ran = []
    for cid in ("md", "ov", "pd", "no"):
        send("Page.navigate", url="file://" + page)
        time.sleep(0.5)
        r = ev("JSON.stringify(document.getElementById('%s').getBoundingClientRect())" % cid)
        r = json.loads(r)
        x, y = r["left"] + r["width"] / 2, r["top"] + r["height"] / 2
        send("Input.dispatchMouseEvent", type="mousePressed", x=x, y=y, button="left", clickCount=1)
        send("Input.dispatchMouseEvent", type="mouseReleased", x=x, y=y, button="left", clickCount=1)
        time.sleep(0.3)
        ran.append(cid + ":" + (ev("document.getElementById('log').textContent") or ""))
    print("ORDER=" + order + " " + " ".join(ran))
finally:
    proc.terminate()
    try: proc.wait(5)
    except Exception: proc.kill()
PY
)" || XREF="SKIP"
    if [ -z "$XREF" ] || [ "$XREF" = "SKIP" ]; then
        echo "[hb-pe] SKIP chromium xref (no usable CDP target)"
    else
        echo "[hb-pe] chromium says: $XREF"
        want="pointerover,pointerenter,mouseover,mouseenter,pointerdown,mousedown,pointerup,mouseup,click"
        got="$(printf '%s\n' "$XREF" | sed -n 's/^ORDER=\([^ ]*\).*/\1/p')"
        check "chromium: one click delivers the nine-event pointer sequence" \
              "$got" eq "$want"
        for nm in md ov pd; do
            if printf '%s\n' "$XREF" | grep -q "$nm:RAN-$nm"; then
                echo "[hb-pe] PASS chromium runs the '$nm' handler on a real click too"
            else
                echo "[hb-pe] FAIL chromium did NOT run the '$nm' handler (expectation is wrong, not the engine)"
                fail=1
            fi
        done
        if printf '%s\n' "$XREF" | grep -q "no:nohandler"; then
            echo "[hb-pe] PASS chromium leaves the listener-less chip inert too"
        else
            echo "[hb-pe] FAIL chromium did something on the listener-less chip"; fail=1
        fi
    fi
else
    echo "[hb-pe] SKIP chromium xref (no chromium / no python3 websocket-client)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-pe] RESULT: FAIL"; exit 1
fi
echo "[hb-pe] RESULT: PASS"
