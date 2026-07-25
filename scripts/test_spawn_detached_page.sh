#!/usr/bin/env bash
# scripts/test_spawn_detached_page.sh — a live PARENT must never lose one of
# its own user pages across a `spawn detached`.
#
# THE BUG THIS GATES: after an rfork(RFPROC|RFNAMEG|RFNOWAIT) the parent's
# .bss page silently went all-zero (hamdesktop's fmc_cur_path / ic_label),
# while bytes written AFTER the event landed fine — i.e. a frame the live
# parent still maps was handed back to an allocator and reissued.
#
# Drives tests/test_spawn_detached_page.ad. PASS = "[sdp] PASS".

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_spawn_detached_page.elf

echo "[sdp] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[sdp] (2/5) Build tests/test_spawn_detached_page.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_spawn_detached_page.ad \
    -o "$TEST_ELF" >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_sdp_child.ad \
    -o build/user/test_sdp_child.elf >/dev/null

echo "[sdp] (3/5) Plant /init = hamsh + /bin/test_spawn_detached_page in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[sdp] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[sdp] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "/bin/test_spawn_detached_page" 45 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[sdp] --- captured output ---"
cat "$LOG"
echo "[sdp] --- end output ---"

fail=0
grep -F -q "[sdp] start" "$LOG" || { echo "[sdp] MISS: fixture banner absent"; fail=1; }
if grep -F -q "[sdp] FAIL" "$LOG"; then
    echo "[sdp] FAIL: parent page corrupted across spawn detached"
    grep -F "[sdp] FAIL" "$LOG" | head -12 || true
    fail=1
fi
grep -F -q "[sdp] PASS" "$LOG" || { echo "[sdp] MISS: PASS banner absent"; fail=1; }
if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[sdp] DIAG: kernel reported a CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[sdp] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[sdp] PASS -- parent memory intact across spawn detached"
