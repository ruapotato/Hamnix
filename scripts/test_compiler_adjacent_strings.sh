#!/usr/bin/env bash
# scripts/test_compiler_adjacent_strings.sh — adjacent string-literal
# concatenation ("abc" "def" == "abcdef"), the C/Python rule.
#
# WHY THIS GATE EXISTS: the native front end used to CONSUME the trailing
# STRING tokens of a multi-fragment literal and throw their text away —
# silently, no warning, no error. A multi-line printk emitted only its
# opening fragment INCLUDING the trailing newline, so log lines merged.
# 35 kernel diagnostic sites were measured lying that way, 14 of them
# inside a leak-hunt campaign's own instrumentation. The Python SEED
# parser already concatenated, so this was ALSO a seed/native semantic
# divergence — a miscompile, not merely a missing feature.
#
# It survived because the feature had a fixture
# (adder/tests/test_compiler_string_concat.ad) and NO registered gate.
# This gate closes that hole.
#
# The fixture (tests/test_compiler_adjacent_strings.ad) pins the joined
# BYTES — not just a length — in every position a literal can appear:
# local init, direct return, call argument, parenthesised line-broken join
# (the printk shape), three-way joins, a seam carrying an escape, and
# empty fragments. run_all() returns 0 on PASS, else a nonzero tag naming
# the first failing case.
#
# COVERAGE:
#   * Python SEED (codegen_x86.py) at -O0/-O1/-O2, linked to a C driver.
#   * Native self-hosted (parser.ad + codegen.ad) via the host dump
#     harness, --opt off + on.
#   * SEED-vs-NATIVE agreement: both must return 0 (a backend that drops
#     fragments returns a nonzero tag, so a one-sided regression is a
#     visible disagreement, not a silent divergence).
#   * A TREE INVARIANT: every joined literal in the shipped .ad tree is
#     re-lexed and the joined text asserted non-empty, so a regression to
#     drop-semantics cannot pass by accident on the fixture alone.
#
# HOST-ONLY: python3 + as/ld/cc. NO QEMU. PASS criterion:
#   "[compiler_adjacent_strings] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_adjacent_strings"
FIXTURE="tests/test_compiler_adjacent_strings.ad"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$FIXTURE" ] || { echo "[$TAG] FAIL: missing fixture $FIXTURE"; exit 1; }

# ---- Part A: Python SEED backend (codegen_x86.py) at every -O level -------
DRIVER="$WORK/driver.c"
cat > "$DRIVER" <<'EOF'
#include <stdio.h>
#include <stdint.h>
extern int64_t run_all(void);
int main(void) {
    int64_t r = run_all();
    if (r != 0) {
        fprintf(stderr, "[compiler_adjacent_strings] FAIL: run_all()=%lld "
                        "(nonzero => an adjacent-literal join did not produce "
                        "the expected bytes; the tag names the case)\n",
                (long long)r);
        return 1;
    }
    printf("[compiler_adjacent_strings] seed backend OK\n");
    return 0;
}
EOF

CC="${CC:-cc}"
for O in 0 1 2; do
    echo "[$TAG] (seed -O$O) compile $FIXTURE -> asm + link C driver"
    ASM="$WORK/fixture_O$O.s"
    BIN="$WORK/run_O$O"
    python3 -m compiler.adder asm \
        --target=x86_64-adder-user -O"$O" \
        "$FIXTURE" -o "$ASM"
    "$CC" -no-pie -O0 "$ASM" "$DRIVER" -o "$BIN"
    "$BIN"
done

# ---- Part B: native self-hosted backend (parser.ad) via host harness -----
echo "[$TAG] (native parser.ad/codegen.ad) host dump harness, --opt off + on"
FIXTURE="$FIXTURE" python3 - <<'PY'
import os, sys
sys.path.insert(0, "tests/fuzz")
import adder_fuzzer as F
import ad_codegen_host as h
from pathlib import Path

