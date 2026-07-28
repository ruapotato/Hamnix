#!/usr/bin/env bash
# scripts/test_hambrowse_flexshrink_host.sh — FAST, QEMU-free gate for the CSS
# Flexbox `flex-shrink` distribution in the native browser engine
# (lib/web/layout/box.ad).
#
# Before this rung `flex-shrink` was PARSED but never applied: when flex items'
# base sizes (flex-basis / content) overflowed the container the engine clamped
# the free space to 0 and every item kept its base size, spilling past the
# container's right edge. Now NEGATIVE free space (overflow) is distributed as
# SHRINKAGE weighted by each item's SCALED flex-shrink factor
# (flex-shrink * flex-basis), mirroring the flex-grow path that distributes
# POSITIVE free space:
#
#   (1) three flex-basis:300px items (flex-shrink:1) OVERFLOW an ~600px row and
#       shrink EQUALLY to fit — the row ends exactly at the container's right
#       edge, no overflow.
#   (2) a flex-shrink:0 item HOLDS its 300px basis while its two shrinkable
#       siblings absorb ALL of the overflow (they end far narrower than it).
#   (3) mixed shrink factors distribute PROPORTIONALLY: flex-shrink:3 loses 3x
#       the width of a same-basis flex-shrink:1 sibling, so it ends narrower.
#
# Boundary (documented): flex-shrink is read from each child's INLINE style="…"
# (or the `flex` shorthand's 2nd number), exactly like flex-grow. Class-resolved
# flex still falls back to the equal-column approximation. Min-content clamping
# floors at 0 (full frozen-item iteration deferred). flex-direction:column stacks
# as normal block flow. Single-level flex only (nested-flex shrink deferred).
#
# Builds BOTH targets (host harness x86_64-linux + native hambrowse
# x86_64-adder-user) so a break in either is caught.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
mkdir -p "$OUT"

echo "[hb-flexshrink] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/compile.log"; then
    echo "[hb-flexshrink] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-flexshrink] PASS host harness compiled -> $BIN"

echo "[hb-flexshrink] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-flexshrink] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-flexshrink] PASS native hambrowse still compiles"

fail=0
D="$OUT/flexshrink.txt"
"$BIN" tests/fixtures/hambrowse_flexshrink.html 800 >"$D" 2>&1 \
    || { echo "[hb-flexshrink] FAIL: render exited non-zero"; cat "$D"; exit 1; }

# FILL <t> <b> <lx> <rx> #rgb <z> — width and right-edge of the FIRST fill of a colour.
fw()  { grep -E "^FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #$1( |\$)" "$D" | awk '{print $5-$4}' | head -1; }
frx() { grep -E "^FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #$1( |\$)" "$D" | awk '{print $5}'    | head -1; }

# The flex container's right edge (all three rows share the same content box).
# At render width 800 a body-level flex row spans the full viewport, so the shrunk
# items end exactly at x=800 (verified: "FILL ... 528 800 #3333cc"). The old 700
# was stale — it predated the full-width bar geometry and made every correctly-
# fitting row read as an overflow. (Chrome would inset by the 8px body margin to
# 792; the engine's separate, consistent full-width-bleed to 800 is out of scope
# here — the point of this gate is that no item spills PAST the container edge.)
RIGHT=800          # container content right edge at render width 800
TOL=6              # px tolerance for the "no overflow past the edge" assertion

# ---- (1) three flex-basis:300 items shrink EQUALLY to fit -------------------
SEA=$(fw aa1111); SEB=$(fw 22bb22); SEC=$(fw 3333cc)
SECRX=$(frx 3333cc)
echo "[hb-flexshrink] equal-shrink widths: SEa=$SEA SEb=$SEB SEc=$SEC  lastRX=$SECRX"
if [ -z "$SEA" ] || [ -z "$SEB" ] || [ -z "$SEC" ]; then
    echo "[hb-flexshrink] FAIL: missing an equal-shrink fill"; cat "$D"; exit 1
fi
d1=$(( SEA - SEB )); d2=$(( SEB - SEC ))
[ "$d1" -lt 0 ] && d1=$(( -d1 )); [ "$d2" -lt 0 ] && d2=$(( -d2 ))
# each shrank well BELOW its 300px basis, they are ~equal, and the row does NOT
# overflow the container's right edge.
if [ "$SEA" -lt 290 ] && [ "$SEA" -gt 120 ] && [ "$d1" -le 20 ] && [ "$d2" -le 20 ] \
   && [ "$SECRX" -le "$(( RIGHT + TOL ))" ]; then
    echo "[hb-flexshrink] PASS three flex-basis:300 items shrink EQUALLY to fit (no overflow)"
