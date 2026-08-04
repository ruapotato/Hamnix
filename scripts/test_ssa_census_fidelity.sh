#!/usr/bin/env bash
# scripts/test_ssa_census_fidelity.sh — the SSA-subset census lane must measure
# the SAME subset the real --opt/ADDER_OPT2 compiler applies.
#
# WHY THIS GATE EXISTS (2026-08-04):
#   The `--dump-ssa` analysis lane in tests/fuzz/ad_codegen_dump_driver.ad called
#   ssa_run_program(prog) on the bare parsed AST.  The real lane
#   (ssa_emit_program, adder/compiler/ssa_emit.ad) first runs
#   collect_externs / layout_classes / register_enums / layout_globals, which is
#   what POPULATES the globals table.  The subset gate for a non-local ND_IDENT
#   rvalue asks glob_lookup() whether the name is a scalar global — so with an
#   EMPTY globals table every single global read bailed (SBR_NONLOCAL site 34)
#   in the census while the real compiler accepted it.
#
#   Consequence: the whole-tree census reported 17.46% accepted and named site 34
#   the largest subset gap at 27.4% of all bails.  Both numbers were artifacts of
#   the measuring driver.  With the prologue restored the same tree measures
#   36.65% accepted and site 34 drops to 4.2% — the roadmap's "next subset
#   target" was a measurement bug, not a compiler gap.
#
#   The census is the instrument that decides what the optimizer works on next.
#   An instrument that silently understates by ~19 points sends every subsequent
#   brief at the wrong construct, so pin it with a gate.
#
# WHAT IT PROVES (host-only, no QEMU):
#   1. A function whose ONLY non-subset-looking construct is a read of an
#      in-file scalar global is ACCEPTED by the census lane (RED before the
#      driver fix: ACCEPTED 0, BAILSITE 34 1).
#   2. The same for a global STORE and for a signed/narrow-width global.
#   3. A genuinely unknown (cross-module / undeclared) name still BAILS at
#      site 34 — the fix must not turn the gate into an accept-everything.
#   4. The site-34 sub-attribution is live: a bare FUNCTION name as an rvalue
#      bails at site 103, not at the blended 34.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

h.build_driver()
DRV = str(h.DRIVER_ELF)
WD = Path("build/ssa_census_fidelity"); WD.mkdir(parents=True, exist_ok=True)

def run(name, src):
    p = WD / (name + ".ad")
    p.write_text(src)
    r = subprocess.run([DRV, "--dump-ssa", str(p)], capture_output=True,
                       text=True, timeout=300)
    acc = fb = 0
    sites = {}
    for line in r.stdout.splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "SSA_ACCEPTED":
            acc = int(f[1])
        elif f[0] == "SSA_FALLBACK":
            fb = int(f[1])
        elif f[0] == "SSA_BAILSITE":
            sites[int(f[1])] = int(f[2])
    if "AC_DUMP_END" not in r.stdout:
        raise SystemExit(f"FAIL {name}: driver produced no dump\n{r.stdout}\n{r.stderr}")
    return acc, fb, sites

fails = []

def expect(name, src, want_acc, want_site=None):
    acc, fb, sites = run(name, src)
    ok = (acc == want_acc)
    if want_site is not None:
        ok = ok and sites.get(want_site, 0) >= 1
    if not ok:
        fails.append(f"{name}: accepted={acc} fallback={fb} sites={sites} "
                     f"(wanted accepted={want_acc} site={want_site})")
    else:
        print(f"  ok {name}: accepted={acc} sites={sites}")

# 1. in-file scalar global READ -> accepted
expect("glob_read", """
g: uint32 = 7

def f() -> uint32:
    return g + 1
""", 1)

# 2. in-file scalar global STORE -> accepted
expect("glob_store", """
g: uint64 = 0

def f(x: uint64) -> uint64:
    g = x + 1
    return g
""", 1)

# 3. narrow + signed scalar globals -> accepted
expect("glob_narrow", """
b: uint8 = 3
s: int16 = -2

def f() -> uint32:
    return cast[uint32](b)
""", 1)

# 4. an UNKNOWN name (imported from another module; not in this TU) still bails
#    at site 34.  Standalone compilation cannot see it, and accepting it would
#    be a silent miscompile.
expect("unknown_name", """
from compiler.codegen import (
    glob_count,
)


def f() -> uint32:
    return glob_count + 1
""", 0, want_site=34)

# 5. a bare FUNCTION name as an rvalue bails at the sub-attributed site 103
#    (function-address decay, LLVM path only), NOT at the blended site 34.
expect("funcname_decay", """
def target() -> uint64:
    return 1


def f() -> uint64:
    p: uint64 = cast[uint64](target)
    return p
""", 1, want_site=103)   # `target` itself is accepted; `f` bails at 103

if fails:
    print("FAIL test_ssa_census_fidelity:")
    for x in fails:
        print("  " + x)
    sys.exit(1)
print("PASS test_ssa_census_fidelity")
PY
