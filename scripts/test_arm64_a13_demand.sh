#!/usr/bin/env bash
# scripts/test_arm64_a13_demand.sh — A13: DEMAND PAGING on the aarch64 LLVM lane
# (arch/arm64/llvm/a13.S + el0.S's ESR decode + init/main.ad's fault policy).
#
# WHAT IS NEW, AND WHY A12's GATE CANNOT COVER IT
# -----------------------------------------------
# A12 gave each task its own TTBR0 address space, but every leaf of every space
# was stamped VALID before the task ran. A space had to be FULLY PRE-POPULATED,
# because a Data Abort from EL0 was not serviceable — and in fact was not even
# recognised: el0.S fed every synchronous exception from EL0 to the SYSCALL
# dispatcher without reading ESR_EL1.EC, so an abort was decoded as a syscall
# numbered by whatever the faulting program had in x8, was answered in x0, and
# was eret'd back to resume. Nothing in A12's gate can see that, because A12
# never faults.
#
# HOW THIS GATE REFUSES TO PASS VACUOUSLY
# ---------------------------------------
# A demand-paging claim is trivially faked by a window that was mapped all along.
# So, in order:
#
#   1. INVALID FIRST. The kernel reads the 8 demand leaves' DESCRIPTORS before
#      the program runs and prints that they are invalid. A pre-mapped window
#      cannot get past this line.
#   2. ONE FAULT PER PAGE. Exactly 8 faults must be serviced, at the 8 expected
#      VAs in order. A retry that installed nothing would fault forever; a
#      handler that mapped the whole window on the first fault would fault once;
#      a handler that re-faulted on the read-back pass would fault 16 times.
#   3. DISTINCT FRAMES. The 8 frame PAs printed must all differ — a handler that
#      pointed every leaf at one page would satisfy the program and the sum.
#   4. PHYSICAL TRUTH. The kernel re-reads what EL0 stored at each frame's
#      IDENTITY PA, i.e. NOT through the task's mapping, so no TLB alias can
#      fake it (arm64_a12_window_differs' discipline).
#   5. AN INDEPENDENT ORACLE. The value the EL0 program prints and the status it
#      exits with are recomputed HERE, in Python, from the contract — not read
#      out of the kernel's own expectation, which would agree with itself.
#   6. AN EXECUTED NEGATIVE CONTROL. A second program stores to 0x4900_0000,
#      EL1-only identity RAM. The kernel must REFUSE it, kill the task with 139
#      (128+SIGSEGV), and keep booting. A pager that maps any faulting address
#      turns every wild pointer into a working access; this is the assertion that
#      it does not. The program's own exit(0) after the store must never be
#      reached, so the status check distinguishes "killed" from "resumed".
#
# WHAT THIS GATE DOES NOT PROVE — say it out loud.
# The nG bit is NOT testable under QEMU TCG (it flushes the whole TLB on an ASID
# change, globals included), so the demand leaves being non-global is asserted by
# INSPECTION here exactly as in scripts/test_arm64_a12_addrspace.sh, and labelled
# as such. Likewise `tlbi vaae1is` is executed but TCG's TLB is not silicon's;
# what IS executed is that the retry after the invalidate sees the new mapping.
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
W="build/a13_gate"
SERIAL="$W/serial.txt"
SEC="$W/a13_section.txt"
BOOT_TIMEOUT="${A13_BOOT_TIMEOUT:-180}"

fail()   { echo "[A13] FAIL $*"; exit 1; }
inconc() { echo "[A13] INCONCLUSIVE $*"; exit 125; }
note()   { echo "[A13] $*"; }

