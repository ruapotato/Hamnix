#!/usr/bin/env bash
# scripts/test_ssa_cluster_exhaustive.sh — the six construct-cluster census
# levers must ACCOUNT FOR THE WHOLE native-vs-memory-model gap.
#
# WHY THIS GATE EXISTS (2026-08-05):
#   scripts/ssa_cluster_lift_diff.sh sizes the SSA subset's next target by
#   splitting the 61.15% -> 88.23% ceiling into six construct clusters (call,
#   arity, member, float, addr, nonlocal) and running a lift-and-diff for each.
#   Every additive row in that table is only trustworthy if the six clusters are
#   EXHAUSTIVE.  If some construct separates the native lane from ssa_mem_model
#   and no ssa_census_keep_* lever names it, that construct's functions ride
#   along inside whichever cluster happens to be lifted, and the table silently
#   over-credits it.  That is exactly the failure mode that made "site 66 =
#   36.9% of bails" read as one actionable target when it was two constructs,
#   neither worth anything alone.
#
#   The self-check is an equality: arming ssa_mem_model AND all six keep levers
#   must reproduce the UNFLAGGED census exactly -- same accepted count, same bail
#   site histogram.  Holding every cluster at its native behaviour can only equal
#   the native lane if the clusters cover everything.
#
#   This is a REGRESSION gate, not a discovery tool: it goes red the moment
#   someone widens ssa_mem_model with a new construct and forgets to give it a
#   keep lever, which is the one way the measurement instrument rots.
#
# WHAT IT PROVES (host-only, no QEMU, seconds):
#   For each of a handful of large REAL compiler sources, the --dump-ssa census
#   run with `--ssa-memmodel` plus all six `--ssa-keep-*` flags is identical --
#   accepted, fallback, and every bail site count -- to the same census run with
#   no flags at all.  It also checks the two ends are actually DIFFERENT (the
#   ceiling accepts strictly more), so the equality above cannot pass by the
#   levers being inert.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import subprocess, sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h

h.build_driver()
DRV = str(h.DRIVER_ELF)

KEEPS = ["--ssa-keep-call", "--ssa-keep-arity", "--ssa-keep-member",
         "--ssa-keep-float", "--ssa-keep-addr", "--ssa-keep-nonlocal"]

# Real, large sources: they carry enough construct variety that a missing
# cluster shows up.  Kept short so the gate stays a few seconds.
CORPUS = [
    "adder/compiler/ssa.ad",
    "adder/compiler/ssa_emit.ad",
    "adder/compiler/ssa_llvm.ad",
    "adder/compiler/cfg.ad",
    "adder/compiler/parser.ad",
    "adder/compiler/lexer.ad",
]

def census(path, args):
    r = subprocess.run([DRV, "--dump-ssa", *args, path],
                       capture_output=True, text=True, timeout=600)
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
    return acc, fb, sites

fail = 0
tot_base = tot_ceil = 0
for path in CORPUS:
    base = census(path, [])
    keep = census(path, ["--ssa-memmodel", *KEEPS])
    ceil = census(path, ["--ssa-memmodel"])

    if base != keep:
        print(f"  FAIL {path}: memmodel+all-keeps != baseline")
        print(f"       baseline accepted={base[0]} fallback={base[1]} sites={base[2]}")
        print(f"       allkeep  accepted={keep[0]} fallback={keep[1]} sites={keep[2]}")
        print( "       => some construct separating the native lane from")
        print( "          ssa_mem_model has NO ssa_census_keep_* lever, so every")
        print( "          additive row in ssa_cluster_lift_diff.sh over-credits")
        print( "          whichever cluster it rides along inside.")
        fail = 1
        continue
    tot_base += base[0]
    tot_ceil += ceil[0]
    print(f"  ok {path}: baseline=allkeep=({base[0]} acc, {base[1]} fb), "
          f"ceiling={ceil[0]} acc")

# The equality above is only meaningful if the two ends really differ.  Checked
# in AGGREGATE, not per file: a single file can legitimately have no
# memory-model-liftable construct in it at all.
if tot_ceil <= tot_base:
    print(f"  FAIL corpus ceiling {tot_ceil} <= baseline {tot_base}: the keep")
    print( "       levers cannot be validated against an inert ceiling -- either")
    print( "       --ssa-memmodel stopped working or the corpus lost its variety")
    fail = 1
else:
    print(f"  ok corpus: baseline {tot_base} accepted, ceiling {tot_ceil} "
          f"(+{tot_ceil - tot_base}); the levers are exercised")

if fail:
    print("FAIL test_ssa_cluster_exhaustive")
    sys.exit(1)
print("PASS test_ssa_cluster_exhaustive")
PY
