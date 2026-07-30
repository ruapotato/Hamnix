#!/usr/bin/env bash
# scripts/test_arm64_a11_archive.sh — Phase A11 host gate: SEVERAL Adder-compiled
# EL0 images in one embedded archive, loaded BY NAME, plus a REAL read(2) on the
# PL011 (docs/arm64_llvm_scoping.md A11).
#
# WHAT A LYING VERSION OF THIS GATE WOULD LOOK LIKE
# -------------------------------------------------
# Three separate claims are easy to fake and are each asserted here at the
# altitude that cannot be:
#
#  (1) "LOADED BY NAME". A loader that ignores the name and always copies the
#      first archive member satisfies every assertion you can make about ONE
#      program. So the archive's members BEHAVE DIFFERENTLY, the kernel asks for
#      them in an order that is NOT their archive order ("sum" first, though
#      "a10" is member 0), and this gate requires the behaviour to follow the
#      NAME. It also requires a name that is NOT in the archive to MISS: a
#      loader that falls back to "whatever was there" would make every by-name
#      assertion above vacuous, and it would still pass a gate that only checked
#      for hits.
#
#  (2) "A REAL read(2)". A read that returns a plausible COUNT is a stub. The
#      echo program's exit status and printed checksum are position-weighted
#      functions of the BYTES it actually received, and this gate pipes a line
#      whose content it chooses at random per run, so a canned answer cannot
#      track it. Byte count alone would not catch a FIFO read backwards; the
#      weighting does.
#
#  (3) "THE PROGRAMS COMPUTED THE RIGHT THING". Nothing here trusts a constant
#      baked into the kernel. Like scripts/test_arm64_a10_userland.sh, this gate
#      RECOMPUTES its oracles every run: it compiles the SAME .ad sources for
#      x86-64 with the SAME host_ac, runs them NATIVELY (feeding the echo one the
#      SAME random line), and requires the aarch64 EL0 runs to match their stdout
#      and exit status exactly. An AArch64 miscompile anywhere on those paths
#      moves a checksum and reds this gate.
#
# It also requires ZERO exceptions in the diagnostic vector and that A8/A9/A10
# still pass ahead of A11.
#
# REGISTERED in scripts/ci_battery_manifest.txt via ci_run_gate.sh. Needs
# qemu-system-aarch64 + aarch64 binutils + clang; a missing one, or a boot too
# starved to reach the A11 rung, is INCONCLUSIVE (125) — never a soft green.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLANG="${CLANG:-clang-19}"
CROSS="${CROSS:-aarch64-linux-gnu-}"
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
ECHO_SRC="user/arm64_a11_echo.ad"
SUM_SRC="user/arm64_a11_sum.ad"
ELF="build/kllvm_arm64/hamnix_kernel_llvm_arm64.elf"
WORK="build/kllvm_arm64"
W="build/a11_gate"
SERIAL="$W/serial.txt"
BOOT_TIMEOUT="${A11_BOOT_TIMEOUT:-90}"

fail()   { echo "[A11] FAIL $*"; exit 1; }
inconc() { echo "[A11] INCONCLUSIVE $*"; exit 125; }
note()   { echo "[A11] $*"; }

command -v qemu-system-aarch64 >/dev/null || inconc "qemu-system-aarch64 not found (apt install qemu-system-arm)"
command -v "${CROSS}ld"        >/dev/null || inconc "aarch64 binutils not found"
command -v "${CROSS}as"        >/dev/null || inconc "aarch64 binutils not found"
command -v "$CLANG"            >/dev/null || inconc "$CLANG not found"
command -v python3             >/dev/null || inconc "python3 not found"
[ -f "$ECHO_SRC" ] || fail "missing $ECHO_SRC"
[ -f "$SUM_SRC" ]  || fail "missing $SUM_SRC"
rm -rf "$W"; mkdir -p "$W"

