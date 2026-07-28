#!/usr/bin/env bash
# scripts/test_ns_child_visibility.sh — BUG #113 repro + regression.
#
# Builds tests/test_ns_child_visibility.ad, boots Hamnix, drives hamsh to
# run the fixture, and asserts a child observes the parent's inherited
# bind through /proc/self/ns (COW namespace visibility), while a private
# COW child's later bind does NOT leak to the parent.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_ns_child_visibility
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_ns_child_visibility.elf

echo "[$TAG] (1/4) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[$TAG] (2/4) Build tests/test_ns_child_visibility.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_ns_child_visibility.ad \
    -o "$TEST_ELF" >/dev/null

echo "[$TAG] (3/4) Plant /init = hamsh + /bin/test_ns_child_visibility in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[$TAG] (4/4) Rebuild kernel image + boot"
mkdir -p build
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"
hamsh_send_await '/bin/test_ns_child_visibility' '[nschild] start' "$CMD_WAIT" || true
for _ in $(seq 1 "$CMD_WAIT"); do
    grep -a -Eq '\[nschild\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
    hamsh_alive || break
    sleep 1
done
hamsh_send 'exit'
sleep 2

echo "[$TAG] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[$TAG] --- end output ---"

verdict_boot_gate "$TAG" "$LOG" 0 '\[nschild\] (start|PASS|FAIL)'

fail=0
check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[$TAG] OK: $label"
    else
        echo "[$TAG] MISS: $label ($marker)"
        fail=1
    fi
}

check "[nschild] start"                                          "fixture ran"
check "[nschild] A ok (plain-fork child sees inherited bind)"    "plain-fork child /proc/self/ns visibility"
check "[nschild] B ok (RFNAMEG child sees inherited bind)"       "RFNAMEG child inherited bind visible"
check "[nschild] E ok (inherited /proc/self/ns fd tracks the reader's ns)" "inherited /proc/self/ns fd resolves self to reader (BUG #113)"
check "[nschild] C ok (child's private bind did not leak to parent)" "COW isolation holds"
check "[nschild] PASS"                                           "fixture reached PASS"

if grep -a -F -q "[nschild] FAIL" "$LOG"; then
    echo "[$TAG] observed fixture FAIL line(s):"
    grep -a -F "[nschild] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a child /proc/self/ns namespace-visibility assertion was VIOLATED."
verdict_pass "$TAG" "child observes inherited bind via /proc/self/ns; COW isolation preserved."
