#!/usr/bin/env bash
# scripts/test_arm64_a12_addrspace.sh — A12 first increment: PER-TASK TTBR0
# ADDRESS SPACES on the aarch64 LLVM lane (arch/arm64/llvm/a12.S).
#
# WHAT IS NEW, AND WHY A11's GATE CANNOT COVER IT
# -----------------------------------------------
# scripts/build_kernel_llvm_arm64.sh states A11's honest scope itself: "All
# members link at the SAME VA and are loaded one at a time ... not several
# concurrently resident address spaces (that needs the per-task TTBR0 work)."
# Every EL0 program up to A11 shared ONE 2 MiB window, so loading the second
# necessarily destroyed the first, and no assertion about one program can
# distinguish "two address spaces" from "one window, reloaded".
#
# A12 gives each task its own L1/L2/L3 and its own private backing pages, so the
# SAME user VA resolves to DIFFERENT physical memory per task. This gate is built
# entirely around the one thing that separates those two worlds:
#
#   ORDER. 'a10' is loaded into space 0. THEN 'sum' is loaded into space 1 at the
#   SAME VA 0x4801_0000. Only after BOTH loads is space 0 run. With one shared
#   window, space 1's load would have overwritten space 0 and the first run would
#   print sum's line. So this gate requires the first run to be A10's output and
#   requires sum's line NOT to appear before it.
#
#   ORDER AGAIN. Space 0 is run a SECOND time, after space 1 has both loaded AND
#   executed. A window that was somehow restored between the load and the first
#   run would still be caught here.
#
#   PHYSICAL TRUTH. Finally the kernel compares the two backing regions BY THEIR
#   IDENTITY PHYSICAL ADDRESSES, i.e. not through either task's mapping, so no
#   TLB alias can make two identical pages look distinct.
#
# THE nG BIT: ASSERTED BY INSPECTION, AND HERE IS WHY
# ---------------------------------------------------
# head.S's EL0-RW window is now built nG=1 (0x0F47, not 0x0747), because on real
# silicon a GLOBAL translation for a user VA survives an ASID change and shadows
# every later per-ASID mapping of that VA — docs/arm64_phase50.md's failure
# exactly.
#
# MEASURED, NOT ASSUMED: reverting both descriptors to nG=0 does NOT red this
# gate. QEMU TCG flushes the whole TLB (globals included) when the ASID in
# TTBR0_EL1 changes, so it cannot discriminate the bit. The ASID tagging itself
# IS discriminated — forcing every space to ASID 0 reds the gate loudly (space 0
# then runs sum and exits 246, and the backing-page comparison fails).
#
# So the nG assertion below is INSPECTION OF THE SOURCE, not execution, and it
# is labelled as such. Leaving it out would mean an execution-only gate that
# stays green while shipping the phase-50 bug to hardware TCG never models.
#
# REGISTERED in scripts/ci_battery_manifest.txt. Needs qemu-system-aarch64 +
# aarch64 binutils + clang; a missing one is INCONCLUSIVE (125), never a soft
# green.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLANG="${CLANG:-clang-19}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
ELF="build/kllvm_arm64/hamnix_kernel_llvm_arm64.elf"
W="build/a12_gate"
SERIAL="$W/serial.txt"
SEC="$W/a12_section.txt"
BOOT_TIMEOUT="${A12_BOOT_TIMEOUT:-120}"

fail()   { echo "[A12] FAIL $*"; exit 1; }
inconc() { echo "[A12] INCONCLUSIVE $*"; exit 125; }
note()   { echo "[A12] $*"; }

command -v qemu-system-aarch64 >/dev/null || inconc "qemu-system-aarch64 not found (apt install qemu-system-arm)"
command -v "${CROSS}as"        >/dev/null || inconc "aarch64 binutils not found"
command -v "${CROSS}ld"        >/dev/null || inconc "aarch64 binutils not found"
command -v "$CLANG"            >/dev/null || inconc "$CLANG not found"
[ -f arch/arm64/llvm/a12.S ] || fail "missing arch/arm64/llvm/a12.S"

rm -rf "$W"; mkdir -p "$W"

if [ -z "${ADDER_HOST_AC:-}" ] && [ ! -x "$HOST_AC" ]; then
    note "0) bootstrapping host_ac"
    # shellcheck disable=SC1091
    source scripts/_adder_cc.sh
    adder_cc_bootstrap >"$W/bootstrap.log" 2>&1 || { sed 's/^/[A12]   | /' "$W/bootstrap.log"; fail "host_ac bootstrap"; }
