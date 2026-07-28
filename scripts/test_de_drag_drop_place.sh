#!/usr/bin/env bash
# scripts/test_de_drag_drop_place.sh — FAST, QEMU-free host gate for the
# drag-from-menu DROP-LOCATION model (#327).
#
# The USER report: dragging an app out of the Applications menu snapped the
# launcher to a FIXED spot next to the Apps button, ignoring where you
# released. The fix makes the RECEIVER (panel or desktop) COMMIT the drop on
# its OWN button RELEASE, at the release coordinate, via the shared pure
# placement helpers in lib/dropplace.ad.
#
# This gate proves, deterministically (no flaky /dev/mouse drag):
#   1. lib/dropplace.ad is pure (extern-free) and its host unit test asserts
#      the panel insertion index TRACKS the drop X (far-right drop APPENDS,
#      NOT a fixed index) and the desktop .desktop body is well-formed.
#   2. The native panel + desktop clients COMMIT on RELEASE at the drop point
#      (no leftover fixed-spot placement), and both still compile native.
#
# Pass marker: RESULT: PASS

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/dropplace_host"
mkdir -p "$OUT"
fail=0
pass() { echo "[dropplace] PASS $*"; }
bad()  { echo "[dropplace] FAIL $*" >&2; fail=1; }

# --- 1. lib is pure -------------------------------------------------------
if grep -qE '^\s*extern\b' lib/dropplace.ad; then
    bad "lib/dropplace.ad contains an 'extern' — it must stay pure/dual-target"
else
    pass "lib/dropplace.ad is extern-free (links host + native)"
fi

# --- 2. host unit test compiles + runs ------------------------------------
echo "[dropplace] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux tests/dropplace_host.ad "$BIN" 2>"$OUT/dropplace_compile.log"; then
    echo "[dropplace] FAIL: host harness did not compile"
    cat "$OUT/dropplace_compile.log"; echo "[dropplace] RESULT: FAIL"; exit 1
fi
pass "host harness compiled -> $BIN"

DUMP="$OUT/dropplace_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[dropplace] FAIL: host harness exited non-zero"; cat "$DUMP"
    echo "[dropplace] RESULT: FAIL"; exit 1
fi
echo "[dropplace] ---- placement output ----"
cat "$DUMP"
echo "[dropplace] --------------------------"

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then pass "$msg"; else
        bad "$msg (missing: $pat)"; fi
}

# Panel placement HONORS the drop X (menu@0, widgets@104/240/360):
assert_grep '^PANEL flow=10 idx=1$'   "drop just past the menu -> index 1"
assert_grep '^PANEL flow=250 idx=3$'  "drop mid-bar -> mid-list index (tracks X)"
assert_grep '^PANEL flow=500 idx=4$'  "far-right drop APPENDS (idx 4) — not a fixed spot"
assert_grep '^PANEL flow=-5 idx=0$'   "drop before everything -> index 0"

# LIVE DROP PREVIEW: the insertion-indicator boundary tracks the cursor and
# sits BETWEEN neighbouring widgets (the visual twin of the insert index).
assert_grep '^PREVIEW flow=10 at=100$'  "preview caret midway after the menu (idx 1)"
assert_grep '^PREVIEW flow=250 at=348$' "preview caret tracks the mid-bar drop (idx 3)"
assert_grep '^PREVIEW flow=500 at=442$' "preview caret past the last widget on a far-right drag"
assert_grep '^PREVIEW flow=-5 at=1$'    "preview caret clamps to the left edge before everything"

# Desktop .desktop launcher body is well-formed.
assert_grep '^\[Desktop Entry\]$'       "desktop entry has the [Desktop Entry] header"
assert_grep '^Name=Text_Editor$'        "desktop entry Name= is the dropped label"
assert_grep '^Exec=/bin/hamtext$'       "desktop entry Exec= is the dropped app"
assert_grep '^Type=Application$'        "desktop entry Type=Application"

# --- 3. native consumers commit on RELEASE at the drop point --------------
# The panel must feed the RELEASE flow coord into the placement, and the old
# fixed-spot placement (append 'just after the menu') must be gone.
if grep -q '_commit_panel_drop(pi, _flow_of(' user/hampanelscene.ad; then
    pass "panel commits the launcher at the RELEASE flow coordinate"
else
    bad "panel does not commit at the release coordinate"
fi
if grep -q 'just after the menu' user/hampanelscene.ad; then
    bad "panel still has the fixed 'just after the menu' placement"
else
    pass "panel's fixed-spot placement is gone"
fi
# LIVE DROP PREVIEW: the panel must render an insertion indicator DURING the
# drag (on pointer-move), not only after release.
if grep -q '_render_drop_preview(bar)' user/hampanelscene.ad \
        && grep -q 'def _render_drop_preview' user/hampanelscene.ad; then
    pass "panel renders a live drop-preview insertion indicator"
else
    bad "panel has no live drop-preview indicator"
fi
if grep -q 'drop_prev_flow = nf' user/hampanelscene.ad; then
    pass "panel updates the drop preview on pointer-move (drag)"
else
    bad "panel does not update the drop preview during the drag"
fi
if grep -q 'dp_panel_insert_boundary' user/hampanelscene.ad; then
    pass "preview resolves the boundary with the shared placement math"
else
    bad "preview does not reuse the shared placement math"
fi
if grep -q '_commit_desk_drop(bx, by)' user/hamdesktop.ad; then
    pass "desktop commits a .desktop launcher at the RELEASE point"
else
    bad "desktop does not commit at the release point"
fi
if grep -q 'from lib.dropplace import' user/hampanelscene.ad \
        && grep -q 'from lib.dropplace import' user/hamdesktop.ad; then
    pass "both clients use the shared lib/dropplace placement helpers"
else
    bad "a client does not import lib/dropplace"
fi

echo "[dropplace] compiling NATIVE panel + desktop consumers ..."
for c in hampanelscene hamdesktop; do
    if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
            "user/${c}.ad" -o "$OUT/${c}.elf" 2>"$OUT/${c}_native.log"; then
        bad "native ${c} did not compile"
        tail -12 "$OUT/${c}_native.log" >&2
    else
        pass "native ${c} compiles"
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "[dropplace] RESULT: PASS"; exit 0
else
    echo "[dropplace] RESULT: FAIL"; exit 1
fi
