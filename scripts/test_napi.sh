#!/usr/bin/env bash
#
# REGISTERED in scripts/ci_battery_manifest.txt (2026-07-28, ~90 s, no QEMU).
#
# PART 1 BELOW IS THE ONLY CHECK IN CI THAT ASSERTS THE x86_64 KERNEL LINK IS
# CLEAN — do not let it go dark again. It was unregistered until 2026-07-28, and
# while dark it went red for a real reason: init/main.ad had picked up
#     extern def arm64_a10_blob_base() -> uint64
#     extern def arm64_a10_blob_size() -> uint64
# (613b886d, the ARM64 A10 EL0 user program) whose symbols exist only in
# arch/arm64/llvm/user_blob.S. init/main.ad is the SHARED kernel root compiled
# for BOTH targets, so those two aarch64-only symbols became undefined references
# in the x86_64 link. Fixed by removing the extern from shared source entirely:
# head.S now passes the blob bounds in as AAPCS64 arguments.
#
# The lesson that keeps this gate registered: that regression was reviewed on the
# strength of kobjdiff, which compares native-vs-seed CODEGEN and therefore
# CANNOT see link resolution — a change can be semantically inert and still break
# the link. kobjdiff needs a link check run alongside it; this is that check.
# scripts/test_napi.sh — NAPI (budgeted receive) regression.
#
# Two-part gate, NO QEMU / NO Hamnix image (compile-check + host logic
# gate), matching the orchestrator's build discipline for this track:
#
#   PART 1 — KERNEL COMPILE-CHECK
#     Compile the whole kernel (init/main.ad) for x86_64-bare-metal with
#     the new net/core/napi.ad + the virtio_net NAPI wiring linked in.
#     Codegen must be clean; the ONLY tolerated link error is the lone
#     `initramfs_cpio_base/size` pair (provided by the orchestrator's real
#     image build), exactly as documented for this worktree.
#
#   PART 2 — NAPI STATE-MACHINE LOGIC GATE
#     Compile tests/test_napi_logic.ad to a native x86_64 Linux ELF and
#     run it ON THE HOST. It reproduces the exact NAPI poll decision
#     (_napi_poll_one + napi_complete + napi_schedule_irqoff) against a
#     synthetic RX flood and asserts:
#       1. budget ceiling   — a pass delivers AT MOST `budget` (64) frames
#       2. re-schedule       — full budget -> stays SCHEDULED, IRQs MASKED
#       3. complete          — under budget -> COMPLETES, IRQs RE-ENABLED
#       4. bounded flood     — 1000 frames drain in ceil(1000/64) passes,
#                              one mask + one unmask for the whole flood
#       5. order preserved   — frames reach the stack in arrival order
#       6. coalesce          — double-schedule doesn't double-mask
#     Exit code 0 + a printed "PASS" line == all assertions held.
#
# Pass marker:  [test_napi] PASS
# Fail marker:  [test_napi] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() {
    echo "[test_napi] FAIL $*"
    exit 1
}

# --- toolchain presence -------------------------------------------------
command -v as  >/dev/null 2>&1 || fail "as not found (apt install binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (apt install binutils)"
command -v gcc >/dev/null 2>&1 || fail "gcc not found (preprocesses linux-runtime.S)"
HOST_ARCH="$(uname -m)"
[ "$HOST_ARCH" = "x86_64" ] || fail "host is $HOST_ARCH, need x86_64 to run the gate ELF"

WORK="$PROJ_ROOT/build/napi_test"
rm -rf "$WORK"
mkdir -p "$WORK"

# --- PART 1: kernel compile-check --------------------------------------
echo "[test_napi] (1/2) Kernel compile-check (net/core/napi.ad + virtio_net wiring)"
KOBJ="$WORK/k_napi.o"
COMPILE_OUT="$(python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$KOBJ" 2>&1)"
# The compiler reports codegen + assemble, then links. We accept ONLY the
# lone initramfs-symbol link failure; any other error (or a real codegen
# error) is a hard FAIL.
# A genuine codegen/parse error mentions a source construct, never an ld ref.
if echo "$COMPILE_OUT" | grep -qE "^Error: (x86|parse|duplicate|.*has no method|.*out of range)"; then
    echo "$COMPILE_OUT" | tail -20
    fail "kernel codegen error (NAPI wiring did not compile)"
fi
# The only acceptable link error is the lone initramfs pair.
LINKERRS="$(echo "$COMPILE_OUT" | grep -E "undefined reference to" || true)"
if [ -n "$LINKERRS" ]; then
    BAD="$(echo "$LINKERRS" | grep -vE "initramfs_cpio_base|initramfs_cpio_size" || true)"
    if [ -n "$BAD" ]; then
        echo "$BAD"
        fail "unexpected undefined references beyond the initramfs pair"
    fi
    echo "[test_napi]   codegen clean (only lone initramfs symbols unresolved — expected)"
else
    echo "[test_napi]   codegen + link clean"
fi

# --- PART 2: NAPI logic gate -------------------------------------------
echo "[test_napi] (2/2) NAPI state-machine logic gate (host run, no QEMU)"
SRC="tests/test_napi_logic.ad"
ELF="$WORK/napi_logic.elf"
[ -f "$SRC" ] || fail "missing $SRC"
GATE_OUT="$(python3 -m compiler.adder compile --target=x86_64-linux \
    "$SRC" -o "$ELF" 2>&1)" || fail "logic-gate compile errored:
$GATE_OUT"
echo "$GATE_OUT" | grep -q "Compiled to" || fail "gate did not compile:
$GATE_OUT"
[ -f "$ELF" ] || fail "no gate ELF produced"
file "$ELF" | grep -q "ELF 64-bit" || fail "gate ELF is not elf64"

set +e
RUN_OUT="$("$ELF" 2>&1)"
RC=$?
set -e
echo "[test_napi]   gate output: $RUN_OUT  (exit=$RC)"
[ "$RC" -eq 0 ] || fail "logic gate failed at assertion (exit $RC)"
echo "$RUN_OUT" | grep -q "PASS" || fail "gate did not print PASS"

echo "[test_napi] PASS"
