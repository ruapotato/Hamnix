#!/usr/bin/env bash
# scripts/test_arm64_a10_userland.sh — Phase A10 host gate: a REAL Adder-compiled
# EL0 user program runs on the ARM64 LLVM kernel (docs/arm64_llvm_scoping.md A10).
#
# WHY A DEDICATED GATE, AND WHY IT IS BUILT THIS WAY
# --------------------------------------------------
# A10's claim is "the ARM64 kernel runs a real compiled userland program", and the
# cheap way to gate that — grep the serial for "A10 PASS" — would be a LYING GATE
# on three separate counts this project has been burned by before:
#
#   (1) WRONG ALTITUDE. "A10 PASS" is printed by the KERNEL after comparing the
#       EL0 exit status to a CONSTANT baked into init/main.ad
#       (ARM64_A10_EXPECT_STATUS). If someone edits user/arm64_a10_el0.ad, that
#       constant goes stale and the kernel would cheerfully compare the new
#       program's status against the old expectation — or worse, someone "fixes"
#       a red by editing the constant. So this gate does NOT trust the constant.
#       It RECOMPUTES the oracle from scratch on every run: it compiles the SAME
#       .ad source for x86-64 with the SAME host_ac, runs it NATIVELY, takes the
#       checksum and exit status that produces, and asserts (a) the ARM64 serial
#       shows that checksum, (b) the ARM64 exit status matches it, and (c) the
#       constant in init/main.ad AGREES with the freshly computed oracle. A drift
#       between source, constant and ARM64 behaviour is a hard red.
#
#   (2) STALE IMAGE. The gate always rebuilds the kernel (which rebuilds the
#       embedded user blob in step 3a), and additionally asserts the .bin
#       embedded in the ELF is byte-identical to one freshly rebuilt from the
#       current .ad source — so a stale blob cannot ride along.
#
#   (3) SILENT PASS-ON-NOTHING. A kernel that never dropped to EL0 could still
#       print its own lines. This gate requires the EL0 program's OWN output
#       ("A10: C=<oracle>", written by the compiled program through a real
#       write(2) svc), requires the loader to report a non-zero image, requires
#       all three syscalls to have been serviced by the real dispatcher, and
#       requires ZERO exceptions in the diagnostic vector.
#
# The underlying program is deliberately not fakeable: it mixes a sieve over a
# global array (EL0 memory traffic), single recursion (Collatz), and double
# recursion (Ackermann) into one checksum. Any miscompile in the aarch64 backend
# along that path, or any break in the EL0 load/store or syscall path, moves the
# checksum and reds the gate.
#
# NOT in the bare-metal battery (needs qemu-system-aarch64 + aarch64 binutils +
# clang + a host_ac with the LLVM backend); a runnable host gate only.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLANG="${CLANG:-clang-19}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
A10_SRC="user/arm64_a10_el0.ad"
ELF="build/kllvm_arm64/hamnix_kernel_llvm_arm64.elf"
WORK="build/kllvm_arm64"
W="build/a10_gate"
SERIAL="$W/serial.txt"

fail() { echo "[A10] FAIL $*"; exit 1; }
note() { echo "[A10] $*"; }

command -v qemu-system-aarch64 >/dev/null || fail "qemu-system-aarch64 not found"
command -v "${CROSS}ld"        >/dev/null || fail "aarch64 binutils not found"
command -v "$CLANG"            >/dev/null || fail "$CLANG not found"
[ -f "$A10_SRC" ] || fail "missing $A10_SRC"
mkdir -p "$W"

# host_ac is CONCATENATED from adder/compiler/*.ad — a stale one silently
# measures the OLD compiler. Rebuild it unless the caller pinned one.
if [ -z "${ADDER_HOST_AC:-}" ]; then
    note "0) rebuilding host_ac (ssa*.ad is concatenated in; a stale one lies)"
    # shellcheck disable=SC1091
    source scripts/_adder_cc.sh
    adder_cc_bootstrap >"$W/bootstrap.log" 2>&1 || { sed 's/^/[A10]   | /' "$W/bootstrap.log"; fail "host_ac bootstrap"; }
fi
[ -x "$HOST_AC" ] || fail "no host_ac.elf at $HOST_AC"

# --------------------------------------------------------------------------
# 1) INDEPENDENT ORACLE: compile the SAME .ad for x86-64 and run it NATIVELY.
#    Nothing here consults the ARM64 side or any hardcoded expectation.
# --------------------------------------------------------------------------
note "1) building the x86-64 oracle from the SAME source ($A10_SRC)"
"$HOST_AC" --backend=llvm "$A10_SRC" "$W/oracle.ll" >"$W/oracle_emit.log" 2>&1 \
    || { sed 's/^/[A10]   | /' "$W/oracle_emit.log"; fail "x86 oracle IR emit"; }