fi
[ -x "$HOST_AC" ] || inconc "no host_ac.elf at $HOST_AC"

note "1) building the aarch64 LLVM kernel"
CLANG="$CLANG" scripts/build_kernel_llvm_arm64.sh >"$W/build.log" 2>&1 \
    || { tail -30 "$W/build.log" | sed 's/^/[A12]   | /'; fail "kernel build"; }
[ -f "$ELF" ] || fail "no kernel ELF at $ELF"
grep -q 'bailed=0' "$W/build.log" \
    || { grep -a 'ADDER_STAT' "$W/build.log" | sed 's/^/[A12]   | /'; fail "emitter bailed (auto-stubs return 0 and the image would lie)"; }

# The two spaces must be backed by DIFFERENT physical regions in the image. If
# a refactor ever collapsed them to one symbol the runtime check below would
# still pass vacuously, so pin the reservation size here too.
BACK_SZ="$("${CROSS}nm" -S "$ELF" | awk '$4=="arm64_a12_backing"{print $2}')"
[ -n "$BACK_SZ" ] || fail "arm64_a12_backing not in the image"
[ "$((16#$BACK_SZ))" = "$((0x400000))" ] \
    || fail "arm64_a12_backing is 0x$BACK_SZ bytes, expected 0x400000 (2 spaces x 2MiB)"
note "   arm64_a12_backing reserves 0x$BACK_SZ bytes (2 spaces x 2 MiB, private)"

# ---- INSPECTION (not execution): the user-VA leaves must be non-global -----
# See the header. TCG's flush-on-ASID-change hides a global user mapping, so no
# amount of booting can assert this; it is checked at the source, and it is
# flagged here as inspection so nobody mistakes it for an executed result.
# Match the CODE, not the prose: both files discuss 0x0F47 and 0x0747 in their
# headers, so a substring search would be satisfied by a comment while the
# instruction built a global mapping.
grep -qE '^[0-9]+:[[:space:]]+movz[[:space:]]+x1, #0x0F47' arch/arm64/llvm/head.S \
    || fail "INSPECTION: head.S's l3_user_pgtable leaf is not built nG=1 (movz x1, #0x0F47) — a global user mapping reintroduces the docs/arm64_phase50.md alias on real silicon, which TCG cannot show you"
grep -qE '^[[:space:]]*\.equ[[:space:]]+A12_PTE_FLAGS,[[:space:]]*0x0F47' arch/arm64/llvm/a12.S \
    || fail "INSPECTION: a12.S's per-task leaf flags are not nG=1 (.equ A12_PTE_FLAGS, 0x0F47)"
note "   INSPECTION ok: user-VA leaves are nG=1 in head.S and a12.S (TCG cannot test this; see header)"

note "2) booting qemu-system-aarch64 -M virt"
printf 'A12-GATE\n' | timeout "$BOOT_TIMEOUT" qemu-system-aarch64 -M virt -cpu cortex-a72 \
    -m 2G -nographic -no-reboot -kernel "$ELF" -serial mon:stdio >"$SERIAL" 2>&1
# The kernel parks in wfi; timeout killing qemu (rc 124) is expected.

dump() { grep -a . "$SERIAL" | grep -vi terminating | sed 's/^/[A12]   | /'; }

grep -qa 'A12: PER-TASK ADDRESS SPACES' "$SERIAL" \
    || { dump; inconc "boot never reached the A12 stage (starved, not a verdict)"; }

# Everything below is judged on the A12 SECTION ONLY. A10/A11 print the same
# strings earlier in the boot, and matching those would make every assertion
# here vacuous.
sed -n '/A12: PER-TASK ADDRESS SPACES/,$p' "$SERIAL" | grep -a . >"$SEC"

grep -qa '^EXC esr=' "$SERIAL" && { dump; fail "the kernel diagnostic vector fired"; }
grep -qa 'A12 FAIL' "$SEC" && { dump; fail "the kernel itself reported an A12 failure"; }

# ---- both programs loaded, at the SAME VA -------------------------------
grep -qa "loaded EL0 image by name 'a10' .* -> 0x48010000" "$SEC" || { dump; fail "'a10' was not loaded into space 0"; }
grep -qa "loaded EL0 image by name 'sum' .* -> 0x48010000" "$SEC" || { dump; fail "'sum' was not loaded into space 1"; }
note "PASS both programs loaded at the same user VA 0x48010000"

