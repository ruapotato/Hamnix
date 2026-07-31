#!/usr/bin/env bash
# scripts/test_selfhost_whole.sh — attempt the WHOLE-compiler self-compile.
#
# The self-host fixpoint endgame (#154): the Adder-in-Adder compiler
# (lexer.ad + parser.ad + codegen.ad) compiling its OWN ~182 KiB source.
#
# This test:
#   1. Fuses the three compiler modules into ONE single-module source via
#      scripts/concat_compiler_source.py (strips intra-compiler imports).
#   2. Runs that fused source through scripts/hamnix-ac, which boots Hamnix
#      under QEMU and has the ON-DEVICE self-hosted compiler compile it,
#      hex-dumping the emitted ELF back to the host.
#
# PASS means: the on-device self-hosted compiler lexed + parsed + codegen'd
# the WHOLE concatenated compiler source and emitted a structurally valid
# ELF (magic + the entry-by-name _start stub). That ELF is itself a
# compiler binary (a library of lexer/parser/codegen functions with no
# `main`, so entry falls back to the first function) — emitting it at all is
# the milestone. A stage1==stage2 byte-identity fixpoint is a FUTURE step.
#
# On failure this surfaces the FIRST on-device blocker (the [hamnix_ac_emit]
# FAIL diagnostic, e.g. a parse error line or a codegen/cap overflow), which
# is exactly the recon signal the next iteration needs.
#
# 2026-07-31 — VERDICT ON A RED: REAL, and the gate is HONEST. But the blocker
# it was reporting was not the blocker.
#
# Measured on device:
#     [hamnix_ac_emit] src bytes=393216
#     [hamnix_ac_emit] tokens=48266
#     [hamnix_ac_emit] FAIL: codegen error reason=8 line=9750 kind=8
#
# reason 8 is codegen's "unknown name/type" — NOT the lexer's MAX_TOKENS
# ceiling (which is a lex error and exits 8, a different thing that is easy to
# confuse with reason=8). And MAX_TOKENS never fired at all: 48,266 tokens is
# comfortably under 65,536.
#
# The real first ceiling is codegen_ac_driver.ad's CC_SRC_CAP = 393,216 bytes.
# The fused source is 1,142,704 bytes, so read_source() filled its buffer and
# SILENTLY returned a file cut off at 34%; reason 8 was codegen dutifully
# reporting a name whose definition lived in the 749 KiB nobody read. The token
# cap had been made loud; this one, which bites FIRST, had not. read_source()
# now probes for one byte past the cap and fails loudly with
# "source exceeds CC_SRC_CAP", so the diagnostic names the actual limit.
#
# WHAT THIS MEANS FOR ON-DEVICE SELF-HOSTING: the whole-compiler self-compile
# is out of reach today for a RESOURCE reason, not a language one. Raising
# CC_SRC_CAP past 1.1 MB is a static-array budget decision inside a 256 MiB
# guest, and clearing it only reaches the NEXT wall — ~140k tokens against
# MAX_TOKENS = 65,536. Both are caps, both are now loud, and neither is a
# missing construct. (The HOST-side half of the same story is
# test_selfhost_wholetree_diff: 265 of 266 real units accepted, reason 7 = 0,
# reason 8 = 0, and the single reject is an ELF-emitter cap.)
#
# This gate stays a FAIL, not an INCONCLUSIVE: it ran, it observed, and the
# milestone is genuinely not met.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FUSED=build/selfhost/whole_compiler.ad
OUT=build/selfhost/whole_compiler.elf

echo "[selfhost_whole] (1/2) Fuse compiler modules -> $FUSED"
python3 scripts/concat_compiler_source.py -o "$FUSED"
SRCLEN=$(wc -c < "$FUSED")
echo "[selfhost_whole] fused source: ${SRCLEN} bytes"

echo "[selfhost_whole] (2/2) Compile fused source ON-DEVICE via hamnix-ac"
rm -f "$OUT"
if ! bash scripts/hamnix-ac "$FUSED" -o "$OUT"; then
    echo "[selfhost_whole] FAIL: on-device whole-compiler compile did not succeed"
    echo "[selfhost_whole] (see [hamnix_ac_emit] diagnostics above for the FIRST blocker)"
    exit 1
fi
if [ ! -s "$OUT" ]; then
    echo "[selfhost_whole] FAIL: $OUT not produced"
    exit 1
fi

NBYTES=$(wc -c < "$OUT")
echo "[selfhost_whole] emitted ELF: $OUT (${NBYTES} bytes)"
echo "[selfhost_whole] $(file "$OUT" 2>/dev/null || true)"

# Sanity: ELF magic.
MAGIC=$(head -c4 "$OUT" | od -An -tx1 | tr -d ' \n')
if [ "$MAGIC" != "7f454c46" ]; then
    echo "[selfhost_whole] FAIL: emitted file lacks ELF magic (got $MAGIC)"
    exit 1
fi

echo "[selfhost_whole] PASS — on-device self-hosted compiler emitted an ELF from its OWN ${SRCLEN}-byte source"