grep -q '^declare' "$W/oracle.ll" && { grep '^declare' "$W/oracle.ll" | sed 's/^/[A10]   | /'; fail "oracle .ll has external declares (a function bailed the subset)"; }
cat > "$W/start_x86.s" <<'EOF'
.text
.globl _start
_start:
    xorl %edi, %edi
    xorl %esi, %esi
    call main
    movq %rax, %rdi
    movq $60, %rax
    syscall
EOF
"$CLANG" --target=x86_64-linux-gnu -O0 -c -ffreestanding -fno-pic "$W/oracle.ll" -o "$W/oracle.o" 2>/dev/null \
    || fail "x86 oracle clang compile"
"$CLANG" --target=x86_64-linux-gnu -c "$W/start_x86.s" -o "$W/start_x86.o" 2>/dev/null || fail "x86 oracle crt0"
ld -static -nostdlib "$W/start_x86.o" "$W/oracle.o" -o "$W/oracle.elf" || fail "x86 oracle link"
ORACLE_OUT="$("$W/oracle.elf")"; ORACLE_STATUS=$?
ORACLE_SUM="$(printf '%s\n' "$ORACLE_OUT" | sed -n 's/^A10: C=\([0-9]\+\)$/\1/p')"
[ -n "$ORACLE_SUM" ] || { printf '%s\n' "$ORACLE_OUT" | sed 's/^/[A10]   | /'; fail "oracle produced no 'A10: C=' checksum line"; }
EXPECT_STATUS=$(( ORACLE_SUM % 256 ))
[ "$ORACLE_STATUS" = "$EXPECT_STATUS" ] \
    || fail "oracle self-inconsistent: exit $ORACLE_STATUS != checksum%256 $EXPECT_STATUS"
note "   oracle (x86-64, native): checksum=$ORACLE_SUM exit=$ORACLE_STATUS"

# --------------------------------------------------------------------------
# 2) The kernel's baked-in expectation must AGREE with the fresh oracle.
#    This is what stops a red from being "fixed" by editing the constant, and
#    stops the constant from silently going stale when the program changes.
# --------------------------------------------------------------------------
note "2) cross-checking init/main.ad's baked expectation against the fresh oracle"
K_SUM="$(sed -n 's/^ARM64_A10_EXPECT_CHECKSUM: int64 = \([0-9]\+\).*/\1/p' init/main.ad)"
K_ST="$(sed -n  's/^ARM64_A10_EXPECT_STATUS: int64 = \([0-9]\+\).*/\1/p'   init/main.ad)"
[ -n "$K_SUM" ] && [ -n "$K_ST" ] || fail "could not read ARM64_A10_EXPECT_* from init/main.ad"
[ "$K_SUM" = "$ORACLE_SUM" ] \
    || fail "init/main.ad ARM64_A10_EXPECT_CHECKSUM=$K_SUM but the oracle says $ORACLE_SUM (stale constant, or the program changed)"
[ "$K_ST" = "$EXPECT_STATUS" ] \
    || fail "init/main.ad ARM64_A10_EXPECT_STATUS=$K_ST but the oracle says $EXPECT_STATUS"
note "   init/main.ad agrees: checksum=$K_SUM status=$K_ST"

# --------------------------------------------------------------------------
# 3) Rebuild the ARM64 kernel (this rebuilds the embedded user blob too).
# --------------------------------------------------------------------------
note "3) rebuilding the ARM64 LLVM kernel (regenerates the embedded EL0 blob)"
bash scripts/build_kernel_llvm_arm64.sh "$ELF" >"$W/build.log" 2>&1 \
    || { sed 's/^/[A10]   | /' "$W/build.log"; fail "kernel build"; }
grep -q "A10 user image:" "$W/build.log" || fail "build did not report an A10 user image"
sed -n 's/^\[kllvm-arm64\]    \(A10 user image:.*\)$/[A10]   \1/p' "$W/build.log"
[ -s "$WORK/a10_user.bin" ] || fail "A10 user blob is missing/empty after the build"

# STALE-BLOB GUARD: rebuild the blob independently from the CURRENT source and
# require it to be byte-identical to the one the kernel build embedded.
note "4) stale-blob guard: independently rebuilt blob must match the embedded one"
cp "$WORK/a10_user.bin" "$W/embedded.bin"
"$HOST_AC" --backend=llvm --target=aarch64 "$A10_SRC" "$W/fresh.ll" >/dev/null 2>&1 || fail "fresh A10 IR emit"
"$CLANG" -O0 -c -ffreestanding -fno-pic -fno-unwind-tables -fno-stack-protector \
    -fno-addrsig --target=aarch64-none-elf -mcmodel=small "$W/fresh.ll" -o "$W/fresh.o" 2>/dev/null \
    || fail "fresh A10 clang compile"
