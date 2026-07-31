#!/usr/bin/env bash
# scripts/test_arm64_currentel_probe.sh — settle, by ASKING THE CPU, whether the
# aarch64 LLVM lane's "EL0 userland" really runs at EL0 (arch/arm64/llvm/elprobe.S).
#
# WHY THIS GATE EXISTS
# --------------------
# head.S fills l2_pgtable with descriptor low bits 0x0705 — AP[2:1] = 00, "EL1
# RW, EL0 no access" — and overrides only L2[64] (VA 0x4800_0000-0x481F_FFFF) to
# an AP=01 EL0-RW L3 window. But A9's two "EL0" tasks link into the KERNEL'S OWN
# .text at ~0x4008_14e4, inside the AP=00 region, and they execute. Every A9/A10/
# A11 "runs userland at EL0" claim rests on that being real EL0 execution, and
# nothing in the tree tested it. Three possibilities had to be separated:
# a descriptor that is not what the source says, a permissive TCG, or tasks that
# were never at EL0 at all.
#
# WHAT IS ASSERTED, AND WHY IT CANNOT BE FAKED
# --------------------------------------------
# Stage 0. `MRS <Xt>, CurrentEL` is defined at EL1+ and UNDEFINED at EL0. The
#   probe sits in the SAME AP=00 kernel .text block as A9's tasks, is eret'd to
#   the same way, and executes that MRS with a sentinel already in x0. At EL0 the
#   MRS never executes: the CPU takes a synchronous exception through the
#   "Lower EL using AArch64" slot (0x400) with ESR.EC = 0x00 and SPSR.M = 0b0000,
#   and x0 still holds the sentinel. At EL1 the MRS would SUCCEED, x0 would
#   become 0x4, and the following `svc #0` would arrive through the "Current EL
#   with SP_ELx" slot (0x200) with EC = 0x15. WHICH SLOT IS ENTERED is chosen by
#   hardware from PSTATE, not by anything the probe or this gate says, and the
#   probe's private vector table has a DIFFERENT handler in every one of the 16
#   slots — so a wrong answer cannot masquerade as the right one.
#
# Stage 1. A pass on stage 0 would be worth little if TCG simply checked no
#   permissions. So the same EL0 probe then performs a DATA LOAD from the very
#   kernel .text it is executing out of. That must take a Data Abort from a lower
#   EL (EC = 0x24). Stage 0 and stage 1 therefore demand OPPOSITE outcomes from
#   the same page for fetch and for data — the pair is what identifies the
#   architectural rule (AP[2:1] gates data; EL0 fetch is gated by UXN, = 0 here),
#   and no single permissive or single restrictive model passes both.
#
# The probe restores VBAR_EL1 before returning, so this gate ALSO requires the
# A8/A9/A10/A11 rungs after it to still complete — a probe that wrecked the lane
# would red here, not silently downstream.
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
W="build/elprobe_gate"
SERIAL="$W/serial.txt"
BOOT_TIMEOUT="${ELPROBE_BOOT_TIMEOUT:-90}"

fail()   { echo "[ELPROBE] FAIL $*"; exit 1; }
inconc() { echo "[ELPROBE] INCONCLUSIVE $*"; exit 125; }
note()   { echo "[ELPROBE] $*"; }

command -v qemu-system-aarch64 >/dev/null || inconc "qemu-system-aarch64 not found (apt install qemu-system-arm)"
command -v "${CROSS}as"        >/dev/null || inconc "aarch64 binutils not found"
command -v "${CROSS}ld"        >/dev/null || inconc "aarch64 binutils not found"
command -v "$CLANG"            >/dev/null || inconc "$CLANG not found"
[ -f arch/arm64/llvm/elprobe.S ] || fail "missing arch/arm64/llvm/elprobe.S"

rm -rf "$W"; mkdir -p "$W"

if [ -z "${ADDER_HOST_AC:-}" ] && [ ! -x "$HOST_AC" ]; then
    note "0) bootstrapping host_ac"
    # shellcheck disable=SC1091
    source scripts/_adder_cc.sh
    adder_cc_bootstrap >"$W/bootstrap.log" 2>&1 || { sed 's/^/[ELPROBE]   | /' "$W/bootstrap.log"; fail "host_ac bootstrap"; }
fi
[ -x "$HOST_AC" ] || inconc "no host_ac.elf at $HOST_AC"

note "1) building the aarch64 LLVM kernel"
CLANG="$CLANG" scripts/build_kernel_llvm_arm64.sh >"$W/build.log" 2>&1 \
    || { tail -30 "$W/build.log" | sed 's/^/[ELPROBE]   | /'; fail "kernel build"; }
[ -f "$ELF" ] || fail "no kernel ELF at $ELF"
grep -q 'bailed=0' "$W/build.log" || { grep -a 'ADDER_STAT' "$W/build.log" | sed 's/^/[ELPROBE]   | /'; fail "emitter bailed (auto-stubs return 0 and the image would lie)"; }

