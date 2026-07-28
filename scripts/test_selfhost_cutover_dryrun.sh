#!/usr/bin/env bash
#
# ON-DEMAND: not in ci_battery_manifest.txt because it builds the FULL fused
# .ad compiler as a host binary and then runs a 300-case differential dry-run
# against the Python seed oracle. It exceeded a 120 s probe budget on
# 55c842b9 without finishing; that is minutes of CPU per shard for a gate
# whose subject (the seed/native cutover) changes rarely. Run it deliberately
# when touching the compiler front end, not on every push.
# scripts/test_selfhost_cutover_dryrun.sh — Track-3 self-hosting CUTOVER
# DRY-RUN gate (host-only, NO QEMU).
#
# Proves the self-hosted Adder compiler (lexer.ad+parser.ad+codegen.ad+
# elf_emit.ad), built as an x86_64-LINUX HOST BINARY by the Python seed
# toolchain, reproduces the Python seed's behavior across the fuzz corpus —
# the precondition for flipping the default build driver from the seed to
# the .ad binary. See tests/fuzz/cutover_dryrun.py for the method.
#
# It ALSO builds the FULL fused compiler (with elf_emit's Hamnix-target ELF
# writer) as a host binary to prove the whole pipeline links + runs on the
# host (the emitted ELF is a Hamnix-format ELF32 image, by design — see
# adder/compiler/elf_emit.ad — so it is NOT executed on host Linux here;
# the on-device fixpoint test_selfhost_fixpoint.sh covers running it).
#
# Usage:
#   bash scripts/test_selfhost_cutover_dryrun.sh
#   CUTOVER_COUNT=1000 bash scripts/test_selfhost_cutover_dryrun.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

COUNT="${CUTOVER_COUNT:-300}"
SEED="${CUTOVER_SEED:-1}"

fail() { echo "[cutover] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v as  >/dev/null 2>&1 || fail "as not found (binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (binutils)"
command -v gcc >/dev/null 2>&1 || fail "gcc not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64"

# --- (1) Build the FULL fused self-hosted compiler (incl. elf_emit) as a
#         host binary, proving the whole compiler links + runs on the host.
echo "[cutover] (1/2) build the FULL fused .ad compiler as an x86_64-linux host binary"
mkdir -p build/cutover
python3 - <<'PY' || exit 1
import importlib.util
spec = importlib.util.spec_from_file_location("ccs", "scripts/concat_compiler_source.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.DRIVER_MAIN = "fused_driver_host_main.ad"   # Linux-syscall host driver
rc = m.main(["concat", "-o", "build/cutover/host_compiler.ad", "--with-driver"])
raise SystemExit(rc)
PY
python3 -m compiler.adder compile --target=x86_64-linux \
    build/cutover/host_compiler.ad -o build/cutover/host_ac.elf \
    >/dev/null 2>build/cutover/host_ac.cerr \
    || { cat build/cutover/host_ac.cerr; fail "full fused host compiler failed to build"; }
[ -x build/cutover/host_ac.elf ] || fail "no host_ac.elf produced"
# Smoke: run it on a trivial program; it must succeed and emit a non-empty ELF.
printf 'def main() -> int64:\n    return cast[int64](42)\n' > build/cutover/smoke.ad
build/cutover/host_ac.elf build/cutover/smoke.ad build/cutover/smoke.elf \
    || fail "host_ac.elf returned nonzero compiling smoke.ad"
[ -s build/cutover/smoke.elf ] || fail "host_ac.elf produced an empty ELF"
echo "[cutover]   full fused host compiler OK: $(stat -c%s build/cutover/host_ac.elf) bytes, smoke compiled"

# --- (2) Differential cutover dry-run: .ad host compiler vs Python seed
#         over the fuzz corpus (behavioral match rate).
echo "[cutover] (2/2) differential dry-run: count=$COUNT seed=$SEED"
python3 tests/fuzz/cutover_dryrun.py --count "$COUNT" --seed "$SEED" || exit 1

echo "[cutover] PASS"
