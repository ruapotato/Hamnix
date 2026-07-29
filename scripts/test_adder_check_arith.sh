#!/usr/bin/env bash
# scripts/test_adder_check_arith.sh — OPT-IN CHECKED INTEGER ARITHMETIC
# (`--check-arith`). HOST-ONLY, NO QEMU.
#
# THE DEFECT THIS GATE EXISTS FOR
# ------------------------------
# On 2026-07-17 `cyc_to_ns()` computed `(cycles * mult) >> shift` in uint64.
# With this TSC (freq=4009555700 mult=4184308 shift=24) the product passes 2^64
# at 2^64/mult = 4.409e12 cycles = 1099.5 SECONDS of uptime, after which the
# monotonic clock jumped BACKWARDS by 1099 s. `hrtimer_start_rel` arms against
# that clock, so past the wrap EVERY bounded wait in the kernel became
# unbounded: 13 kernel sites on `wq_wait_commit_timeout` (pipe, 9p, AHCI, HDA,
# TCP, devfd) and 16 userland programs parked on `sys_waitfds`. The DE panel
# wedged after 18 minutes. One silent multiply, four days invisible.
#
# Case (1) below is that exact computation over a cycle count PAST the wrap.
# Unchecked it silently returns a wrapped value; with --check-arith it traps
# naming the operation, both operands, the type and the line. MUTATION TEST:
# neutralising the CK_OP_MUL arm of ck_pred_unsigned in
# adder/compiler/checkarith.ad (return a constant-false predicate) turns case
# (1) red — verified 2026-07-28.
#
# WHAT IS COVERED
#   (1) CLOCK WRAP  uint64 multiply overflow traps (exit 134) with a
#                   diagnostic naming op/operands/type/line.
#   (2) IN-RANGE    the same code below the wrap runs completely unaffected.
#   (3) OPERATIONS  unsigned add, unsigned sub (underflow), signed add,
#                   signed shl, and divide-by-zero each trap.
#   (4) OPT-OUT     the same overflowing multiply inside an `unsafe:` block
#                   emits ZERO guards and no reference to the trap.
#   (5) BYTE-INERT  without the flag NOTHING is emitted — no trap symbol, no
#                   guard — so the default build is unchanged.
#   (6) KERNEL      the bare-metal target IS instrumented (unlike
#                   --check-bounds, which exempts the kernel) and the trap is
#                   wired to panic().
#
# The runnable cases go through the LLVM lane (host_ac --backend=llvm + clang)
# because host_ac's native userspace output is a Hamnix ELF32 image that does
# not execute on a Linux host. The native x86-64 backend is checked
# structurally instead, via the bare-metal relocatable object (case 6).
#
# Usage:  bash scripts/test_adder_check_arith.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[check-arith] FAIL $*"; exit 1; }
note() { echo "[check-arith] $*"; }

FIX="tests/checkarith"
WORK="${HAMNIX_BUILD_DIR:-build}/check_arith"
mkdir -p "$WORK"

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64"

# shellcheck source=_adder_cc.sh
source scripts/_adder_cc.sh
ADDER_CC=adder PROJ_ROOT="$PROJ_ROOT" adder_cc_bootstrap >/dev/null 2>&1 \
    || fail "host_ac.elf bootstrap failed"
AC="$PROJ_ROOT/build/cutover/host_ac.elf"
[ -x "$AC" ] || fail "no host_ac.elf"

CLANG="${BENCH_CLANG:-}"
if [ -z "$CLANG" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
HAVE_CLANG=1
command -v "$CLANG" >/dev/null 2>&1 || HAVE_CLANG=0

# build_run <fixture> -> sets RC and LOG (compile+run output)
build_run() {
    local f="$1"
    "$AC" --backend=llvm --check-arith "$FIX/$f.ad" "$WORK/$f.ll" \
        >"$WORK/$f.emit" 2>&1 || { cat "$WORK/$f.emit"; fail "emit failed: $f"; }
    "$CLANG" -O1 -o "$WORK/$f.elf" "$WORK/$f.ll" scripts/adder_llvm_runtime.c \
        >"$WORK/$f.link" 2>&1 || { cat "$WORK/$f.link"; fail "link failed: $f"; }
    "$WORK/$f.elf" >"$WORK/$f.out" 2>&1
    RC=$?
    LOG="$(cat "$WORK/$f.out")"
}

if [ "$HAVE_CLANG" = "1" ]; then
    note "(1) the 2026-07-17 clock wrap: uint64 multiply overflow must trap"
    build_run clockwrap
    note "    exit=$RC out: $LOG"
    [ "$RC" -eq 134 ] || fail "clock-wrap multiply did NOT trap (exit $RC)"
    case "$LOG" in
        *"mul overflow"*"ty=uint64"*) : ;;
        *) fail "diagnostic did not name the mul/type: $LOG" ;;
    esac
    case "$LOG" in
        *"rhs=4184308"*) : ;;
        *) fail "diagnostic did not report the operands: $LOG" ;;
    esac

    note "(2) the same computation below the wrap must be unaffected"
    build_run inrange
    [ "$RC" -eq 10 ] || fail "in-range run returned $RC, expected 10"

    note "(3) per-operation coverage"
    for pair in "add_unsigned:add overflow" "add_signed:add overflow" \
                "sub_unsigned:sub overflow" "shl_signed:shl overflow" \
                "divzero:div-by-zero"; do
        f="${pair%%:*}"; want="${pair#*:}"
        build_run "$f"
        [ "$RC" -eq 134 ] || fail "$f did not trap (exit $RC): $LOG"
        case "$LOG" in
            *"$want"*) note "    $f -> $LOG" ;;
            *) fail "$f trapped but the diagnostic was wrong: $LOG" ;;
        esac
    done
