#!/usr/bin/env bash
# scripts/test_ns_isolation.sh — V2 per-process namespace regression.
#
# Builds tests/test_ns_isolation.ad, drops it into the cpio initramfs,
# boots Hamnix in QEMU, and greps the serial log for the PASS marker.
# The fixture exercises the full V2 contract end-to-end:
#
#   * parent binds /myalias -> /etc
#   * parent rforks RFPROC|RFFDG|RFNAMEG|RFENVG
#   * child sees inherited binding (proves ns_clone deep-copied),
#     then unmounts + re-binds /myalias -> /bin, then opens
#     /myalias/cat (proves the divergent view is live).
#   * parent (after waitpid) re-opens /myalias/inittab -- proves the
#     parent's row was NEVER touched by the child's bind.
#
# MIGRATED (test-trustworthiness sweep) off the old marker-gated resend
# feeder onto the load-adaptive scripts/_hamsh_drive.sh (boot-ready
# marker + FEEDER_SYNC handshake + send-once). Assertions read the
# fixture's OWN `[ns_isolation] …` OUTPUT markers, never the typed
# `/bin/test_ns_isolation` input-echo. Three-valued verdict: a starved
# guest is INCONCLUSIVE, an OBSERVED violation is a real FAIL.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_ns_isolation
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_ns_isolation.elf

echo "[test_ns_isolation] (1/4) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_ns_isolation] (2/4) Build tests/test_ns_isolation.ad -> $TEST_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
adder_bin x86_64-adder-user tests/test_ns_isolation.ad "$TEST_ELF" >/dev/null

echo "[test_ns_isolation] (3/4) Plant /init = hamsh + /bin/test_ns_isolation in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ns_isolation] (4/4) Rebuild kernel image + boot"
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
hamsh_send_await '/bin/test_ns_isolation' '[ns_isolation] start' "$CMD_WAIT" || true
for _ in $(seq 1 "$CMD_WAIT"); do
    grep -a -Eq '\[ns_isolation\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
    hamsh_alive || break
    sleep 1
done
hamsh_send 'exit'
sleep 2

echo "[test_ns_isolation] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[test_ns_isolation] --- end output ---"

verdict_boot_gate "$TAG" "$LOG" 0 '\[ns_isolation\] (start|PASS|FAIL)'

fail=0
check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_ns_isolation] OK: $label"
    else
        echo "[test_ns_isolation] MISS: $label ($marker)"
        fail=1
    fi
}

check "[ns_isolation] start"                                   "fixture ran"
check "[ns_isolation] parent bind /myalias -> /etc ok"         "parent bind"
check "[ns_isolation] child inherited /myalias/inittab ok"     "ns_clone deep-copied parent's bindings"
check "[ns_isolation] child bind /myalias -> /bin ok"          "child re-bind in private namespace"
check "[ns_isolation] child /myalias/cat ok (private bind live)" "child's bind resolves to /bin"
check "[ns_isolation] child PASS"                              "child reached PASS"
check "[ns_isolation] parent /myalias/inittab ok post-child"   "parent's view preserved after child"
check "[ns_isolation] parent /myalias/cat missing (expected)"  "child's bind did not leak to parent"
check "[ns_isolation] PASS"                                    "fixture reached PASS"

if grep -a -F -q "[ns_isolation] FAIL" "$LOG"; then
    echo "[test_ns_isolation] observed fixture FAIL line(s):"
    grep -a -F "[ns_isolation] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a per-process namespace isolation assertion was VIOLATED (see MISS:/FAIL lines)."
verdict_pass "$TAG" "per-process namespace isolation verified end-to-end."
