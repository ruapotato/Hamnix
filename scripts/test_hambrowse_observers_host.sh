#!/usr/bin/env bash
# scripts/test_hambrowse_observers_host.sh — FAST, QEMU-free gate for the DOM
# observer APIs modern frameworks depend on (browser W3C campaign): MutationObserver,
# IntersectionObserver, ResizeObserver.
#
# Proves, on a single headless render of one fixture:
#   * MutationObserver batches childList mutations (append/append/remove) and
#     fires its callback exactly ONCE, as a MICROTASK — i.e. AFTER the mutating
#     script's synchronous code finishes (the 'mo-sync' marker is logged before
#     any 'mo-child' callback line). The batch carries the right added/removed
#     node counts and a stable observer identity.
#   * attributes records carry attributeName + attributeOldValue; attributeFilter
#     limits which attributes are recorded.
#   * disconnect() stops delivery; takeRecords() drains the queue SYNCHRONOUSLY
#     (and the scheduled microtask then finds nothing to deliver).
#   * IntersectionObserver reports isIntersecting=true (ratio>0) for an on-screen
#     element and false for one positioned far off-screen (absolute top:6000px).
#   * ResizeObserver reports a laid-out element's contentRect dimensions.
#
# Delivery model note: this is a HEADLESS single-layout render — IntersectionObserver
# and ResizeObserver deliver ONCE after observe() (no live scroll/resize loop).
# See docs/browser_w3c_conformance.md.
#
# Builds the host harness (x86_64-linux) AND the native browser (x86_64-adder-user)
# with the frozen seed compiler, so a regression in either target fails here with
# no QEMU boot. Exact-output oracle on the script's console.log (JSLOG) lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIX="tests/fixtures/hambrowse_observers.html"
mkdir -p "$OUT"

echo "[hb-obs] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/obs_compile.log"; then
    echo "[hb-obs] FAIL: host harness did not compile"; cat "$OUT/obs_compile.log"; exit 1
fi
echo "[hb-obs] PASS host harness compiled -> $BIN"

echo "[hb-obs] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/obs_native.log"; then
    echo "[hb-obs] FAIL: native hambrowse did not compile"; cat "$OUT/obs_native.log"; exit 1
fi
echo "[hb-obs] PASS native hambrowse still compiles"

fail=0
D0="$OUT/obs_run.txt"
"$BIN" "$FIX" 880 >"$D0" 2>&1 || { echo "[hb-obs] FAIL: render exited non-zero"; cat "$D0"; exit 1; }

grep -E 'JSLOG|JSERR' "$D0" || true

assert_grep() {   # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-obs] PASS $2"
    else
        echo "[hb-obs] FAIL $2 (missing: $1)"; fail=1
    fi
}
assert_nogrep() { # pattern message
    if grep -Eq -- "$1" "$D0"; then
        echo "[hb-obs] FAIL $2 (present: $1)"; fail=1
    else
        echo "[hb-obs] PASS $2"
    fi
}
# line number of the FIRST line matching a pattern (0 if absent)
lineno() { grep -nE -- "$1" "$D0" | head -1 | cut -d: -f1; }

# ---- MutationObserver: batched childList as ONE microtask ------------------
assert_grep '^JSLOG mo-child records 3 added 2 removed 1$' \
    "MutationObserver batches append/append/remove into 3 records (2 added, 1 removed)"
assert_grep '^JSLOG mo-child calls 1 observerok true$' \
    "callback fires exactly ONCE for the batch; 2nd arg is the observer"

# Microtask timing: the synchronous 'mo-sync' marker MUST precede the callback.
SYNC_LN="$(lineno '^JSLOG mo-sync done-mutating$')"
CB_LN="$(lineno '^JSLOG mo-child records ')"
if [ -n "$SYNC_LN" ] && [ -n "$CB_LN" ] && [ "$SYNC_LN" -lt "$CB_LN" ]; then
    echo "[hb-obs] PASS callback is a microtask: fires AFTER the mutating script ($SYNC_LN < $CB_LN)"
else
    echo "[hb-obs] FAIL microtask timing (sync=$SYNC_LN cb=$CB_LN)"; fail=1
fi

# ---- attributes + attributeOldValue + attributeFilter ---------------------
assert_grep '^JSLOG mo-attr records 2 name data-x old v1$' \
    "attributes records carry attributeName + attributeOldValue (2nd write sees old 'v1')"
assert_grep '^JSLOG mo-filter records 1 names data-keep,$' \
    "attributeFilter records only data-keep, excludes data-skip"

# ---- disconnect() + takeRecords() -----------------------------------------
assert_grep '^JSLOG mo-disc synccount 0$'   "disconnect() before mutation -> callback never fires"
assert_nogrep '^JSLOG mo-disc FIRED$'       "disconnected observer delivers nothing"
assert_grep '^JSLOG mo-take taken 1 type childList added 1$' \
    "takeRecords() drains the queue synchronously (1 childList record, 1 added node)"
assert_nogrep '^JSLOG mo-take CB-FIRED'     "after takeRecords drained them, the microtask delivers nothing"

# ---- IntersectionObserver -------------------------------------------------
assert_grep '^JSLOG io vis intersect true ratiopos true$' \
    "IntersectionObserver: on-screen element isIntersecting=true, ratio>0"
assert_grep '^JSLOG io off intersect false ratiopos false$' \
    "IntersectionObserver: far off-screen (top:6000px) element isIntersecting=false"

# ---- ResizeObserver -------------------------------------------------------
assert_grep '^JSLOG ro targetok true w true h true$' \
    "ResizeObserver: entry.target + contentRect width/height of the laid-out box"

# No uncaught JS error anywhere.
assert_nogrep '^JSERR'   "no uncaught JS error across the observers script"
assert_nogrep 'Uncaught' "no 'Uncaught' error from a missing observer API"

if [ "$fail" -ne 0 ]; then
    echo "[hb-obs] RESULT: FAIL"; exit 1
fi
echo "[hb-obs] RESULT: PASS"
