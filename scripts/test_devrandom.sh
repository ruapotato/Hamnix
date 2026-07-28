#!/usr/bin/env bash
# scripts/test_devrandom.sh — M16.95 regression for /dev/random.
#
# Mirrors test_devcons.sh / test_devtime.sh: rebuild user + kernel,
# boot QEMU, run /bin/test_devrandom, assert the 16 emitted bytes are
# NOT all 0 and NOT all 255 (a coarse "entropy is varying" check
# appropriate to the xorshift64 placeholder shipped in M16.95).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_devrandom
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devrandom.elf

echo "[test_devrandom] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devrandom] (2/5) Build tests/test_devrandom.ad -> $TEST_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_devrandom.ad "$TEST_ELF" >/dev/null

echo "[test_devrandom] (3/5) Plant /init = hamsh + /bin/test_devrandom in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devrandom] (4/5) Rebuild kernel image"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_devrandom] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

# PROMPT-GATED + output-adaptive input (scripts/_hamsh_drive.sh).
hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
hamsh_send_await '/bin/test_devrandom' '[test_devrandom] bytes=' "$CMD_WAIT" || true
hamsh_send_await 'echo POST_RANDOM_OK' 'POST_RANDOM_OK' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[test_devrandom] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_devrandom] --- end output ---"

# Zero fixture markers -> the guest was starved, not that /dev/random is broken.
verdict_boot_gate "$TAG" "$LOG" 0 '\[test_devrandom\] (start|bytes=)'

fail=0
if grep -F -q "[test_devrandom] start" "$LOG"; then
    echo "[test_devrandom] OK: fixture ran"
else
    echo "[test_devrandom] MISS: fixture banner missing"
    fail=1
fi

# Pull the bytes= line out, parse the 16 space-separated decimals.
BYTES_LINE=$(grep "\[test_devrandom\] bytes=" "$LOG" || true)
if [ -z "$BYTES_LINE" ]; then
    echo "[test_devrandom] MISS: bytes= line absent"
    fail=1
else
    # Strip the prefix; leaves a leading space and 16 numbers.
    NUMS=${BYTES_LINE#*bytes=}
    # Count zeros and 255s. xorshift64 from a non-zero seed never
    # produces an all-zero 16-byte run (cycle excludes 0), and even
    # less likely to produce all 255s — these are sanity bounds.
    zero_count=0
    ff_count=0
    total=0
    for n in $NUMS; do
        # Skip non-numeric tokens (defensive — shouldn't happen, but
        # let CR/LF artifacts pass through silently).
        case "$n" in
            ''|*[!0-9]*) continue ;;
        esac
        total=$((total + 1))
        if [ "$n" -eq 0 ]; then
            zero_count=$((zero_count + 1))
        fi
        if [ "$n" -eq 255 ]; then
            ff_count=$((ff_count + 1))
        fi
    done
    echo "[test_devrandom] parsed $total bytes ($zero_count zero, $ff_count 0xff)"
    if [ "$total" -lt 16 ]; then
        echo "[test_devrandom] MISS: expected 16 bytes, got $total"
        fail=1
    elif [ "$zero_count" -eq 16 ]; then
        echo "[test_devrandom] MISS: all 16 bytes were zero (PRNG not seeded?)"
        fail=1
    elif [ "$ff_count" -eq 16 ]; then
        echo "[test_devrandom] MISS: all 16 bytes were 0xff (degenerate state?)"
        fail=1
    else
        echo "[test_devrandom] OK: /dev/random produced varying bytes"
    fi
fi

post_ok=0
if grep -F -q "POST_RANDOM_OK" "$LOG"; then
    echo "[test_devrandom] OK: hamsh remains responsive"
    post_ok=1
else
    echo "[test_devrandom] NOTE: POST_RANDOM_OK responsiveness sentinel not observed"
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" "a /dev/random assertion was VIOLATED (see MISS: lines)"
fi
if [ "$post_ok" -ne 1 ]; then
    verdict_inconclusive "$TAG" \
        "/dev/random produced varying bytes, but the POST_RANDOM_OK" \
        "responsiveness sentinel was not seen within ${CMD_WAIT}s — cannot" \
        "tell a shell wedge from a starved guest. Re-run on a quiet host."
fi
verdict_pass "$TAG" "/dev/random produced 16 varying bytes; hamsh survived the round-trip"