# host_ac is CONCATENATED from adder/compiler/*.ad — a stale one silently
# measures the OLD compiler.
if [ -z "${ADDER_HOST_AC:-}" ]; then
    note "0) rebuilding host_ac (ssa*.ad is concatenated in; a stale one lies)"
    # shellcheck disable=SC1091
    source scripts/_adder_cc.sh
    adder_cc_bootstrap >"$W/bootstrap.log" 2>&1 || { sed 's/^/[A11]   | /' "$W/bootstrap.log"; fail "host_ac bootstrap"; }
fi
[ -x "$HOST_AC" ] || fail "no host_ac.elf at $HOST_AC"

# A line the kernel cannot have been written against. Fixed alphabet so it
# survives the serial round trip unambiguously (no quoting, no CR, no UTF-8).
LINE="${A11_ECHO_LINE:-$(python3 -c '
import random, string
random.seed()
print("A11-" + "".join(random.choice(string.ascii_uppercase + string.digits) for _ in range(12)))')}"
note "stdin line for this run: $LINE"

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
"$CLANG" --target=x86_64-linux-gnu -c "$W/start_x86.s" -o "$W/start_x86.o" 2>/dev/null \
    || fail "x86 oracle crt0"

# build_oracle <tag> <src.ad> -> $W/<tag>.elf
build_oracle() {
    local tag="$1" src="$2"
    "$HOST_AC" --backend=llvm "$src" "$W/$tag.ll" >"$W/$tag.emit.log" 2>&1 \
        || { sed 's/^/[A11]   | /' "$W/$tag.emit.log"; fail "x86 oracle IR emit for $src"; }
    if grep -q '^declare' "$W/$tag.ll"; then
        grep '^declare' "$W/$tag.ll" | sed 's/^/[A11]   | /'
        fail "$src oracle .ll has external declares (a function bailed the subset)"
    fi
    "$CLANG" --target=x86_64-linux-gnu -O0 -c -ffreestanding -fno-pic \
        "$W/$tag.ll" -o "$W/$tag.o" 2>/dev/null || fail "x86 oracle clang compile for $src"
    ld -static -nostdlib "$W/start_x86.o" "$W/$tag.o" -o "$W/$tag.elf" \
        || fail "x86 oracle link for $src"
}

# --------------------------------------------------------------------------
# 1) INDEPENDENT ORACLES: the SAME sources, compiled for x86-64, run NATIVELY.
#    Nothing here consults the ARM64 side or any in-kernel expectation.
# --------------------------------------------------------------------------
note "1) building the x86-64 oracles from the SAME sources"
build_oracle sum  "$SUM_SRC"
build_oracle echo "$ECHO_SRC"

SUM_OUT="$("$W/sum.elf")"; SUM_STATUS=$?
SUM_LINE="$(printf '%s\n' "$SUM_OUT" | grep -a '^A11: S=' | head -1)"
[ -n "$SUM_LINE" ] || { printf '%s\n' "$SUM_OUT" | sed 's/^/[A11]   | /'; fail "sum oracle printed no 'A11: S=' line"; }
note "   oracle sum  (x86-64, native): '$SUM_LINE' exit=$SUM_STATUS"

ECHO_OUT="$(printf '%s\n' "$LINE" | "$W/echo.elf")"; ECHO_STATUS=$?
ECHO_LINE="$(printf '%s\n' "$ECHO_OUT" | grep -a '^A11: R=' | head -1)"
[ -n "$ECHO_LINE" ] || { printf '%s\n' "$ECHO_OUT" | sed 's/^/[A11]   | /'; fail "echo oracle printed no 'A11: R=' line"; }
note "   oracle echo (x86-64, native): '$ECHO_LINE' exit=$ECHO_STATUS"
# The oracle must genuinely depend on the input, or comparing against it proves
# nothing. Feed it a DIFFERENT line and require a different answer.
ALT_OUT="$(printf '%s\n' "${LINE}X" | "$W/echo.elf")"; ALT_STATUS=$?
ALT_LINE="$(printf '%s\n' "$ALT_OUT" | grep -a '^A11: R=' | head -1)"
[ "$ALT_LINE" != "$ECHO_LINE" ] \
    || fail "echo oracle produced the same line for different input — it is not reading stdin"
