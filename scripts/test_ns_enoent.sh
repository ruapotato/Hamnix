#!/usr/bin/env bash
# scripts/test_ns_enoent.sh — F1-substrate acceptance (audit #444 /
# task #446): UNBOUND = ENOENT, per-Pgrp.
#
# Builds tests/test_ns_enoent.ad, drops it into the cpio initramfs,
# boots Hamnix in QEMU, and greps the serial log for the markers.
# The fixture proves the namespace substrate contract:
#
#   * a file the PARENT (default boot namespace) can open is ENOENT
#     in an RFCNAMEG child's EMPTY namespace — no silent fall-through
#     to a global cpio root (the old veneer's behavior);
#   * an explicit server-anchored bind (#r/etc at /onlyetc) makes
#     exactly that subtree visible — and nothing else (the original
#     path and /bin stay ENOENT);
#   * the child's empty namespace + bind are per-Pgrp: the parent's
#     default view is intact afterwards and /onlyetc never leaks.
#
# MIGRATED (test-trustworthiness sweep) off the old marker-gated resend
# feeder onto the load-adaptive scripts/_hamsh_drive.sh (boot-ready
# marker + FEEDER_SYNC handshake + send-once). The fixture prints its
# OWN `[ns_enoent] …` markers — genuine command OUTPUT, never the typed
# `/bin/test_ns_enoent` input-echo. Three-valued verdict: a guest that
# never reaches the fixture is INCONCLUSIVE (this host starves TCG),
# an OBSERVED `[ns_enoent] FAIL` / missing PASS is a real FAIL.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_ns_enoent
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_ns_enoent.elf

echo "[test_ns_enoent] (1/4) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_ns_enoent] (2/4) Build tests/test_ns_enoent.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_ns_enoent.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_ns_enoent] (3/4) Plant /init = hamsh + /bin/test_ns_enoent in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ns_enoent] (4/4) Rebuild kernel image + boot"
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
hamsh_send_await '/bin/test_ns_enoent' '[ns_enoent] start' "$CMD_WAIT" || true
# Wait (bounded) for the fixture's terminal verdict line before exiting.
for _ in $(seq 1 "$CMD_WAIT"); do
    grep -a -Eq '\[ns_enoent\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
    hamsh_alive || break
    sleep 1
done
hamsh_send 'exit'
sleep 2

echo "[test_ns_enoent] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_ns_enoent] --- end output ---"

# Zero fixture markers -> the guest was starved, not the substrate broken.
verdict_boot_gate "$TAG" "$LOG" 0 '\[ns_enoent\] (start|PASS|FAIL)'

fail=0
check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_ns_enoent] OK: $label"
    else
        echo "[test_ns_enoent] MISS: $label ($marker)"
        fail=1
    fi
}

check "[ns_enoent] start" \
      "fixture ran"
check "[ns_enoent] parent /etc/inittab ok (default ns)" \
      "parent opens the probe file in the default boot namespace"
check "[ns_enoent] child empty-ns /etc/inittab ENOENT (expected)" \
      "UNBOUND = ENOENT: empty namespace does NOT fall through to a global root"
check "[ns_enoent] child bind /onlyetc <- #r/etc ok" \
      "server-anchored bind into the empty namespace"
check "[ns_enoent] child /onlyetc/inittab ok (explicit bind only)" \
      "the explicit bind (and only it) restores visibility"
check "[ns_enoent] child /etc/inittab still ENOENT post-bind (expected)" \
      "an unrelated bind does not resurrect a global root"
check "[ns_enoent] child /bin/cat ENOENT (expected)" \
      "never-bound subtree stays invisible"
check "[ns_enoent] child /dev/null ENOENT (expected, devtab gated)" \
      "F10-1: /dev/null is namespace-gated (no devtab strcmp bypass)"
check "[ns_enoent] child /dev/zero ENOENT (expected, devtab gated)" \
      "F10-1: /dev/zero is namespace-gated"
check "[ns_enoent] child /dev/random ENOENT (expected, devtab gated)" \
      "F10-1: /dev/random is namespace-gated"
check "[ns_enoent] child /dev/cpuinfo ENOENT (expected, devtab gated)" \
      "F10-1: /dev/cpuinfo is namespace-gated"
check "[ns_enoent] child bind /dev <- #c ok" \
      "F10-1: server-anchored #c bind into the empty namespace works"
check "[ns_enoent] child /dev/null ok (post #c bind)" \
      "F10-1: post-bind /dev/null opens via the devtab #c/<leaf> arm"
check "[ns_enoent] child /dev/zero ok (post #c bind)" \
      "F10-1: post-bind /dev/zero opens via the devtab #c/<leaf> arm"
check "[ns_enoent] child PASS" \
      "child reached PASS"
check "[ns_enoent] parent /etc/inittab ok post-child" \
      "parent's default namespace intact after the child (per-Pgrp)"
check "[ns_enoent] parent /onlyetc missing (expected)" \
      "child's bind did not leak to the parent"
check "[ns_enoent] PASS" \
      "fixture reached PASS"

# Any fixture FAIL line is a hard failure even if the PASS markers appeared.
if grep -a -F -q "[ns_enoent] FAIL" "$LOG"; then
    echo "[test_ns_enoent] observed fixture FAIL line(s):"
    grep -a -F "[ns_enoent] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a namespace-substrate assertion was VIOLATED (see MISS:/FAIL lines)."
verdict_pass "$TAG" \
    "an empty (RFCNAMEG) namespace resolves NOTHING until bound: unbound = ENOENT with no global-root fall-through, and binds are per-Pgrp."