"${CROSS}as" -o "$W/fresh_rt.o" arch/arm64/llvm/user_rt.S || fail "fresh crt0"
"${CROSS}ld" -nostdlib -static -T arch/arm64/llvm/user.lds -o "$W/fresh.elf" \
    "$W/fresh_rt.o" "$W/fresh.o" 2>/dev/null || fail "fresh A10 link"
"${CROSS}objcopy" -O binary "$W/fresh.elf" "$W/fresh.bin" || fail "fresh objcopy"
cmp -s "$W/fresh.bin" "$W/embedded.bin" \
    || fail "embedded EL0 blob differs from a fresh build of $A10_SRC (STALE BLOB)"
note "   embedded blob == fresh blob ($(stat -c %s "$W/fresh.bin") bytes)"

# --------------------------------------------------------------------------
# 5) Boot and assert at the altitude that matters.
# --------------------------------------------------------------------------
note "5) booting qemu-system-aarch64 -M virt"
timeout 60 qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G -nographic -no-reboot \
    -kernel "$ELF" -serial mon:stdio >"$SERIAL" 2>&1
# The kernel parks in wfi; timeout killing qemu (rc 124) is expected.
[ -s "$SERIAL" ] || fail "no serial output"

dump() { grep -a . "$SERIAL" | grep -vi terminating | sed 's/^/[A10]   | /'; }
need() { grep -qa "$1" "$SERIAL" || { dump; fail "$2"; }; }

# (a) The kernel actually LOADED a non-empty image (not a no-op).
need "A10: loading a COMPILED Adder EL0 user program" "kernel never reached the A10 stage"
LOADED="$(sed -n 's/.*A10: loaded EL0 user image: \([0-9]\+\) bytes.*/\1/p' "$SERIAL" | head -1)"
[ -n "$LOADED" ] && [ "$LOADED" -gt 0 ] || { dump; fail "loader did not report a non-empty EL0 image"; }
EMB_SZ="$(stat -c %s "$W/embedded.bin")"
[ "$LOADED" = "$EMB_SZ" ] || { dump; fail "kernel loaded $LOADED bytes but the blob is $EMB_SZ bytes"; }
note "   loader: $LOADED bytes == on-disk blob size"

# (b) The EL0 PROGRAM'S OWN output, produced by a real write(2) svc, carrying
#     the checksum the INDEPENDENT x86 oracle computed. This is the assertion
#     that actually proves compiled EL0 code executed correctly.
need "^A10: C=$ORACLE_SUM\$" "EL0 program did not emit the oracle checksum $ORACLE_SUM (miscompile, or EL0 never ran)"
need "^A10: P=" "EL0 program did not emit its getpid line"
note "   EL0 program emitted checksum $ORACLE_SUM — matches the x86-64 native oracle"

# (c) All three syscalls went through the REAL kernel dispatcher.
need "EL0 svc: getpid -> current_task_pid()" "getpid did not reach the real dispatcher"
need "EL0 svc: write(fd=1, buf, len) -> console" "write did not reach the real dispatcher"
need "EL0 svc: exit(status=$EXPECT_STATUS) serviced" "exit($EXPECT_STATUS) not serviced by the real dispatcher"

# (d) The kernel's own cross-check agreed, and control came back cleanly.
need "A10: EL0 user program exited, returned to kernel" "EL0 exit did not unwind back into head.S"
need "A10 PASS: real Adder-compiled EL0 program ran; exit status $EXPECT_STATUS == expected $EXPECT_STATUS" \
     "kernel-side exit-status cross-check did not pass"

# (e) Nothing faulted. A fault would have printed the diagnostic vector's dump.
grep -qa "^EXC esr=" "$SERIAL" && { dump; fail "an exception hit the diagnostic vector"; }

# (f) A10 must not have regressed the A8/A9 rungs below it.
need "A8: EL0 task exited, returned to kernel" "A8 regressed"
need "A9: preemptive EL0 scheduling proven" "A9 regressed"

echo "[A10] EL0 program output:"
grep -a "^A10: [PC]=" "$SERIAL" | sed 's/^/[A10]   | /'
echo "[A10] PASS — a real Adder-compiled EL0 user program ran on the ARM64 LLVM kernel"
echo "[A10]        (checksum $ORACLE_SUM cross-verified against a native x86-64 run of the same source)"
