#!/usr/bin/env bash
# scripts/test_htb_evt_paste_host.sh — FAST, QEMU-free host gate proving the
# X11-style PRIMARY selection works through the LIVE EVENT PATH (task #315),
# not just the clipboard buffer API. The prior gate (test_snarf_primary_host.sh)
# only drove the put/get buffer calls, so it passed even when an app's real
# pointer event loop was broken. THIS gate feeds a raw "m <x> <y> <buttons> <dz>"
# WIRE LINE — the exact bytes the compositor pushes onto a window's /event ring —
# through the SHARED toolkit path the shipped editor/Notes now run:
#   htb_evt_parse_m  ->  htb_box_pointer_decide  ->  paste from the REAL
#   sys/src/9/port/devsnarf.ad PRIMARY buffer  ->  the managed text box mutates.
# A synthetic middle-click (buttons bit2 = 4) must PASTE the PRIMARY selection
# into the box at the caret; a button-1 drag-release must SET it.
#
# It also confirms the editor + Notes (which now call the shared parser +
# middle-edge detector) still compile NATIVE, so the host proof can't drift
# from the shipped on-device code path.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/htb_evt_paste_host"
mkdir -p "$OUT"

echo "[htb-evt] compiling live-event-path host gate (x86_64-linux) ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/htb_evt_paste_host.ad "$BIN" 2>"$OUT/htb_evt_compile.log"; then
    echo "[htb-evt] FAIL: host harness did not compile"
    cat "$OUT/htb_evt_compile.log"; exit 1
fi

echo "[htb-evt] confirming editor + Notes compile NATIVE (shared PRIMARY path) ..."
for app in hameditscene hamnotesscene; do
    if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
            "user/$app.ad" -o "$OUT/${app}_native.elf" \
            2>"$OUT/htb_evt_${app}_native.log"; then
        echo "[htb-evt] FAIL: native $app did not compile"
        cat "$OUT/htb_evt_${app}_native.log"; exit 1
    fi
done
echo "[htb-evt] PASS native compile"

echo "[htb-evt] running live-event-path host gate ..."
DUMP="$OUT/htb_evt_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[htb-evt] host gate reported failures:"; cat "$DUMP"; exit 1
fi
cat "$DUMP"
if ! grep -q "^\[htb-evt\] RESULT PASS" "$DUMP"; then
    echo "[htb-evt] FAIL: RESULT PASS marker missing"; exit 1
fi
echo "PASS: #315 PRIMARY-selection LIVE-EVENT-PATH host gate"
