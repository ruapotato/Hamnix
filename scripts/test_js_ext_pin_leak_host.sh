#!/usr/bin/env bash
# scripts/test_js_ext_pin_leak_host.sh — QEMU-FREE ratchet on the EXTERNAL-PIN
# LEAK: how many objects a page makes immortal per unit of ordinary work.
#
# WHY THIS GATE EXISTS
# ====================
# lib/web/js/api.ad ext_pin() pins FOREVER every object value handle that
# crosses the js_* API boundary. It is documented as "a leak and never a
# corruption", bounded by "the set that was already immortal". On 2026-08-04
# that bound was measured and found false: a native CONSTRUCTOR builds its
# result with js_new_object_v(), which crosses the boundary, so the immortal
# set is LINEAR IN WHAT THE PAGE DOES.
#
#   * 20,000 `new AbortController()`, every one dropped, pins ~40,600 objects
#     and consumes 41,391 of the 48,000 object slots. AbortController and
#     AbortSignal are built purely from js_new_object_v + js_set_prop; no
#     embedder table ever holds them, so the pin protects nothing.
#   * 8,000 `document.createElement("div")`, never inserted, pins ~25,176 —
#     about 3 immortal objects per detached node. A node the page has dropped
#     and never attached can never be reclaimed.
#
# This is what ends a long-running page, and it is what ends a WPT file: a page
# with NO DOM interaction at all — 4,000 trivial test() calls — dies at 2,211
# subtests, the same wall as the Range files, because testharness.js builds an
# AbortController per Test.
#
# WHY IT IS A RATCHET AND NOT AN ASSERTION OF ZERO
# ===============================================
# The leak is real and OPEN — fixing it means splitting ext_pin into a scoped
# temp-root for transient handles and a traced root set for the embedder's
# tables (see the comment above ext_pin). Until then, asserting zero would be a
# permanently-red gate, which this project has learned reads as noise. So this
# banks TODAY'S numbers as a CEILING: it goes green now, and it goes red the
# moment a change makes the immortal set grow faster. When the leak is fixed,
# drop CEILING_* to the new numbers — the gate is the proof it stayed fixed.
#
# The measurement is the js_arena_stat live-object census (indices 49-54),
# surfaced by hambrowse_host under HAMNIX_JS_ARENA_STATS=1. n_objs alone cannot
# do this: it is an EXTENT that never falls, so a retention bug and a genuine
# working set both read as "n_objs == MAX_OBJ".
#
# ~40 s: engine compile + two small pages.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TAG="[ext-pin-leak]"
OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

# Banked 2026-08-04 on x86_64-linux. Both probes drop every object they make.
#
# N_EL is 8000 and not 20000 because document.createElement has its OWN hard
# per-page ceiling, CRE_MAX=8192, after which it returns null and the page dies
# on the next property access. That is a fifth silent cap on top of the four
# arena ceilings, and it is why this probe must stay under it: a probe that
# trips a DIFFERENT limit measures that limit instead of the one it names.
N_AC=20000
N_EL=8000
CEILING_AC=41000        # objpinned after 20k dropped AbortControllers
CEILING_EL=25500        # objpinned after 8k dropped detached <div>s (~3.07 each)

echo "$TAG compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/extpin_compile.log"; then
    echo "$TAG INCONCLUSIVE: host harness did not compile; nothing was measured."
    cat "$OUT/extpin_compile.log"; exit 125
fi

probe() {   # $1 = name, $2 = iterations, $3 = JS body
    cat > "$OUT/extpin_$1.html" <<EOF
<!doctype html><meta charset=utf-8><title>$1</title>
<script>
var sink = 0;
for (var i = 0; i < $2; i++) { $3 }
console.log("PROBE-DONE " + sink);
</script>
EOF
    HAMNIX_JS_ARENA_STATS=1 timeout 300 "$BIN" "$OUT/extpin_$1.html" 800 \
        > "$OUT/extpin_$1.out" 2>&1
}

read_stat() {   # $1 = out file, $2 = key
    sed -n 's/.*[^a-z]'"$2"'=\([0-9]*\).*/\1/p' "$1" | head -1
}

rc=0

probe ac "$N_AC" 'var c = new AbortController(); sink += c.signal ? 1 : 0;'
if ! grep -q 'PROBE-DONE' "$OUT/extpin_ac.out"; then
    echo "$TAG INCONCLUSIVE: the AbortController probe never finished;"
    echo "$TAG   no census was taken, so there is no reading to judge."
    sed -n '1,10p' "$OUT/extpin_ac.out"; exit 125
fi
AC=$(read_stat "$OUT/extpin_ac.out" objpinned)
[ -n "$AC" ] || { echo "$TAG INCONCLUSIVE: no ARENA census line in the probe output;"
                  echo "$TAG   HAMNIX_JS_ARENA_STATS is the instrument and it said nothing."
                  exit 125; }

probe el "$N_EL" 'var e = document.createElement("div"); sink += e.nodeName.length;'
if ! grep -q 'PROBE-DONE' "$OUT/extpin_el.out"; then
    echo "$TAG INCONCLUSIVE: the createElement probe never finished."
    sed -n '1,10p' "$OUT/extpin_el.out"; exit 125
fi
EL=$(read_stat "$OUT/extpin_el.out" objpinned)
[ -n "$EL" ] || { echo "$TAG INCONCLUSIVE: no ARENA census line in the probe output."; exit 125; }

echo "$TAG $N_AC dropped AbortControllers -> objpinned=$AC (ceiling $CEILING_AC)"
echo "$TAG $N_EL dropped detached <div>s  -> objpinned=$EL (ceiling $CEILING_EL)"

if [ "$AC" -gt "$CEILING_AC" ]; then
    echo "$TAG FAIL: the immortal set per dropped AbortController GREW."
    rc=1
fi
if [ "$EL" -gt "$CEILING_EL" ]; then
    echo "$TAG FAIL: the immortal set per dropped detached element GREW."
    rc=1
fi

if [ "$rc" = 0 ]; then
    echo "$TAG RESULT: PASS (leak did not worsen)"
    echo "$TAG NOTE: these are not healthy numbers, they are BANKED ones. Every"
    echo "$TAG   object counted here was dropped by the page and can never be"
    echo "$TAG   reclaimed. See the comment above ext_pin in lib/web/js/api.ad."
else
    echo "$TAG RESULT: FAIL — ext_pin's immortal set grew; see lib/web/js/api.ad."
fi
exit $rc
