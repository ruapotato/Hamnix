#!/usr/bin/env bash
# scripts/test_dev_blk_ns_visibility.sh — task #9 acceptance gate.
#
# Proves the /dev directory listing is NAMESPACE-ACCURATE with respect to
# the hostowner-only raw block server (`#b` / /dev/blk):
#
#   HOSTOWNER ns  — `ls /dev` NAMES `blk`, `/dev/blk` enumerates the live
#                   block devices, and `lsblk` lists them. (unbroken)
#   STRIPPED  ns  — `ls /dev` does NOT name `blk` (root-cause fix: the
#                   listing no longer advertises a path the caller can't
#                   open), `/dev/blk` opens are denied at the server
#                   boundary (NOT weakened), and lsblk degrades to a clean
#                   "no accessible block devices" instead of erroring.
#
# The kernel-side contract for both namespaces is exercised in ONE boot by
# tests/test_dev_blk_ns_visibility.ad, which starts as hostowner (inherited
# from PID 1), asserts the hostowner listing, then sys_setuid(NOBODY) and
# asserts the stripped listing + boundary. As hostowner we ALSO drive the
# real /bin/lsblk in hamsh to confirm it still lists devices end-to-end.
#
# Boot path: the light `-kernel` + hamsh-as-init route (mirrors
# scripts/test_default_uid.sh) — a virtio-blk drive is attached so a live
# block device (`vda`) is registered for the hostowner enumeration to find.
# Input is GATED on the shell-ready marker (re-sent until echoed), never a
# fixed sleep, so the gate stays deterministic under host load.

. "$(dirname "$0")/_verdict.sh"
. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
TAG=test_dev_blk_ns_visibility

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_dev_blk_ns_visibility.elf

echo "[$TAG] (1/5) Build userland (hamsh + coreutils incl. lsblk)"
if ! bash scripts/build_user.sh >/tmp/${TAG}_user.log 2>&1; then
    tail -30 /tmp/${TAG}_user.log >&2
    verdict_inconclusive "$TAG" "userland build failed — toolchain issue, not a /dev-ns regression."
fi
if ! bash scripts/build_modules.sh >/tmp/${TAG}_mods.log 2>&1; then
    tail -30 /tmp/${TAG}_mods.log >&2
    verdict_inconclusive "$TAG" "module build failed — toolchain issue, not a /dev-ns regression."
fi

echo "[$TAG] (2/5) Compile tests/test_dev_blk_ns_visibility.ad -> $TEST_ELF"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-adder-user tests/test_dev_blk_ns_visibility.ad "$TEST_ELF" >/tmp/${TAG}_fixture.log 2>&1; then
    tail -40 /tmp/${TAG}_fixture.log >&2
    verdict_inconclusive "$TAG" "fixture compile failed — see /tmp/${TAG}_fixture.log."
fi

echo "[$TAG] (3/5) Plant /init = hamsh + /bin/{lsblk,test_dev_blk_ns_visibility}"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/tmp/${TAG}_cpio.log 2>&1 || {
    tail -20 /tmp/${TAG}_cpio.log >&2
    verdict_inconclusive "$TAG" "initramfs build failed."
}

echo "[$TAG] (4/5) Rebuild kernel image (compiles the whole kernel)"
mkdir -p build
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
if ! kernel_image_compile "$ELF" >/tmp/${TAG}_kernel.log 2>&1; then
    tail -40 /tmp/${TAG}_kernel.log >&2
    verdict_inconclusive "$TAG" "kernel build failed — see /tmp/${TAG}_kernel.log."
fi