command -v qemu-system-aarch64 >/dev/null || inconc "qemu-system-aarch64 not found (apt install qemu-system-arm)"
command -v "${CROSS}as"        >/dev/null || inconc "aarch64 binutils not found"
command -v "${CROSS}ld"        >/dev/null || inconc "aarch64 binutils not found"
command -v "$CLANG"            >/dev/null || inconc "$CLANG not found"
command -v python3             >/dev/null || inconc "python3 not found (needed for the independent oracle)"
[ -f arch/arm64/llvm/a13.S ]            || fail "missing arch/arm64/llvm/a13.S"
[ -f user/arm64_a13_demand.ad ]         || fail "missing user/arm64_a13_demand.ad"
[ -f user/arm64_a13_segv.ad ]           || fail "missing user/arm64_a13_segv.ad"

rm -rf "$W"; mkdir -p "$W"

if [ -z "${ADDER_HOST_AC:-}" ] && [ ! -x "$HOST_AC" ]; then
    note "0) bootstrapping host_ac"
    # shellcheck disable=SC1091
    source scripts/_adder_cc.sh
    adder_cc_bootstrap >"$W/bootstrap.log" 2>&1 || { sed 's/^/[A13]   | /' "$W/bootstrap.log"; fail "host_ac bootstrap"; }
fi
[ -x "$HOST_AC" ] || inconc "no host_ac.elf at $HOST_AC"

# --------------------------------------------------------------------------
# The INDEPENDENT ORACLE. The kernel's verifier and the EL0 program both work
# from the same contract; if the gate asked either of them what the answer
# should be, it would only be checking self-consistency. So recompute it here,
# from the contract as stated in the sources, in a different language.
#
# Contract (user/arm64_a13_demand.ad): page k in [0,PAGES) at
# BASE + k*4096 gets word0 = 0x5A5A0000 + (k+1)*1111 and word1 = k; the program
# prints the sum of every word it reads back and exits with sum % 256.
# --------------------------------------------------------------------------
PAGES="$(grep -oP '^A13_PAGES:\s*int64\s*=\s*\K[0-9]+' user/arm64_a13_demand.ad)"
BASE="$(grep -oP '^A13_BASE:\s*int64\s*=\s*\K0x[0-9A-Fa-f]+' user/arm64_a13_demand.ad)"
[ -n "$PAGES" ] && [ -n "$BASE" ] || fail "could not read the A13 page contract out of user/arm64_a13_demand.ad"
read -r EXP_SUM EXP_STATUS <<<"$(python3 -c "
p=$PAGES
s=sum((0x5A5A0000+(k+1)*1111)+k for k in range(p))
print(s, s%256)")"
note "   oracle (recomputed in python, $PAGES pages from $BASE): D=$EXP_SUM, exit status=$EXP_STATUS"

# The head.S stage and the EL0 program must agree on the page count, or the
# kernel's 'exactly N faults' check silently weakens to whatever the program did.
grep -qE '^\s*\.equ\s+A13_DEMAND_PAGES_HEAD,\s*'"$PAGES"'$' arch/arm64/llvm/head.S \
    || fail "head.S's A13_DEMAND_PAGES_HEAD does not equal the program's A13_PAGES=$PAGES"

note "1) building the aarch64 LLVM kernel"
CLANG="$CLANG" scripts/build_kernel_llvm_arm64.sh >"$W/build.log" 2>&1 \
    || { tail -30 "$W/build.log" | sed 's/^/[A13]   | /'; fail "kernel build"; }
[ -f "$ELF" ] || fail "no kernel ELF at $ELF"
grep -q 'bailed=0' "$W/build.log" \
    || { grep -a 'ADDER_STAT' "$W/build.log" | sed 's/^/[A13]   | /'; fail "emitter bailed (auto-stubs return 0 and the image would lie)"; }

# The frame pool must be a reservation of its own, distinct from the space's
# backing region: a refactor that pointed the pool INTO the backing window would
# hand out pages the space already mapped and the runtime checks would pass.
POOL_SZ="$("${CROSS}nm" -S "$ELF" | awk '$4=="arm64_a13_frame_pool"{print $2}')"
[ -n "$POOL_SZ" ] || fail "arm64_a13_frame_pool not in the image"
[ "$((16#$POOL_SZ))" -ge "$((PAGES * 4096))" ] \
    || fail "arm64_a13_frame_pool is 0x$POOL_SZ bytes, too small for $PAGES demand pages"