note "   oracle echo is input-sensitive (a different line gives a different checksum)"

# --------------------------------------------------------------------------
# 2) Rebuild the ARM64 kernel (rebuilds every archive member + repacks).
# --------------------------------------------------------------------------
note "2) rebuilding the ARM64 LLVM kernel (regenerates + repacks the EL0 archive)"
ADDER_HOST_AC="$HOST_AC" bash scripts/build_kernel_llvm_arm64.sh "$ELF" >"$W/build.log" 2>&1 \
    || { sed 's/^/[A11]   | /' "$W/build.log"; fail "kernel build"; }
grep -q "pack-arm64-archive" "$W/build.log" || fail "build did not pack an EL0 archive"
sed -n 's/^\[kllvm-arm64\]    \(\[pack-arm64-archive\].*\)$/[A11]   \1/p' "$W/build.log"
ARCHIVE="$WORK/user_archive.bin"
[ -s "$ARCHIVE" ] || fail "no packed archive at $ARCHIVE"

# STALE / STRUCTURE GUARD: parse the archive independently of the kernel and
# require the members the by-name assertions below depend on to exist, with the
# sizes the build reported. A gate that trusts the kernel's own parse of a blob
# the kernel also produced is checking nothing.
note "3) independently parsing the packed archive"
python3 - "$ARCHIVE" "$WORK/a10_user.bin" "$WORK/a11_echo.bin" "$WORK/a11_sum.bin" <<'PYEOF' || fail "archive structure check"
import struct, sys
blob = open(sys.argv[1], 'rb').read()
want = {'a10': open(sys.argv[2], 'rb').read(),
        'echo': open(sys.argv[3], 'rb').read(),
        'sum': open(sys.argv[4], 'rb').read()}
magic, count = struct.unpack_from('<QQ', blob, 0)
assert magic == 0x5648435241313141, 'bad magic %#x' % magic
assert count == 3, 'expected 3 members, got %d' % count
seen = {}
order = []
for i in range(count):
    base = 16 + 32 * i
    name = blob[base:base + 16].split(b'\0')[0].decode()
    off, size = struct.unpack_from('<QQ', blob, base + 16)
    assert off + size <= len(blob), '%s payload out of range' % name
    seen[name] = blob[off:off + size]
    order.append(name)
for name, data in want.items():
    assert name in seen, 'member %r missing' % name
    assert seen[name] == data, 'member %r payload differs from the built image' % name
# The by-name assertions are only meaningful if the members DIFFER.
assert len(set(seen.values())) == 3, 'archive members are not distinct'
# And only if the kernel does not get the right answer by asking for member 0:
# head.S requests "sum" first, so "sum" must NOT be member 0.
assert order[0] != 'sum', 'sum is member 0 — the by-name test would be vacuous'
print('[A11]    archive OK: %d members %r, all payloads == the built images, all distinct'
      % (count, order))
PYEOF

# --------------------------------------------------------------------------
# 4) Boot, feeding the random line on stdin.
# --------------------------------------------------------------------------
note "4) booting qemu-system-aarch64 -M virt with the line on stdin"
printf '%s\n' "$LINE" | timeout "$BOOT_TIMEOUT" qemu-system-aarch64 -M virt -cpu cortex-a72 \
    -m 2G -nographic -no-reboot -kernel "$ELF" -serial mon:stdio >"$SERIAL" 2>&1
# The kernel parks in wfi; timeout killing qemu (rc 124) is expected.

dump() { grep -a . "$SERIAL" | grep -vi terminating | sed 's/^/[A11]   | /'; }
need() { grep -qa "$1" "$SERIAL" || { dump; fail "$2"; }; }

