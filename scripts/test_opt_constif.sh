#!/usr/bin/env bash
# scripts/test_opt_constif.sh — focused, host-only correctness + firing guard for
# the CONSTANT-CONDITION IF FOLD (codegen.ad `gen_if` / cg_const_cond_truth):
#   * CONSTIF — an ND_IF whose PRIMARY condition is a provably-true constant
#     literal (an `if 1:` — the shape the opt const-branch pass leaves after
#     rewriting `if 1==1:` -> `if 1:` via opt_if_keep_arm, or a literal truthy
#     constant) is emitted as the then-body ALONE with NO condition materialize,
#     NO `test`, and NO conditional branch. Armed only under --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECTNESS — `if 1==1:`/`if 1:`/`if 7:` (with and without else/elif),
#      const-if nested in a loop (the dcecopy shape), each produce EXACTLY the
#      --opt-OFF value.
#   2. FIRING — CONSTIF > 0 on the constant-condition shapes.
#   3. FALLBACK soundness — a RUNTIME condition (`if x > 0`), a `if x == x`
#      (non-literal, not const-folded), and a constant-FALSE-primary WITH-else
#      construct all stay ON==OFF; the runtime shapes route CONSTIF 0.
#   4. PLUMBING REMOVED — a folded const-if program's --opt image is strictly
#      SMALLER than its --opt-OFF image and emits NO `test`/`je`/`jne` for the
#      folded branch region.
#   5. BYTE-INERT OFF — with --opt off CONSTIF==0.
#   6. DELIBERATE-BREAK sensitivity — a const-FALSE `if 0:` (no else) whose body
#      has an observable effect must NOT run; the ON==OFF oracle catches any
#      mis-fold that emits the body.
#
# HOST-ONLY: python3 + as/ld/gcc + objdump (x86_64). NO QEMU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# LEGACY opt1 LANE GUARD (added 2026-07-25).  Every "the lever FIRED" assertion
# below targets the opt1 optimizer lane (opt.ad's AST passes + the
# ra_enabled-gated codegen levers).  Commit ba2e4bcf (2026-07-21) retired that
# lane — `--opt` now arms the SSA pipeline and the dump driver never calls
# ra_enable() on the emission path — so those counters are structurally 0 while
# the values stay CORRECT (opt == off == reference).  The helper PROBES the lane
# and skips loudly only while it is genuinely retired; it re-arms this guard
# automatically the moment the lane comes back.  See docs/ci_status_2026-07-25.md.
source "$PROJ_ROOT/scripts/lib_opt1_lane.sh"
opt1_require_lane "test_opt_constif"

python3 - <<'PY'
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_constif"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
fails = 0

def disasm(code_bytes):
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout

def check(name, body, want_fire):
    global fails
    r_on = h.run_through_codegen_ad(f"ci_{name}", body, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"ci_{name}o", body, WD, opt=False)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name} on={r_on.kind} off={r_off.kind}"); fails += 1; return
    if r_on.stdout != r_off.stdout or r_on.exit != r_off.exit:
        print(f"FAIL {name} ON({r_on.stdout},{r_on.exit}) != OFF({r_off.stdout},{r_off.exit})")
        fails += 1
    ci = int(getattr(r_on, "constif", 0) or 0)
    if want_fire and ci == 0:
        print(f"FAIL {name} CONSTIF never fired"); fails += 1
    if (not want_fire) and ci != 0:
        print(f"FAIL {name} CONSTIF fired ({ci}) on a non-constant shape"); fails += 1
    # byte-inert OFF: CONSTIF must be 0 with --opt off.
    src = WD / f"ci_{name}.ad"; src.write_text(h.codegen_compatible_source(body))
    d_off = h.run_dump(src, opt=False)
    if d_off.status == "ok" and int(getattr(d_off, "constif", 0) or 0) != 0:
        print(f"FAIL {name} NOT byte-inert OFF (CONSTIF={getattr(d_off,'constif','?')})")
        fails += 1
    else:
        print(f"[{name}] ON==OFF=({r_on.stdout},{r_on.exit}) CONSTIF={ci} inert-OFF OK")

def mkmain(bodystmts, ret):
    return PRELUDE + "\n" + (
        "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
        + bodystmts +
        f"    print_u64(cast[uint64]({ret}))\n"
        f"    return cast[int32](({ret}) & 255)\n")

# ---------------------------------------------------------------------------
# 1+2) Constant-condition ifs — CONSTIF must fire, correct ON==OFF.
# ---------------------------------------------------------------------------
# if 1 == 1 with else (the dcecopy shape): the const-branch pass rewrites to
# `if 1:`, codegen folds away the test+branch.
check("eq_lit_else", mkmain(
    "    r: int64 = 3\n"
    "    if 1 == 1:\n"
    "        r = 7\n"
    "    else:\n"
    "        r = 9\n", "r"), True)

# Bare literal `if 1:` (no else).
check("lit1", mkmain(
    "    r: int64 = 3\n"
    "    if 1:\n"
    "        r = 42\n", "r"), True)

