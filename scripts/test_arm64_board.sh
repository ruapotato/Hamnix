#!/usr/bin/env bash
# scripts/test_arm64_board.sh — BOARD / PLATFORM ABSTRACTION layer test.
#
# Not in ci_battery_manifest.txt because it is one RUNG of the standalone aarch64
# ladder that scripts/test_arm64_phase49.sh (which IS registered) runs end to end:
# arch/arm64/kmain.ad executes phases 1..49 in sequence in a SINGLE boot, each rung
# gated on the previous rung's PASS marker, so a regression here stops that boot
# long before "Phase 49 PASS" and reds the registered gate. Registering all 49
# would be 49 identical seed-compiles and 49 identical ~6.5-min TCG boots for one
# signal -- a manifest number going up, not coverage, and ~5 hours against a
# 50-minute shard cap. Kept rather than deleted because when the registered gate
# reds, running the rungs individually is how you find WHICH rung broke; this is
# the on-demand bisection tool for that. Per the USER ruling of 2026-07-30 ARM64
# ships on the LLVM path only, so the hand-written seed backend this lane
# exercises is a frozen regression FIXTURE, not a track under active development.
#
# The aarch64 port used to hardcode qemu-virt MMIO literals (PL011 UART
# @0x0900_0000, GICv2 @0x0800_0000, RAM @0x4000_0000) throughout kmain.ad. They
# are now factored into a board descriptor: compile-time constant globals
# (BOARD_QV_* and BOARD_RK_*) selected by BOARD_SEL into mutable runtime globals
# (PL011_BASE / UART_TYPE / GICD_BASE / GICC_BASE / RAM_BASE / arm64_cpu_count)
# at board_init(). A second board, rk3399-pinebook-pro, supplies the Rockchip
# RK3399 8250 UART2 base + GIC-400 bases + RAM@0, and an 8250/16550 putc path.
#
# This test proves the abstraction is structurally present and that BOTH boards
# compile, AND that the DEFAULT (qemu-virt) still boots its banner over the
# PL011 console (i.e. the abstraction did not regress the live console path).
# It does NOT claim the RK3399 image boots on hardware — there is no RK3399 here,
# so that descriptor is validated compile-only.
#
# Prints "[test_arm64_board] PASS" on success or "[test_arm64_board] FAIL ...".

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KMAIN="$PROJ_ROOT/arch/arm64/kmain.ad"
BANNER="HAMNIX aarch64 boot OK"

fail() {
    echo "[test_arm64_board] FAIL $*"
    exit 1
}

# --- locate qemu-system-aarch64 ----------------------------------------
QEMU=""
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU="qemu-system-aarch64"
else
    echo "[test_arm64_board] qemu-system-aarch64 not found; attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y qemu-system-arm >/dev/null 2>&1 || true
    fi
    command -v qemu-system-aarch64 >/dev/null 2>&1 \
        || fail "qemu-system-aarch64 not installed (apt install qemu-system-arm)"
    QEMU="qemu-system-aarch64"
fi

# --- check the aarch64 readelf -----------------------------------------
READELF="aarch64-linux-gnu-readelf"
command -v "$READELF" >/dev/null 2>&1 || READELF="readelf"
command -v "$READELF" >/dev/null 2>&1 || fail "no readelf available"

# --- 1. the abstraction is structurally present in source --------------
for SYM in \
    "BOARD_SEL" \
    "BOARD_QEMU_VIRT" "BOARD_RK3399_PINEBOOK_PRO" \
    "BOARD_QV_UART_BASE" "BOARD_QV_GICD_BASE" "BOARD_QV_GICC_BASE" "BOARD_QV_RAM_BASE" \
    "BOARD_RK_UART_BASE" "BOARD_RK_GICD_BASE" "BOARD_RK_GICC_BASE" "BOARD_RK_RAM_BASE" \
    "UART_TYPE_PL011" "UART_TYPE_8250" \
    "def board_init" "def _uart_putc_pl011" "def _uart_putc_8250" ; do
    grep -q -F "$SYM" "$KMAIN" || fail "board descriptor symbol/func '$SYM' missing from kmain.ad"