else
    echo "[hb-flexshrink] FAIL equal-shrink wrong (SEa=$SEA SEb=$SEB SEc=$SEC lastRX=$SECRX)"; fail=1
fi

# ---- (2) flex-shrink:0 holds its basis; siblings absorb the overflow -------
S0F=$(fw dd4444); S0A=$(fw 55ee55); S0B=$(fw ee55ee)
S0BRX=$(frx ee55ee)
echo "[hb-flexshrink] shrink:0 widths: fixed=$S0F sib1=$S0A sib2=$S0B  lastRX=$S0BRX"
if [ -z "$S0F" ] || [ -z "$S0A" ] || [ -z "$S0B" ]; then
    echo "[hb-flexshrink] FAIL: missing a shrink:0 fill"; cat "$D"; exit 1
fi
sd=$(( S0A - S0B )); [ "$sd" -lt 0 ] && sd=$(( -sd ))
# the flex-shrink:0 item stays near its 300px basis (much wider than the
# shrinkable siblings), the siblings shrank ~equally, and no overflow.
if [ "$S0F" -ge 295 ] && [ "$S0A" -lt "$S0F" ] && [ "$S0B" -lt "$S0F" ] \
   && [ "$sd" -le 20 ] && [ "$S0BRX" -le "$(( RIGHT + TOL ))" ]; then
    echo "[hb-flexshrink] PASS flex-shrink:0 holds its basis while siblings absorb the overflow"
else
    echo "[hb-flexshrink] FAIL shrink:0 distribution wrong (fixed=$S0F sib1=$S0A sib2=$S0B lastRX=$S0BRX)"; fail=1
fi

# ---- (3) mixed shrink factors distribute proportionally --------------------
SMLO=$(fw 661166); SMHI=$(fw 77dd77)
SMHIRX=$(frx 77dd77)
echo "[hb-flexshrink] mixed-shrink widths: shrink1=$SMLO shrink3=$SMHI  lastRX=$SMHIRX"
if [ -z "$SMLO" ] || [ -z "$SMHI" ]; then
    echo "[hb-flexshrink] FAIL: missing a mixed-shrink fill"; cat "$D"; exit 1
fi
# same 500px basis: shrink:3 loses 3x what shrink:1 loses. Two 500px items
# overflow the ~800px row by 200px; that overflow is split 1:3 by scaled shrink
# factor, so shrink:1 -> 450px and shrink:3 -> 350px (Chrome). shrink:3 ends
# clearly narrower, and the row still fits. (The fixture previously used 400px
# bases: 2*400 == the 800px container == ZERO overflow, so there was no free
# space to distribute and the two items rendered near-equal — the fixture, not
# the engine, was wrong; bumped to 500px to actually exercise proportional shrink.)
if [ "$SMLO" -gt "$SMHI" ] && [ "$(( SMLO - SMHI ))" -ge 60 ] \
   && [ "$SMHIRX" -le "$(( RIGHT + TOL ))" ]; then
    echo "[hb-flexshrink] PASS mixed shrink factors distribute proportionally (shrink:3 narrower)"
else
    echo "[hb-flexshrink] FAIL mixed-shrink not proportional (shrink1=$SMLO shrink3=$SMHI lastRX=$SMHIRX)"; fail=1
fi

# ---- control: NO item overflows the container's right edge ------------------
MAXRX=$(grep -E "^FILL [0-9]+ [0-9]+ [0-9]+ [0-9]+ #(aa1111|22bb22|3333cc|dd4444|55ee55|ee55ee|661166|77dd77)( |\$)" "$D" \
        | awk '{print $5}' | sort -n | tail -1)
echo "[hb-flexshrink] max flex-item right edge = $MAXRX (container right ~$RIGHT)"
if [ -n "$MAXRX" ] && [ "$MAXRX" -le "$(( RIGHT + TOL ))" ]; then
    echo "[hb-flexshrink] PASS no flex item overflows the container (was: base sizes spilled past the edge)"
else
    echo "[hb-flexshrink] FAIL an item overflows the container (maxRX=$MAXRX)"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hb-flexshrink] RESULT: FAIL"; exit 1
fi
echo "[hb-flexshrink] RESULT: PASS"
