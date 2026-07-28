#!/usr/bin/env bash
# scripts/test_adder_hamstr.sh — owning-heap String METHODS (lib/hamstr.ad)
# correctness gate, on the real on-device x86_64-adder-user target under QEMU.
#
# lib/hamstr.ad is a PURE LIBRARY over lib/hamalloc.ad (the heap) +
# lib/strview.ad (the views): case folding, trim, a zero-copy split iterator,
# search/replace, and integer stringification. This gate drives
# tests/hamstr/test_hamstr_methods.ad, which exercises EVERY method against an
# asserted expected output, frees each owning result, and churns 2000 more
# allocations to prove the heap stays uncorrupted after the frees:
#   T1 upper   T2 lower   T3 trim (mid + all-whitespace)
#   T4 split   (count + fields incl empties, trailing-sep, empty input)
#   T5 replace (same-len, longer, shorter, empty-needle no-op)
#   T6 from_int/from_uint (zero, positive, negative, INT_MIN, UINT64_MAX)
#   T7 starts_with / ends_with
#   T8 2000-cycle from_uint churn round-trip (no corruption after frees)
#
# Also asserts seed<->native byte-lockstep on the fixture (objdiff clean),
# since hamstr is meant to be a byte-inert library atop the tested path.
#
# Pipeline mirrors scripts/test_adder_hamalloc.sh: build userland, build the
# fixture, plant /init = hamsh so we land at a shell, boot QEMU, run the test,
# grep the serial log for the PASS banners.
#
# PASS = serial log contains T1..T8 PASS + "[hamstr-m] PASS", no FAIL, no
# CPU exception, AND the seed<->native objdiff is clean.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_hamstr_methods.elf
FIXTURE=tests/hamstr/test_hamstr_methods.ad

echo "[test_hamstr] (1/6) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamstr] (2/6) Build the hamstr methods fixture"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    "$FIXTURE" \
    -o "$TEST_ELF" >/dev/null

echo "[test_hamstr] (3/6) seed<->native byte-lockstep (objdiff) on the fixture"
OBJ_LOG=$(mktemp)
if bash scripts/test_native_vs_seed_objdiff.sh "$FIXTURE" >"$OBJ_LOG" 2>&1 \
        && grep -q "zero semantic divergences" "$OBJ_LOG" \
        && grep -q "native-accepted=1" "$OBJ_LOG"; then
    echo "[test_hamstr] OK: $(grep 'PASS' "$OBJ_LOG" | head -1)"
    objdiff_ok=1
else
    echo "[test_hamstr] FAIL: seed<->native objdiff diverged (or native reject)"
    tail -20 "$OBJ_LOG"
    objdiff_ok=0
fi
rm -f "$OBJ_LOG"

echo "[test_hamstr] (4/6) Plant /init = hamsh + /bin/test_hamstr_methods"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamstr] (5/6) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_hamstr] (6/6) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "/bin/test_hamstr_methods" 60 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hamstr] --- captured output ---"
cat "$LOG"
echo "[test_hamstr] --- end output ---"

fail=0
[ "$objdiff_ok" -eq 1 ] || fail=1

for t in 1 2 3 4 5 6 7 8; do
    if grep -F -q "[hamstr-m] T${t} PASS" "$LOG"; then
        echo "[test_hamstr] OK: T${t} passed"
    else
        echo "[test_hamstr] MISS: T${t} PASS banner absent"
        fail=1
    fi
done

if grep -F -q "[hamstr-m] FAIL" "$LOG"; then
    echo "[test_hamstr] FAIL: fixture reported a failure"
    grep -F "[hamstr-m] FAIL" "$LOG" || true
    fail=1
fi

if grep -F -q "[hamstr-m] PASS" "$LOG"; then
    echo "[test_hamstr] OK: fixture reached final PASS"
else
    echo "[test_hamstr] MISS: final PASS banner absent"
    fail=1
fi

if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[test_hamstr] DIAG: kernel reported a CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamstr] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamstr] PASS -- owning-heap String methods correct + heap uncorrupted"
