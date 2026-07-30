#!/usr/bin/env bash
# scripts/test_arm64_build_integrity.sh — THE ARM64 LANE STILL BUILDS, AND THE
# CODE IT BUILDS STILL RUNS.
#
# WHY THIS GATE EXISTS
# ====================
# ARM64 is the lane that quietly stops building. It has happened at least twice:
#
#   * 2026-07-28: api_autostubs regeneration collided with the hand-maintained
#     arch/arm64/llvm/stubs.c snapshot -> `multiple definition` at link. Nothing
#     in CI built the lane, so nothing noticed. That is why
#     scripts/test_arm64_llvm_kernel.sh was registered.
#   * 2026-07-30 (this gate): the lane was RED on main @ efa0ddc8 again, by the
#     MIRROR of the same fault. stubs.c covered "the 5 LLVM bails
#     (start_kernel, do_syscall, ...)". As the SSA/LLVM subset broadened on the
#     x86 track, `do_syscall` started EMITTING instead of bailing — and its
#     emitted body called `_do_syscall_dispatch`, which STILL bails and which
#     stubs.c had never listed, because do_syscall itself used to be the stub:
#         relocation truncated to fit: R_AARCH64_CALL26 against undefined
#         symbol `arch_x86_kernel_syscall__do_syscall_dispatch'
#
# Both are the same shape: a hand-maintained list of undefined symbols drifting
# against a moving compiler. build_kernel_llvm_arm64.sh step 3c now derives that
# list mechanically from the emitter's own `; BAILED @sym` markers. THIS gate
# asserts the invariants that fix depends on, so the next drift is a red here
# instead of a surprise for whoever next touches ARM64.
#
# WHY IT IS SEPARATE FROM test_arm64_llvm_kernel.sh
# =================================================
# That gate boots qemu-system-aarch64 (~90 s) and proves EL0 multitasking. This
# one is QEMU-SYSTEM-FREE (~50 s) and proves only that both ARM64 lanes BUILD
# and that emitted AArch64 EXECUTES. It is the cheap early-warning tripwire: a
# link regression should not have to wait on a full TCG boot to be noticed, and
# a gate that costs a boot is a gate people are tempted to unregister.
#
# WHAT IT ASSERTS  (both ARM64 lanes)
# ===================================
# LANE 1 — the LLVM whole-kernel lane (the one that regressed):
#   1. the whole-kernel closure emits an aarch64-triple .ll, and emits a
#      PLAUSIBLE amount of it (>= 11000 functions). A closure that collapsed to
#      a handful of functions would link perfectly and prove nothing: "a lane
#      that emits nothing is UNKNOWN, not green".
#   2. the image LINKS, is ELF64 AArch64, and has ZERO undefined symbols.
#   3. BAIL ACCOUNTING (the 2026-07-30 root cause): every symbol the emitter
#      marked `; BAILED` is DEFINED in the final image. This is the invariant
#      whose violation produced the R_AARCH64_CALL26 red.
#   4. NO LAUNDERING: the generated autostub file defines ONLY symbols that
#      appear in the emitter's BAILED set. This is what keeps step 3c from
#      degenerating into "stub whatever is undefined", which would turn every
#      genuinely missing arch mechanism into a silent green.
#   5. the A10 EL0 user program embedded in the image has 0 bails and 0
#      undefined symbols (it has no runtime to borrow from).
#
# LANE 2 — the hand-written seed backend (compiler/codegen_arm64.py):
#   6. it compiles an Adder program with --target=aarch64-linux to a well-formed
#      ELF reporting Machine: AArch64, and
#   7. that binary EXECUTES correctly under qemu-aarch64 user-mode: stdout
#      "hello from aarch64" AND exit status 42, which the program returns only
#      if a for-loop sum, fib(10), sum_to(10) and array round-trips ALL agree.
#      This is EXECUTION against an oracle, not an inspection of emitted code —
#      the distinction that let a signedness miscompile ship 684 sites deep in
#      the x86 LLVM lane while every emitted-code diff stayed green.
#
# NEVER A SOFT GREEN
# ==================
# The ARM64 toolchain (clang, binutils-aarch64-linux-gnu, qemu-user-static) is
# not installed on every runner. A missing toolchain means the assertion was
# NEVER OBSERVED, so this gate exits 125 INCONCLUSIVE — it does NOT exit 0.
# scripts/ci_run_gate.sh turns 125 into a non-failing ::warning::, so a runner
# without the cross toolchain reports "unknown", which is the truth, rather than
# a green that would re-open exactly the hole this gate was written to close.
#
# Exit: 0 PASS, 1 FAIL, 125 INCONCLUSIVE. No qemu-system. ~50 s with a warm
# host_ac.elf.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
. scripts/_verdict.sh

TAG="arm64_build_integrity"
WORK="build/kllvm_arm64"
ELF="$WORK/hamnix_kernel_llvm_arm64.elf"
CROSS="aarch64-linux-gnu-"
CLANG="${CLANG:-clang-19}"
command -v "$CLANG" >/dev/null 2>&1 || CLANG=clang