else
    note "SKIP runnable cases: no clang (\$BENCH_CLANG/clang-19/clang) on PATH"
fi

note "(4) unsafe: opt-out — zero guards, no trap reference"
"$AC" --backend=llvm --check-arith "$FIX/unsafe_optout.ad" \
    "$WORK/unsafe_optout.ll" >"$WORK/unsafe.emit" 2>&1 \
    || { cat "$WORK/unsafe.emit"; fail "emit failed: unsafe_optout"; }
grep -q "instrumented 0 site(s)" "$WORK/unsafe.emit" \
    || { cat "$WORK/unsafe.emit"; fail "unsafe: block was still instrumented"; }
# The runtime is DEFINED whenever the flag is on; what must be absent is any
# CALL to it from the unsafe: body.
grep -q "call .*@__ck_arith_trap" "$WORK/unsafe_optout.ll" \
    && fail "unsafe: build still calls __ck_arith_trap"
note "    0 sites, no __ck_arith_trap reference"

note "(5) byte-inert when off"
"$AC" --backend=llvm "$FIX/clockwrap.ad" "$WORK/off.ll" >"$WORK/off.emit" 2>&1 \
    || { cat "$WORK/off.emit"; fail "emit failed: clockwrap (no flag)"; }
grep -q "__ck_arith_trap" "$WORK/off.ll" \
    && fail "default build emitted a check"   # not even the runtime is injected
grep -q "check-arith" "$WORK/off.emit" \
    && fail "default build printed check-arith diagnostics"
"$AC" --target=x86_64-bare-metal "$FIX/kernel_guard.ad" "$WORK/off.o" \
    >/dev/null 2>&1 || fail "native emit failed: kernel_guard (no flag)"
readelf -sW "$WORK/off.o" 2>/dev/null | grep -q "__ck_arith_trap" \
    && fail "native default build emitted a check"
note "    no guard, no trap, no diagnostics"

note "(6) the KERNEL is instrumented too, and traps via panic()"
"$AC" --target=x86_64-bare-metal --check-arith "$FIX/kernel_guard.ad" \
    "$WORK/kern.o" >"$WORK/kern.emit" 2>&1 \
    || { cat "$WORK/kern.emit"; fail "kernel emit failed"; }
grep -q "instrumented 1 site(s)" "$WORK/kern.emit" \
    || { cat "$WORK/kern.emit"; fail "kernel target emitted no guard"; }
readelf -sW "$WORK/kern.o" 2>/dev/null | grep -q "__ck_arith_trap" \
    || fail "kernel object has no __ck_arith_trap"
objdump -d --no-show-raw-insn "$WORK/kern.o" 2>/dev/null \
    | sed -n '/<__ck_arith_trap>:/,/^$/p' | grep -q "call.*<panic>" \
    || fail "kernel trap does not call panic()"
objdump -d --no-show-raw-insn "$WORK/kern.o" 2>/dev/null \
    | sed -n '/<cyc_to_ns>:/,/^$/p' | grep -q "call.*<__ck_arith_trap>" \
    || fail "cyc_to_ns was not guarded on the kernel target"
note "    guard emitted in cyc_to_ns, trap routes to panic()"

echo "[check-arith] PASS: checked arithmetic catches the clock-wrap multiply,"
echo "[check-arith]       covers add/sub/shl/div, honours unsafe:, instruments"
echo "[check-arith]       the kernel via panic(), and is byte-inert when off."