# ---- ORDER: sum is loaded BEFORE space 0 first runs ---------------------
L_SUMLOAD=$(grep -na "loaded EL0 image by name 'sum'" "$SEC" | head -1 | cut -d: -f1)
L_RUN0=$(grep -na 'running space 0 (ASID 1)' "$SEC" | head -1 | cut -d: -f1)
L_RUN1=$(grep -na 'running space 1 (ASID 2)' "$SEC" | head -1 | cut -d: -f1)
L_RUN0B=$(grep -na 'running space 0 AGAIN' "$SEC" | head -1 | cut -d: -f1)
for v in L_SUMLOAD L_RUN0 L_RUN1 L_RUN0B; do
    [ -n "${!v}" ] || { dump; fail "missing marker for $v"; }
done
[ "$L_SUMLOAD" -lt "$L_RUN0" ] \
    || { dump; fail "'sum' was loaded AFTER space 0 ran — the ordering that makes this test meaningful is gone"; }
note "PASS 'sum' was loaded into space 1 BEFORE space 0 was ever run"

# ---- space 0's first run is a10, NOT sum --------------------------------
seg() { sed -n "$1,$2p" "$SEC"; }
S0="$(seg $((L_RUN0+1)) $((L_RUN1-1)))"
S1="$(seg $((L_RUN1+1)) $((L_RUN0B-1)))"
S0B="$(seg $((L_RUN0B+1)) 100000)"

echo "$S0" | grep -q 'A10: C=965649' \
    || { dump; fail "space 0 did not run 'a10' — space 1's load clobbered it (ONE shared window)"; }
echo "$S0" | grep -q 'A11: S=' \
    && { dump; fail "space 0 printed SUM's output — the spaces are the same window"; }
echo "$S0" | grep -q 'A12: space 0 program exited, status=17' \
    || { dump; fail "space 0 did not exit with a10's status 17"; }
note "PASS space 0 ran 'a10' even though 'sum' had already been loaded at the same VA"

# ---- space 1 runs sum ---------------------------------------------------
echo "$S1" | grep -q 'A11: S=179190' \
    || { dump; fail "space 1 did not run 'sum'"; }
echo "$S1" | grep -q 'A10: C=' \
    && { dump; fail "space 1 printed A10's output — load-by-name or the space switch is wrong"; }
echo "$S1" | grep -q 'A12: space 1 program exited, status=246' \
    || { dump; fail "space 1 did not exit with sum's status 246"; }
note "PASS space 1 ran 'sum' at the same VA, concurrently resident with space 0"

# ---- space 0 again, after space 1 both loaded AND ran -------------------
echo "$S0B" | grep -q 'A10: C=965649' \
    || { dump; fail "space 0's second run lost its program — it was not isolated from space 1"; }
echo "$S0B" | grep -q 'A12: space 0 program exited, status=17' \
    || { dump; fail "space 0's second run did not complete"; }
note "PASS space 0 re-entered unchanged after space 1 loaded and executed"

# ---- physical truth -----------------------------------------------------
grep -qa "A12 PASS: the two spaces' backing pages differ" "$SEC" \
    || { dump; fail "the two spaces' backing pages are identical (one shared window)"; }
note "PASS the backing regions differ, checked by identity PA (no task mapping involved)"

# ---- the earlier ladder is undisturbed by the nG=1 + TTBR0 work ---------
grep -qa 'A8: EL0 task exited'         "$SERIAL" || { dump; fail "A8 regressed"; }
grep -qa 'A9: scheduler returned'      "$SERIAL" || { dump; fail "A9 regressed"; }
grep -qa 'A10 PASS'                    "$SERIAL" || { dump; fail "A10 regressed"; }
grep -qa 'A11: archive stage complete' "$SERIAL" || { dump; fail "A11 regressed"; }
grep -qa 'ELPROBE-VERDICT: EL0 '       "$SERIAL" || { dump; fail "the EL0 probe regressed"; }
note "PASS A8/A9/A10/A11 + the EL0 probe still pass with the window non-global"

echo "[A12] PASS per-task TTBR0 address spaces: two programs concurrently resident at the same user VA"
exit 0