# ---------------------------------------------------------------- toolchain
for t in "$CLANG" "${CROSS}ld" "${CROSS}as" "${CROSS}nm" readelf; do
    command -v "$t" >/dev/null 2>&1 || \
        verdict_inconclusive "$TAG" "$t not found (ARM64 cross toolchain absent; assertion never observed)"
done
QEMU_USER=""
for q in qemu-aarch64 qemu-aarch64-static; do
    command -v "$q" >/dev/null 2>&1 && { QEMU_USER="$q"; break; }
done
[ -n "$QEMU_USER" ] || \
    verdict_inconclusive "$TAG" "qemu-aarch64 user-mode absent (apt install qemu-user-static); cannot EXECUTE aarch64"

# host_ac.elf carries the LLVM backend; ssa*.ad is concatenated into it, so a
# stale copy measures the wrong compiler. Rebuild rather than trust one.
echo "[$TAG] 0) ensuring host_ac.elf (ssa*.ad is concatenated in; a stale one lies)"
# $WORK and its parent must exist BEFORE the redirect below: on a fresh
# checkout (i.e. CI) neither does, the redirect fails, the bootstrap is
# reported as having failed, and the gate exits 125 without ever reaching
# a single ARM64 assertion. A gate that never asserts on a clean tree is
# the exact hole this file was written to close.
mkdir -p "$WORK"
rm -f build/cutover/host_ac.elf
if ! ( . scripts/_adder_cc.sh && adder_cc_bootstrap ) >"$WORK/../ac_boot.log" 2>&1; then
    verdict_inconclusive "$TAG" "host_ac bootstrap failed; the ARM64 assertion was never reached (see $WORK/../ac_boot.log)"
fi
[ -x build/cutover/host_ac.elf ] || \
    verdict_inconclusive "$TAG" "no build/cutover/host_ac.elf after bootstrap"

# ============================ LANE 1: LLVM whole-kernel ====================
echo "[$TAG] 1) building the ARM64 LLVM whole-kernel lane"
mkdir -p "$WORK"
if ! bash scripts/build_kernel_llvm_arm64.sh "$ELF" >"$WORK/integrity_build.log" 2>&1; then
    sed "s/^/[$TAG]   | /" "$WORK/integrity_build.log"
    verdict_fail "$TAG" "scripts/build_kernel_llvm_arm64.sh FAILED — the ARM64 lane does not build"
fi

LL="$WORK/kernel_arm64.ll"
[ -f "$LL" ] || verdict_fail "$TAG" "no emitted $LL"
grep -q 'target triple = "aarch64' "$LL" || \
    verdict_fail "$TAG" "emitted .ll is not an aarch64 triple"

# (1) the closure must be SUBSTANTIAL, or a green means nothing.
STAT="$(grep -m1 '; ADDER_STAT' "$LL" || true)"
EMITTED="$(printf '%s' "$STAT" | grep -oP 'emitted=\K[0-9]+' || echo 0)"
[ "${EMITTED:-0}" -ge 11000 ] || \
    verdict_fail "$TAG" "only ${EMITTED:-0} functions emitted (expected >=11000) — the closure collapsed; a link over nothing proves nothing [$STAT]"
echo "[$TAG]    closure: $STAT"

# (2) linked, aarch64, zero undefined.
[ -f "$ELF" ] || verdict_fail "$TAG" "no linked image at $ELF"
readelf -h "$ELF" 2>/dev/null | grep -q 'Machine: *AArch64' || \
    verdict_fail "$TAG" "linked kernel image is not AArch64"
UNDEF="$("${CROSS}nm" -u "$ELF" 2>/dev/null | grep -c ' U ')"
[ "$UNDEF" = "0" ] || \
    verdict_fail "$TAG" "linked kernel image has $UNDEF undefined symbols"
echo "[$TAG]    linked AArch64 image, 0 undefined symbols"

# (3) BAIL ACCOUNTING — the 2026-07-30 root cause, asserted directly.
# Every function the emitter declined to emit must nonetheless have a
# definition in the final image, or some caller that STARTED emitting will hit
# an undefined reference the moment the subset moves again.
grep -oP '^; BAILED @\K[A-Za-z0-9_.$]+' "$LL" | sort -u >"$WORK/ig_bailed.txt"
NBAILED=$(grep -c . "$WORK/ig_bailed.txt" || true)
"${CROSS}nm" --defined-only "$ELF" 2>/dev/null | awk '{print $NF}' | sort -u >"$WORK/ig_elf_defined.txt"
comm -23 "$WORK/ig_bailed.txt" "$WORK/ig_elf_defined.txt" >"$WORK/ig_bailed_missing.txt"
NMISS=$(grep -c . "$WORK/ig_bailed_missing.txt" || true)
if [ "${NMISS:-0}" -gt 0 ]; then
    sed 's/^/[bail-undefined] /' "$WORK/ig_bailed_missing.txt"
    verdict_fail "$TAG" "$NMISS emitter-BAILED symbol(s) have NO definition in the image — the 2026-07-30 R_AARCH64_CALL26 regression class has reopened"