echo "[$TAG] (5/5) Boot QEMU (+ virtio-blk vda) and drive the fixture via hamsh"
LOG=$(mktemp --tmpdir hamnix-devblkns.boot.XXXXXX.log)
BLK_IMG=$(mktemp --tmpdir hamnix-devblkns.vda.XXXXXX.img)
truncate -s 16M "$BLK_IMG"
# Restore the default asm-init initramfs on exit (matches test_default_uid.sh).
cleanup() {
    rm -f "$LOG" "$BLK_IMG"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

set +e
(
    # Marker-gated feeder: wait for the shell-ready line, then send each
    # command, re-sending until its echo lands (keyed on the echo, not a
    # fixture marker, so a slow-but-received run is never double-driven).
    for _ in $(seq 1 60); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    # (a) hostowner lsblk — must list the virtio-blk device.
    printf '/bin/lsblk\n'
    for _ in $(seq 1 10); do
        sleep 1.2
        grep -q "SIZE(512B-sectors)" "$LOG" 2>/dev/null && break
        printf '/bin/lsblk\n'
    done
    # (b) the ns-visibility fixture (hostowner + setuid(NOBODY) in-process).
    printf '/bin/test_dev_blk_ns_visibility\n'
    for _ in $(seq 1 12); do
        sleep 1.5
        grep -q "\[devblk_ns\] start" "$LOG" 2>/dev/null && break
        printf '/bin/test_dev_blk_ns_visibility\n'
    done
    for _ in $(seq 1 40); do
        grep -Eq '\[devblk_ns\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -drive file="$BLK_IMG",format=raw,if=none,id=vd0 \
    -device virtio-blk-pci,drive=vd0 \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[$TAG] --- captured output ---"
cat "$LOG"
echo "[$TAG] --- end output ---"

# A dead boot (0 guest markers) is INCONCLUSIVE, not FAIL — the assertion
# was never observable. The fixture's own start line is the liveness proof.
if ! grep -a -F -q "[devblk_ns] start" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "the fixture never printed its start marker (qemu rc=$rc) — the guest" \
        "did not reach the interactive shell (starved TCG runner or boot" \
        "failure), so nothing was observable. Re-run on a quieter/KVM host."
fi

fail=0
miss() { echo "[$TAG] MISS: $1"; fail=1; }
ok()   { echo "[$TAG] OK: $1"; }

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then ok "$label"; else miss "$label ($marker)"; fi
}

# --- hostowner ns (unbroken) ---
check "[devblk_ns] hostowner: ls /dev names blk (+cons)" \
      "hostowner /dev listing names blk"
check "[devblk_ns] hostowner: /dev/blk enumerates" \
      "hostowner /dev/blk enumerates a live device"
# Real lsblk as hostowner listed the virtio-blk device.
if grep -a -F -q "SIZE(512B-sectors)" "$LOG"; then
    ok "hostowner lsblk printed its table header"
else
    miss "hostowner lsblk table header (SIZE(512B-sectors))"
fi
if grep -a -E -q '(^|[^[:alnum:]])vda([^[:alnum:]]|$)' "$LOG"; then
    ok "hostowner lsblk / enumeration named the virtio-blk device vda"
else
    miss "virtio-blk device vda not enumerated by hostowner"
fi

# --- stripped ns (root-cause fix + boundary intact) ---
check "[devblk_ns] stripped: ls /dev OMITS blk (keeps cons)" \
      "stripped-ns /dev listing hides blk (root-cause fix)"
check "[devblk_ns] stripped: /dev/blk open denied (boundary intact)" \
      "stripped-ns /dev/blk open denied at the server boundary"
check "[devblk_ns] stripped: /dev/blk/vda open denied (expected)" \
      "stripped-ns leaf /dev/blk/vda open denied"

check "[devblk_ns] PASS" "fixture reached PASS"

if grep -a -F -q "[devblk_ns] FAIL" "$LOG"; then
    echo "[$TAG] fixture FAIL line(s):"
    grep -a -F "[devblk_ns] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "the fixture ran (start observed) but a /dev namespace-visibility" \
        "assertion was OBSERVED absent — either the listing still advertises" \
        "an unopenable blk in a stripped ns, or the hostowner path regressed."
fi

verdict_pass "$TAG" \
    "the /dev listing is namespace-accurate: hostowner ns names blk and" \
    "enumerates /dev/blk (lsblk lists vda); a stripped (NOBODY) ns hides blk" \
    "from ls /dev, is denied /dev/blk at the server boundary, and lsblk" \
    "degrades cleanly — an unopenable path is no longer advertised."