done

# The RK3399 descriptor must carry the documented platform addresses.
grep -q -F "0xFF1A0000" "$KMAIN" || fail "RK3399 UART2 base 0xFF1A0000 not found"
grep -q -F "0xFEE00000" "$KMAIN" || fail "RK3399 GIC-400 distributor base 0xFEE00000 not found"
grep -q -F "0xFEF02000" "$KMAIN" || fail "RK3399 GIC-400 cpu-interface base 0xFEF02000 not found"

# The default selector must be qemu-virt (value 0) so the phase tests stay green.
grep -Eq '^BOARD_SEL: uint64 = 0([^0-9]|$)' "$KMAIN" \
    || fail "BOARD_SEL default is not 0 (qemu-virt) — phase self-tests would target the wrong board"

echo "[test_arm64_board] descriptor symbols present; default board = qemu-virt"

# --- workspace ---------------------------------------------------------
WORK="$PROJ_ROOT/build/arm64_board_test"
mkdir -p "$WORK"
QV_ELF="$WORK/hamnix-qv.elf"
RK_ELF="$WORK/hamnix-rk.elf"
RK_SRC="$WORK/kmain_rk3399.ad"
SERIAL="$WORK/serial.txt"
trap 'rm -rf "$WORK"' EXIT

# --- 2. default (qemu-virt) compiles -----------------------------------
OUT="$(python3 -m compiler.adder compile --target=aarch64-bare-metal "$KMAIN" -o "$QV_ELF" 2>&1)" \
    || fail "qemu-virt compile errored:
$OUT"
echo "$OUT" | grep -q "Compiled to" || fail "qemu-virt compile did not report success"
"$READELF" -h "$QV_ELF" 2>&1 | grep -q "Machine: *AArch64" || fail "qemu-virt ELF not AArch64"

# --- 3. boot the default image; banner must print over PL011 -----------
timeout 60 "$QEMU" \
    -M virt -cpu cortex-a72 -smp 2 -nographic -no-reboot \
    -kernel "$QV_ELF" \
    >"$SERIAL" 2>&1
[ -s "$SERIAL" ] || fail "no serial output from qemu-virt boot"
grep -q "$BANNER" "$SERIAL" \
    || { sed 's/^/[test_arm64_board]   | /' "$SERIAL"; fail "qemu-virt banner not printed (console path regressed)"; }
echo "[test_arm64_board] qemu-virt boots, banner over PL011: $(grep "$BANNER" "$SERIAL" | head -1)"

# --- 4. the rk3399-pinebook-pro descriptor compiles --------------------
# Flip BOARD_SEL to BOARD_RK3399_PINEBOOK_PRO (1) in a throwaway COPY; the real
# source stays qemu-virt. Proves selecting the RK3399 board is a descriptor flip
# that produces a valid AArch64 image (NOT bootable here — no RK3399 silicon).
sed -E 's/^BOARD_SEL: uint64 = 0([^0-9]|$)/BOARD_SEL: uint64 = 1\1/' "$KMAIN" > "$RK_SRC"
grep -Eq '^BOARD_SEL: uint64 = 1' "$RK_SRC" || fail "could not flip BOARD_SEL in the rk3399 copy"

OUT="$(python3 -m compiler.adder compile --target=aarch64-bare-metal "$RK_SRC" -o "$RK_ELF" 2>&1)" \
    || fail "rk3399 compile errored:
$OUT"
echo "$OUT" | grep -q "Compiled to" || fail "rk3399 compile did not report success"
"$READELF" -h "$RK_ELF" 2>&1 | grep -q "Machine: *AArch64" || fail "rk3399 ELF not AArch64"
echo "[test_arm64_board] rk3399-pinebook-pro descriptor compiles to a valid AArch64 image"

echo "[test_arm64_board] PASS"