# STARVATION vs REGRESSION: how far did the boot get? A11 sits above A8/A9/A10,
# so a run that produced nothing, or never reached A10, never got close enough
# to observe A11's assertion. That is 125, not a miscompile report.
[ -s "$SERIAL" ] && grep -qa "EL1 entry OK" "$SERIAL" \
    || inconc "boot produced no/!EL1 serial in ${BOOT_TIMEOUT}s (starved TCG runner?); A11 never observed"
grep -qa "A10 PASS:" "$SERIAL" || grep -qa "A11:" "$SERIAL" \
    || { dump; inconc "boot never reached the A10 rung below A11 in ${BOOT_TIMEOUT}s (starved TCG runner?)"; }

# (a) The archive stage ran at all.
need "A11: embedded EL0 image ARCHIVE, loaded BY NAME" "kernel never reached the A11 stage"

# (b) LOADED BY NAME. Each member must be reported loaded under ITS OWN name,
#     with the size of THAT image — not of whichever member happened to be first.
for m in a10 echo sum; do
    binf="$WORK/a11_$m.bin"; [ "$m" = a10 ] && binf="$WORK/a10_user.bin"
    sz="$(stat -c %s "$binf")"
    need "A11: loaded EL0 image by name '$m' ($sz bytes" \
         "member '$m' was not loaded by name at its own size ($sz bytes)"
done
note "   all three members loaded by name, each at its own size"

# (c) A name that is NOT in the archive must MISS, and must not silently load
#     something else. Without this every by-name assertion above is vacuous.
need "A11: load-by-name MISS for 'nosuchprog'" "an absent name did not MISS (the loader ignores names?)"
grep -qa "A11: FAIL load-by-name returned an image for a name NOT in the archive" "$SERIAL" \
    && { dump; fail "load-by-name returned an image for a name not in the archive"; }
note "   an absent name correctly MISSED"

# (d) THE PROGRAMS' OWN OUTPUT, matching the independent x86-64 oracles.
need "^$SUM_LINE\$"  "'sum' did not emit the oracle line '$SUM_LINE' (miscompile, or the wrong image ran)"
need "A11: program 'sum' exited, status=$SUM_STATUS" \
     "'sum' exit status != the oracle's $SUM_STATUS"
note "   sum  matched the x86-64 oracle: '$SUM_LINE' status $SUM_STATUS"

# (e) THE READ. The echo line is a function of the RANDOM input, so matching it
#     requires read(2) to have moved those exact bytes in that exact order.
need "^$ECHO_LINE\$" "'echo' did not emit the oracle line '$ECHO_LINE' — read(2) did not deliver the piped bytes"
need "A11: program 'echo' exited, status=$ECHO_STATUS" \
     "'echo' exit status != the oracle's $ECHO_STATUS"
need "EL0 read serviced" "read() never reached the real kernel dispatcher"
note "   echo matched the x86-64 oracle fed the SAME random line: '$ECHO_LINE' status $ECHO_STATUS"

# (f) Nothing faulted, and the rungs below A11 did not regress.
grep -qa "^EXC esr=" "$SERIAL" && { dump; fail "an exception hit the diagnostic vector"; }
need "A8: EL0 task exited, returned to kernel" "A8 regressed"
need "A9: preemptive EL0 scheduling proven" "A9 regressed"
need "A10 PASS: real Adder-compiled EL0 program ran" "A10 regressed"
need "A11: archive stage complete, returned to kernel" "A11 did not return cleanly to the kernel"

echo "[A11] EL0 program output:"
grep -a "^A11: [SR]=" "$SERIAL" | sed 's/^/[A11]   | /'
echo "[A11] PASS — 3 compiled EL0 images loaded BY NAME from one embedded archive,"
echo "[A11]        an absent name MISSED, and read(2) delivered a random line off the"
echo "[A11]        PL011 (both programs cross-verified against native x86-64 runs)"
