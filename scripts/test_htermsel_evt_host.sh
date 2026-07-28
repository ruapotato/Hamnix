#!/usr/bin/env bash
# scripts/test_htermsel_evt_host.sh — FAST, QEMU-free gate for the DE
# terminal's OWN pointer-event handling: the raw "m <x> <y> <buttons> <dz>"
# bytes the compositor pushes onto a window's /event ring, in; a published
# PRIMARY selection and a middle-click paste, out.
#
# ASSERTION ALTITUDE — why this gate exists. Nine host gates covered
# highlight-to-middle-click-paste and all nine were green while the feature was
# stone dead on device, because each of them stopped one layer BELOW the code
# that was broken: they call htsel_begin/extend/extract and the clipboard
# put/get by hand. This gate begins at the wire bytes and ends at the real
# kernel clipboard device, so the terminal's own decision logic
# (lib/htermsel.ad::htsel_pointer_step, which hamtermscene now calls) is on the
# path. See user/htermsel_evt_host.ad for the assertion list.
#
# Runs in milliseconds: no DE, no compositor, no mouse injection.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/htermsel_evt_host"
mkdir -p "$OUT"

echo "[htsel-evt] compiling host gate (x86_64-linux) ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/htermsel_evt_host.ad -o "$BIN" 2>"$OUT/htsel_evt_compile.log"; then
    echo "[htsel-evt] FAIL: host harness did not compile"
    cat "$OUT/htsel_evt_compile.log"
    exit 1
fi

echo "[htsel-evt] confirming the shipped terminal still compiles NATIVE ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hamtermscene.ad -o "$OUT/hamtermscene_native.elf" \
        2>"$OUT/htsel_evt_native.log"; then
    echo "[htsel-evt] FAIL: native hamtermscene did not compile"
    cat "$OUT/htsel_evt_native.log"
    exit 1
fi
echo "[htsel-evt] PASS native compile"

# The terminal must actually ROUTE its pointer events through the shared step —
# otherwise this gate would be asserting logic the shipped binary never runs,
# which is exactly the failure mode it was written to end.
if ! grep -q "htsel_pointer_step" user/hamtermscene.ad; then
    echo "[htsel-evt] FAIL: hamtermscene no longer calls htsel_pointer_step —" \
         "this gate would be testing dead code"
    exit 1
fi
echo "[htsel-evt] PASS shipped terminal routes through the tested step"

echo "[htsel-evt] running assertions ..."
"$BIN"
rc=$?
if [ $rc -ne 0 ]; then
    echo "[htsel-evt] RESULT: FAIL"
    exit 1
fi
echo "[htsel-evt] RESULT: PASS"
exit 0