POOL_ADDR=$((16#$("${CROSS}nm" "$ELF" | awk '$3=="arm64_a13_frame_pool"{print $1}')))
BACK_ADDR=$((16#$("${CROSS}nm" "$ELF" | awk '$3=="arm64_a13_backing"{print $1}')))
BACK_SZ=$((16#$("${CROSS}nm" -S "$ELF" | awk '$4=="arm64_a13_backing"{print $2}')))
[ "$POOL_ADDR" -lt "$BACK_ADDR" ] || [ "$POOL_ADDR" -ge $((BACK_ADDR + BACK_SZ)) ] \
    || fail "the frame pool lies INSIDE arm64_a13_backing — demand frames would be pages the space already maps"
note "   arm64_a13_frame_pool is a separate reservation of 0x$POOL_SZ bytes, disjoint from arm64_a13_backing"

# ---- INSPECTION (not execution) -----------------------------------------
# (a) the demand leaves must be non-global. See the header: TCG cannot show you
#     this, so it is checked at the source and labelled as inspection.
grep -qE '^[[:space:]]*\.equ[[:space:]]+A13_PTE_FLAGS,[[:space:]]*0x0F47' arch/arm64/llvm/a13.S \
    || fail "INSPECTION: a13.S's demand leaf flags are not nG=1 (.equ A13_PTE_FLAGS, 0x0F47) — a global user mapping reintroduces the docs/arm64_phase50.md alias on real silicon"
# (b) el0.S must actually DECODE ESR.EC. This is the bug A13 fixes; a revert that
#     went back to unconditional syscall dispatch would still service the demand
#     faults (they would land in the dispatcher and... not) — assert the decode
#     exists in the CODE, not in a comment.
grep -qE '^[[:space:]]*mrs[[:space:]]+x9, esr_el1' arch/arm64/llvm/el0.S \
    || fail "INSPECTION: el0.S's lower-EL sync stub no longer reads ESR_EL1 — every EL0 exception would go to the syscall dispatcher again"
note "   INSPECTION ok: demand leaves nG=1, and el0.S decodes ESR_EL1.EC (TCG cannot test the first; see header)"

note "2) booting qemu-system-aarch64 -M virt"
printf 'A13-GATE\n' | timeout "$BOOT_TIMEOUT" qemu-system-aarch64 -M virt -cpu cortex-a72 \
    -m 2G -nographic -no-reboot -kernel "$ELF" -serial mon:stdio >"$SERIAL" 2>&1
# The kernel parks in wfi; timeout killing qemu (rc 124) is expected.

dump() { grep -a . "$SERIAL" | grep -vi terminating | sed 's/^/[A13]   | /'; }

grep -qa 'A13: DEMAND PAGING' "$SERIAL" \
    || { dump; inconc "boot never reached the A13 stage (starved, not a verdict)"; }

# Judge on the A13 SECTION ONLY: earlier stages print similar strings.
sed -n '/A13: DEMAND PAGING/,$p' "$SERIAL" | grep -a . >"$SEC"

grep -qa '^EXC esr=' "$SERIAL" && { dump; fail "the kernel diagnostic vector fired — an exception reached the halt handler"; }
grep -qa 'A13 FAIL'  "$SEC"    && { dump; fail "the kernel itself reported an A13 failure"; }

# ---- 1. the window was INVALID before the program ran -------------------
grep -qa "A13: $PAGES demand leaves are INVALID before the EL0 program runs" "$SEC" \
    || { dump; fail "the demand window was not verified invalid before the run — the whole test could be a pre-mapped window"; }
note "PASS the $PAGES demand leaves were read as INVALID descriptors before the program ran"

# ---- 2. exactly one fault per page, at the expected VAs, in order -------
NFAULT=$(grep -ca 'A13: demand fault #' "$SEC")
[ "$NFAULT" = "$PAGES" ] \
    || { dump; fail "$NFAULT demand faults serviced, expected exactly $PAGES (a retry that installed nothing faults forever; one that mapped the window at once faults once)"; }
for k in $(seq 0 $((PAGES - 1))); do
    VA=$(printf '0x%x' $((BASE + k * 4096)))
    grep -qa "A13: demand fault #$((k+1)): VA $VA ->" "$SEC" \
        || { dump; fail "fault #$((k+1)) was not at $VA — the faults are not one-per-page in address order"; }
done
note "PASS exactly $PAGES faults, one per page, at the expected VAs in order"

# ---- 3. the frames handed out are all distinct --------------------------
NDISTINCT=$(grep -oaP 'fresh frame PA \K0x[0-9a-f]+' "$SEC" | sort -u | wc -l)
[ "$NDISTINCT" = "$PAGES" ] \
    || { dump; fail "only $NDISTINCT distinct frames for $PAGES pages — the handler is aliasing demand pages onto one frame"; }
note "PASS all $PAGES demand faults were backed by DISTINCT frames"

# ---- 4. + 5. physical truth, against the independent oracle -------------
grep -qa "A13: D=$EXP_SUM" "$SEC" \
    || { dump; fail "the EL0 program printed a sum other than the python oracle's $EXP_SUM — the bytes it stored into the demand pages did not come back"; }
grep -qa "A13 PASS: $PAGES demand faults serviced; EL0 stores verified at the frames' identity PAs (status=$EXP_STATUS)" "$SEC" \
    || { dump; fail "the kernel's identity-PA verification of EL0's stores did not pass with status $EXP_STATUS"; }
note "PASS EL0's stores are readable at the frames' identity PAs, and D=$EXP_SUM / status=$EXP_STATUS match the python oracle"

# ---- 6. the executed negative control ------------------------------------
grep -qa 'A13: WILD' "$SEC" \
    || { dump; fail "the 'segv' program never announced itself — it did not run, so its fault proves nothing"; }
grep -qa 'A13: REFUSED fault at 0x49000000 — outside the demand region (task killed)' "$SEC" \
    || { dump; fail "the wild store at 0x49000000 was NOT refused — a pager that maps any faulting VA turns every wild pointer into a working access"; }
grep -qa "A13 PASS: 1 refused fault(s); the faulting EL0 task was killed with status 139 and the kernel survived" "$SEC" \
    || { dump; fail "the faulting task was not killed with 139 (a status of 0 would mean the kernel RESUMED a task it should have killed)"; }
grep -qa 'A13: demand-paging stage complete' "$SEC" \
    || { dump; fail "the kernel did not survive past the refused fault"; }
note "PASS the refused fault killed the TASK (139), not the kernel, and the boot continued"

# ---- the earlier ladder is undisturbed ----------------------------------
grep -qa 'A8: EL0 task exited'          "$SERIAL" || { dump; fail "A8 regressed"; }
grep -qa 'A9: scheduler returned'       "$SERIAL" || { dump; fail "A9 regressed"; }
grep -qa 'A10 PASS'                     "$SERIAL" || { dump; fail "A10 regressed"; }
grep -qa 'A11: archive stage complete'  "$SERIAL" || { dump; fail "A11 regressed"; }
grep -qa "A12 PASS: the two spaces' backing pages differ" "$SERIAL" || { dump; fail "A12 regressed"; }
grep -qa 'ELPROBE-VERDICT: EL0 '        "$SERIAL" || { dump; fail "the EL0 probe regressed"; }
note "PASS A8/A9/A10/A11/A12 + the EL0 probe still pass with the ESR decode in place"

echo "[A13] PASS demand paging: an EL0 task faulted into an unmapped window, was served and retried transparently, and a fault outside it killed the task instead of the kernel"
exit 0