fi
echo "[$TAG]    bail accounting: all $NBAILED BAILED symbol(s) defined in the image"

# (4) NO LAUNDERING — the autostub file may define ONLY emitter-BAILED symbols.
AUTOSTUB="$WORK/autostub_bails.c"
[ -f "$AUTOSTUB" ] || \
    verdict_fail "$TAG" "build produced no $AUTOSTUB — step 3c (auto-stub the bails) did not run"
grep -oP '^u64 \K[A-Za-z0-9_.$]+(?=\(void\))' "$AUTOSTUB" | sort -u >"$WORK/ig_autostub.txt"
comm -23 "$WORK/ig_autostub.txt" "$WORK/ig_bailed.txt" >"$WORK/ig_autostub_extra.txt"
NEXTRA=$(grep -c . "$WORK/ig_autostub_extra.txt" || true)
if [ "${NEXTRA:-0}" -gt 0 ]; then
    sed 's/^/[laundered] /' "$WORK/ig_autostub_extra.txt"
    verdict_fail "$TAG" "$NEXTRA auto-stubbed symbol(s) were NOT emitter-BAILED — step 3c is papering over genuinely missing symbols, which is a soft green by construction"
fi
echo "[$TAG]    no laundering: $(grep -c . "$WORK/ig_autostub.txt" || true) auto-stub(s), all from the BAILED set"

# (5) the embedded EL0 user image stands alone.
A10ELF="$WORK/a10_user.elf"
if [ -f "$A10ELF" ]; then
    A10U="$("${CROSS}nm" -u "$A10ELF" 2>/dev/null | grep -c ' U ')"
    [ "$A10U" = "0" ] || verdict_fail "$TAG" "A10 EL0 user image has $A10U undefined symbols"
    grep -q '^declare' "$WORK/a10_user.ll" 2>/dev/null && \
        verdict_fail "$TAG" "A10 EL0 user .ll has external declares (a function bailed with no runtime to supply it)"
    echo "[$TAG]    A10 EL0 user image: 0 undefined, 0 bails"
else
    verdict_fail "$TAG" "no A10 EL0 user image at $A10ELF"
fi

# ============================ LANE 2: seed backend =========================
# The hand-written aarch64 encoder (compiler/codegen_arm64.py). Distinct from
# LANE 1 in every part: different compiler, different output (asm not IR),
# different target (Linux user-mode not bare metal).
echo "[$TAG] 2) seed aarch64 backend: compile, then EXECUTE under $QEMU_USER"
SWORK="$ROOT/build/arm64_integrity_seed"
rm -rf "$SWORK"; mkdir -p "$SWORK"
SSRC="$SWORK/prog.ad"
SELF_ELF="$SWORK/prog.elf"
cat > "$SSRC" <<'ADDER'
def puts(s: Ptr[char], n: int64) -> int64:
    return __syscall3(64, 1, cast[uint64](s), cast[uint64](n))

def fib(n: int64) -> int64:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

def sum_to(n: int64) -> int64:
    total: int64 = 0
    i: int64 = 0
    while i <= n:
        total = total + i
        i = i + 1
    return total

def main() -> int64:
    msg: Ptr[char] = "hello from aarch64\n"
    puts(msg, 19)

    acc: int64 = 0
    for k in range(1, 6):
        acc = acc + k * k

    f: int64 = fib(10)
    s: int64 = sum_to(10)

    buf: Array[4, int64] = 0
    buf[0] = 10
    buf[1] = 20
    buf[2] = buf[0] + buf[1]

    if acc == 55 and f == 55 and s == 55 and buf[2] == 30:
        return 42
    return 1
ADDER

COMPILE_OUT="$(python3 -m compiler.adder compile --target=aarch64-linux "$SSRC" -o "$SELF_ELF" 2>&1)" || {
    echo "$COMPILE_OUT" | sed 's/^/[seed] /'
    verdict_fail "$TAG" "seed aarch64 backend failed to compile"
}
[ -f "$SELF_ELF" ] || verdict_fail "$TAG" "seed backend produced no ELF"
readelf -h "$SELF_ELF" 2>/dev/null | grep -q 'Machine: *AArch64' || \
    verdict_fail "$TAG" "seed backend ELF is not Machine: AArch64"

RUN_OUT="$("$QEMU_USER" "$SELF_ELF" 2>/dev/null)"; RC=$?
echo "$RUN_OUT" | grep -q 'hello from aarch64' || \
    verdict_fail "$TAG" "executed aarch64 binary: expected stdout 'hello from aarch64', got '$RUN_OUT'"
[ "$RC" -eq 42 ] || \
    verdict_fail "$TAG" "executed aarch64 binary: expected exit 42 (all computations agree), got $RC"
echo "[$TAG]    EXECUTED on $QEMU_USER: stdout ok, exit 42 (loop sum, fib(10), sum_to(10), array all agree)"
rm -rf "$SWORK"

verdict_pass "$TAG" "ARM64 both lanes: LLVM kernel links AArch64 with 0 undefined and $NBAILED bails all defined; seed backend EXECUTED aarch64 correctly (exit 42)"