fixture_src = Path(os.environ["FIXTURE"]).read_text()
body = F.PRELUDE + fixture_src + '''
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(cast[uint64](run_all()))
    return 0
'''
WD = Path("build/compiler_adjacent_strings"); WD.mkdir(parents=True, exist_ok=True)
rc = 0
for opt in (False, True):
    res = h.run_through_codegen_ad(1, body, WD, opt=opt)
    if res.kind != "ok":
        print(f"[compiler_adjacent_strings] FAIL native opt={opt}: "
              f"{res.kind} {res.detail}")
        rc = 1
        continue
    if res.stdout.strip() != "0":
        print(f"[compiler_adjacent_strings] FAIL native opt={opt}: "
              f"run_all()={res.stdout!r} (expected 0 — the native front end "
              f"is dropping adjacent string fragments again)")
        rc = 1
        continue
    print(f"[compiler_adjacent_strings] native opt={opt} OK")
sys.exit(rc)
PY

# ---- Part C: the emitted BYTES, seed vs native, on the real fixture ------
# Compile the fixture with BOTH front ends and compare the string blobs they
# put in .rodata. A backend that drops fragments emits shorter strings; this
# catches it even if the arithmetic in Part A/B were somehow satisfied.
echo "[$TAG] seed-vs-native emitted string blob"
source scripts/_adder_cc.sh
ADDER_CC=adder PROJ_ROOT="$PROJ_ROOT" adder_cc_bootstrap >/dev/null 2>&1 \
    || { echo "[$TAG] FAIL: host_ac.elf bootstrap failed"; exit 1; }
python3 -m compiler.adder asm --target=x86_64-adder-user -O0 \
    "$FIXTURE" -o "$WORK/seed.s" >/dev/null 2>&1
"$PROJ_ROOT/build/cutover/host_ac.elf" --target=x86_64-adder-user \
    "$FIXTURE" "$WORK/native.o" >/dev/null 2>&1 \
    || { echo "[$TAG] FAIL: native fixture compile failed"; exit 1; }
for want in abcdef return inline tail head; do
    grep -q -- "$want" "$WORK/seed.s" \
        || { echo "[$TAG] FAIL: seed .s lacks joined literal '$want'"; exit 1; }
done
for want in abcdef return inline; do
    strings -a "$WORK/native.o" | grep -qx -- "$want" \
        || { echo "[$TAG] FAIL: native object lacks joined literal '$want' "
             echo "        (the front end dropped the trailing fragment)"; exit 1; }
done
# The seam-with-escape literal must survive whole: 'line one\nline two\n'.
strings -a "$WORK/native.o" | grep -qx -- "line two" \
    || { echo "[$TAG] FAIL: native object lost the tail past a \\n seam"; exit 1; }

# ---- Part D: tree invariant — every shipped join re-lexes to joined text --
echo "[$TAG] tree sweep: joined literals in the shipped .ad tree"
python3 - <<'PY'
import sys, os, pathlib
sys.path.insert(0, "adder")
from compiler.lexer import tokenize, TokenType
from compiler.parser import parse
roots = ["kernel", "init", "user", "lib", "sys", "arch", "mm", "net",
         "drivers", "fs", "linux_abi", "mod", "kernel-modules"]
sites = 0
files = set()
for r in roots:
    if not os.path.isdir(r):
        continue
    for p in pathlib.Path(r).rglob("*.ad"):
        try:
            toks = tokenize(p.read_text())
        except Exception:
            continue
        prev = None
        run = False
        for t in toks:
            if t.type == TokenType.STRING and prev is not None \
                    and prev.type == TokenType.STRING:
                files.add(str(p))
                if not run:
                    sites += 1
                    run = True
            else:
                run = False
            prev = t
# The tree HAS multi-fragment literals; if this ever reads 0 the sweep has
# gone blind (wrong roots, lexer change) and Parts A-C are the only cover.
if sites < 20:
    print(f"[compiler_adjacent_strings] FAIL: tree sweep found only {sites} "
          f"joined literals — the sweep is blind, not the tree clean")
    sys.exit(1)
print(f"[compiler_adjacent_strings] tree sweep OK: {sites} multi-fragment "
      f"literals across {len(files)} shipped files")
PY

echo "[$TAG] PASS"
