#!/usr/bin/env bash
# scripts/test_adder_hamalloc.sh — userland heap allocator (lib/hamalloc.ad)
# correctness + no-leak + stress gate.
#
# Drives tests/hamalloc/test_hamalloc.ad on the real on-device
# x86_64-adder-user target under QEMU:
#   T1  alloc/write/readback + non-overlap of live allocations
#   T2  free-then-alloc reuses freed memory
#   T3  16-byte alignment across every size class
#   T4  realloc grows a block and preserves its bytes
#   T5  large (> 2048) direct-mmap alloc/free
#   T6  20k-iteration churn stress: per-block pattern verified on free,
#       mapped footprint BOUNDED after warm-up, final checksum reported
#
# Then drives tests/hamalloc/test_hamstr.ad — the owning-heap-String demo
# (ham_str_dup / ham_str_cat / ham_str_free) the allocator unblocks.
#
# Pipeline mirrors scripts/test_mmap.sh: build userland, build the
# fixture, plant /init = hamsh so we land at a shell, boot QEMU, run
# /bin/test_hamalloc, grep the serial log for the PASS banners.
#
# PASS = serial log contains T1..T6 PASS + "[hamalloc] PASS", no FAIL.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_hamalloc.elf
STR_ELF=build/user/test_hamstr.elf

echo "[test_hamalloc] (1/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamalloc] (2/5) Build allocator + owning-String fixtures"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/hamalloc/test_hamalloc.ad \
    -o "$TEST_ELF" >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/hamalloc/test_hamstr.ad \
    -o "$STR_ELF" >/dev/null

echo "[test_hamalloc] (3/5) Plant /init = hamsh + /bin/test_hamalloc + /bin/test_hamstr"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamalloc] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_hamalloc] (5/5) Boot QEMU + drive both tests via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "/bin/test_hamalloc" 60 \
       "/bin/test_hamstr" 20 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hamalloc] --- captured output ---"
cat "$LOG"
echo "[test_hamalloc] --- end output ---"

fail=0

for t in 1 2 3 4 5 6; do
    if grep -F -q "[hamalloc] T${t} PASS" "$LOG"; then
        echo "[test_hamalloc] OK: T${t} passed"
    else
        echo "[test_hamalloc] MISS: T${t} PASS banner absent"
        fail=1
    fi
done

if grep -F -q "[hamalloc] FAIL" "$LOG"; then
    echo "[test_hamalloc] FAIL: fixture reported a failure"
    grep -F "[hamalloc] FAIL" "$LOG" || true
    fail=1
fi

if grep -F -q "[hamalloc] PASS" "$LOG"; then
    echo "[test_hamalloc] OK: fixture reached final PASS"
else
    echo "[test_hamalloc] MISS: final PASS banner absent"
    fail=1
fi

# Owning-heap-String demo (tests/hamalloc/test_hamstr.ad).
for s in 1 2 3; do
    if grep -F -q "[hamstr] S${s} PASS" "$LOG"; then
        echo "[test_hamalloc] OK: owning-String S${s} passed"
    else
        echo "[test_hamalloc] MISS: [hamstr] S${s} PASS banner absent"
        fail=1
    fi
done
if grep -F -q "[hamstr] FAIL" "$LOG"; then
    echo "[test_hamalloc] FAIL: owning-String demo reported a failure"
    fail=1
fi
if grep -F -q "[hamstr] PASS" "$LOG"; then
    echo "[test_hamalloc] OK: owning-String demo reached final PASS"
else
    echo "[test_hamalloc] MISS: [hamstr] final PASS banner absent"
    fail=1
fi

if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[test_hamalloc] DIAG: kernel reported a CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamalloc] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamalloc] PASS -- userland heap allocator correct + bounded under churn"