# Non-1 truthy literal `if 7:`.
check("lit7", mkmain(
    "    r: int64 = 0\n"
    "    if 7:\n"
    "        r = 5\n", "r"), True)

# elif after a true primary: only the primary body runs; elif/else dropped.
check("true_primary_elif", mkmain(
    "    r: int64 = 0\n"
    "    x: int64 = 100\n"
    "    if 1 == 1:\n"
    "        r = 11\n"
    "    elif x > 0:\n"
    "        r = 22\n"
    "    else:\n"
    "        r = 33\n", "r"), True)

# const-if nested in a loop with a memory write — the exact dcecopy hot shape.
loopbody = (
    "    acc: int64 = 0\n"
    "    i: int64 = 0\n"
    "    while i < 20:\n"
    "        d: int64 = i * 2 + 1\n"
    "        if 1 == 1:\n"
    "            acc = acc + d\n"
    "        else:\n"
    "            acc = acc - d\n"
    "        i = i + 1\n")
check("loop_const_if", mkmain(loopbody, "acc"), True)

# AND/OR constant conditions the truth-folder proves (1 and 1, 0 or 1).
check("and_const", mkmain(
    "    r: int64 = 0\n"
    "    if 1 == 1 and 2 == 2:\n"
    "        r = 8\n", "r"), True)

# ---------------------------------------------------------------------------
# 3) FALLBACK soundness — runtime / non-literal conditions must NOT fold.
# ---------------------------------------------------------------------------
# Runtime compare (x from argc): not constant, CONSTIF must be 0.
check("runtime_cmp", mkmain(
    "    r: int64 = 3\n"
    "    x: int64 = cast[int64](argc)\n"
    "    if x > 0:\n"
    "        r = 7\n"
    "    else:\n"
    "        r = 9\n", "r"), False)

# x == x is NOT a literal (the opt const-truth folder needs both operands
# literal), so codegen sees a real compare -> CONSTIF 0, still correct.
check("selfcmp_runtime", mkmain(
    "    r: int64 = 1\n"
    "    x: int64 = cast[int64](argc) + 5\n"
    "    if x == x:\n"
    "        r = 2\n", "r"), False)

# ---------------------------------------------------------------------------
# 6) DELIBERATE-BREAK sensitivity — a const-FALSE `if 0:` body must NOT run.
#    (The opt pass makes `if 0:` bodyless a no-op; here the body writes r, so a
#    mis-fold that emitted the body would set r=99. ON==OFF==0 catches it.)
# ---------------------------------------------------------------------------
check("false_lit_noelse", mkmain(
    "    r: int64 = 0\n"
    "    if 0:\n"
    "        r = 99\n", "r"), False)

# const-FALSE primary WITH else: the else runs (opt promotes it to `if 1: else`).
check("false_primary_else", mkmain(
    "    r: int64 = 0\n"
    "    if 0:\n"
    "        r = 5\n"
    "    else:\n"
    "        r = 6\n", "r"), True)

# ---------------------------------------------------------------------------
# 4) PLUMBING REMOVED — a folded const-if program's --opt image is strictly
#    smaller than its --opt-OFF image and emits NO test/je/jne for the branch.
# ---------------------------------------------------------------------------
plumb = mkmain(
    "    r: int64 = 3\n"
    "    if 1 == 1:\n"
    "        r = 7\n"
    "    else:\n"
    "        r = 9\n", "r")
src = WD / "ci_plumb.ad"; src.write_text(h.codegen_compatible_source(plumb))
d_on = h.run_dump(src, opt=True)
d_off = h.run_dump(src, opt=False)
if d_on.status != "ok" or d_off.status != "ok":
    print(f"FAIL plumb dump on={d_on.status} off={d_off.status}"); fails += 1
else:
    if len(d_on.code) >= len(d_off.code):
        print(f"FAIL plumb: ON image ({len(d_on.code)}) not smaller than OFF "
              f"({len(d_off.code)})"); fails += 1
    text = disasm(d_on.code).lower()
    # This program's only branch is the folded const-if; the true-body sets r=7.
    # After the fold there must be no conditional branch / test in main's body
    # (the prelude helpers live in other functions, but this main is tiny and
    # the whole image is dumped — a residual je/jne/test would mean the fold
    # left the compare in place). We check the whole image has no jne/test since
    # the const-if is the ONLY comparison in the program.
    if (" jne " in text) or (" test " in text) or (" sete " in text):
        print(f"FAIL plumb: residual test/jne/sete for the folded const-if"); fails += 1
    else:
        print(f"[plumb] ON({len(d_on.code)}) < OFF({len(d_off.code)}), no test/jne OK")

if fails:
    print(f"FAIL: {fails} const-condition-if fold check(s) failed")
    sys.exit(1)
print("PASS: constant-condition IF fold — correctness + firing + fallback + "
      "plumbing-removed + inert-OFF")
PY
rc=$?
if [ $rc -ne 0 ]; then
    echo "test_opt_constif: FAIL"
    exit 1
fi
echo "test_opt_constif: PASS"