# The probe must live in the AP=00 region, NOT in the 0x4800_0000 EL0-RW window.
# If it ever drifted into the window the whole question would be begged.
PROBE_VA="$("${CROSS}nm" "$ELF" | awk '$3=="arm64_elprobe_entry"{print $1}')"
[ -n "$PROBE_VA" ] || fail "arm64_elprobe_entry not in the image"
PROBE_DEC=$((0x$PROBE_VA))
if [ "$PROBE_DEC" -ge $((0x48000000)) ] && [ "$PROBE_DEC" -lt $((0x48200000)) ]; then
    fail "probe at 0x$PROBE_VA is INSIDE the AP=01 EL0-RW window — the test would be vacuous"
fi
note "   probe text VA 0x$PROBE_VA (outside the 0x4800_0000-0x481F_FFFF AP=01 window)"

note "2) booting qemu-system-aarch64 -M virt"
printf 'ELPROBE-GATE\n' | timeout "$BOOT_TIMEOUT" qemu-system-aarch64 -M virt -cpu cortex-a72 \
    -m 2G -nographic -no-reboot -kernel "$ELF" -serial mon:stdio >"$SERIAL" 2>&1
# The kernel parks in wfi; timeout killing qemu (rc 124) is expected.

dump() { grep -a . "$SERIAL" | grep -vi terminating | sed 's/^/[ELPROBE]   | /'; }

grep -qa 'ELPROBE: asking the CPU' "$SERIAL" \
    || { dump; inconc "boot never reached the probe (starved, not a verdict)"; }

VERDICT_LINE="$(grep -a 'ELPROBE: trapped via' "$SERIAL" | head -1)"
note "   stage-0 raw: $VERDICT_LINE"

# ---- Stage 0: the program is at EL0 -------------------------------------
if grep -qa 'ELPROBE-VERDICT: NOT-EL0' "$SERIAL"; then
    dump
    fail "the eret'd 'EL0' program is NOT at EL0 — every A9/A10/A11 EL0 claim is wrong"
fi
grep -qa 'ELPROBE-VERDICT: EL0 ' "$SERIAL" || { dump; fail "no stage-0 verdict line"; }
# Belt and braces: the raw discriminators, read independently of the verdict line
# the probe printed for itself.
echo "$VERDICT_LINE" | grep -q 'LOWER-EL AArch64 sync slot' \
    || { dump; fail "stage 0 did not trap through the lower-EL slot"; }
echo "$VERDICT_LINE" | grep -q 'ec=0000000000000000' \
    || { dump; fail "stage 0 ESR.EC is not 0x00 (MRS CurrentEL was not UNDEFINED)"; }
echo "$VERDICT_LINE" | grep -q ' m=0000000000000000' \
    || { dump; fail "stage 0 SPSR.M[3:0] is not EL0t"; }
echo "$VERDICT_LINE" | grep -q ' x0=0000000000005EED' \
    || { dump; fail "stage 0 x0 is not the sentinel (the MRS wrote it => it executed)"; }
note "PASS stage 0: EL0 confirmed by the CPU (lower-EL slot, EC=0x00, SPSR.M=EL0t, sentinel intact)"

# ---- Stage 1: AP=00 IS enforced for EL0 data on that same page ----------
DATA_LINE="$(grep -a 'ELPROBE: trapped via' "$SERIAL" | sed -n 2p)"
[ -n "$DATA_LINE" ] || { dump; fail "stage 1 never ran"; }
note "   stage-1 raw: $DATA_LINE"
if grep -qa 'ELPROBE-VERDICT: AP00-DATA-NOT-ENFORCED' "$SERIAL"; then
    dump
    fail "EL0 read kernel .text through an AP=00 mapping — no data isolation at all"
fi
grep -qa 'ELPROBE-VERDICT: AP00-DATA-ENFORCED' "$SERIAL" || { dump; fail "no stage-1 verdict line"; }
echo "$DATA_LINE" | grep -q 'ec=0000000000000024' \
    || { dump; fail "stage 1 ESR.EC is not 0x24 (Data Abort from a lower EL)"; }
echo "$DATA_LINE" | grep -q ' m=0000000000000000' \
    || { dump; fail "stage 1 SPSR.M[3:0] is not EL0t"; }
note "PASS stage 1: AP=00 blocks EL0 DATA on the very page EL0 executes from (EC=0x24)"

# ---- The probe must not have disturbed the lane -------------------------
grep -qa 'A8: EL0 task exited'            "$SERIAL" || { dump; fail "A8 regressed after the probe"; }
grep -qa 'A9: scheduler returned'         "$SERIAL" || { dump; fail "A9 regressed after the probe"; }
grep -qa 'A10 PASS'                       "$SERIAL" || { dump; fail "A10 regressed after the probe"; }
grep -qa 'A11: archive stage complete'    "$SERIAL" || { dump; fail "A11 regressed after the probe"; }
grep -qa '^EXC esr='                      "$SERIAL" && { dump; fail "the kernel diagnostic vector fired"; }
note "PASS the probe restored VBAR_EL1; A8/A9/A10/A11 still complete, no EXC"

echo "[ELPROBE] PASS aarch64 LLVM-lane userland runs at EL0 (asked the CPU, both directions)"
exit 0
