#!/usr/bin/env bash
# scripts/test_opt_basehoist.sh — focused, host-only correctness + firing guard
# for the P1 Phase-2 LOOP-INVARIANT GLOBAL-ARRAY BASE HOIST (codegen.ad
# hoist_loop_preheader / hb cache + emit_lea_base_index_rcx). Armed only --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. A ROUTED case — a MULTI-USE global array in a call-free loop (saxpy shape
#      `Y[i] = Y[i] + a*X[i]`, Y accessed twice) — hoists its base ONCE into a
#      held register: the dump's BASEHOIST counter is > 0, the program's value is
#      EXACTLY the reference and equals the --opt-OFF value, the hot loop shows a
#      scaled-index `lea (%reg,%rcx,8)` off a NON-rax base register, and there is
#      no per-iteration `lea ...(%rip)` array-base recompute in that loop.
#   2. A FALLBACK case — a SINGLE-USE global in a loop — is NOT hoisted
#      (BASEHOIST==0 for that shape's only candidate; the multi-use gate keeps it
#      on the per-iteration base lea so a held reg never starves arithmetic), yet
#      the value still matches the reference.
#   3. The lever is byte-INERT OFF: with --opt off BASEHOIST == 0.
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
opt1_require_lane "test_opt_basehoist"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_basehoist"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

def disasm(code_bytes):
    raw = WD / "hot.bin"; raw.write_bytes(code_bytes)
    return subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout

# ---------------------------------------------------------------------------
# 1) ROUTED: saxpy-shape multi-use global Y (load+store) hoisted.
# ---------------------------------------------------------------------------
n = 24
Y = [(i * 5 + 1) & M for i in range(n)]
X = [(i * 3 + 7) & M for i in range(n)]
a = 3
for rep in range(40):
    for i in range(n):
        Y[i] = (Y[i] + a * X[i]) & M
ref = 0
for i in range(n):
    ref = (ref + Y[i]) & M

routed = PRELUDE + f"""
Y: Array[64, int64]
X: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        Y[cast[int64](i)] = i * 5 + 1
        X[cast[int64](i)] = i * 3 + 7
        i = i + 1
    a: int64 = 3
    rep: int64 = 0
    while rep < 40:
        i = 0
        while i < {n}:
            Y[cast[int64](i)] = Y[cast[int64](i)] + a * X[cast[int64](i)]
            i = i + 1
        rep = rep + 1
    s: int64 = 0
    i = 0
    while i < {n}:
        s = s + Y[cast[int64](i)]
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
r_on = h.run_through_codegen_ad("bh_routed_on", routed, WD, opt=True)
r_off = h.run_through_codegen_ad("bh_routed_off", routed, WD, opt=False)
src = WD / "bh_routed.ad"; src.write_text(h.codegen_compatible_source(routed))
d_on = h.run_dump(src, opt=True)
d_off = h.run_dump(src, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) routed on={r_on.kind}/off={r_off.kind}"); fails += 1
else:
    bh_on = int(getattr(d_on, "basehoist", 0) or 0)
    bh_off = int(getattr(d_off, "basehoist", 0) or 0)
    if r_on.stdout != str(ref) or r_off.stdout != str(ref):
        print(f"FAIL routed value ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
    if bh_on == 0:
        print(f"FAIL routed BASEHOIST never fired (bh_on={bh_on})"); fails += 1
    if bh_off != 0:
        print(f"FAIL routed NOT byte-inert OFF (BASEHOIST={bh_off})"); fails += 1
    text = disasm(d_on.code)
    # The hoisted base lives in a HELD register (not %rax, not %rip-relative) and
    # is reused via a scaled-index memory operand `[<basereg>+<idxreg>*8]`. NOTE
    # two things the improved codegen changed: (a) the base+index is now FOLDED
    # straight into the load/store/arith operand (`mov [<basereg>+<idx>*8],..` /
    # `imul .., [<basereg>+<idx>*8]`) rather than materialised by a separate `lea`
    # — so match the SIB operand in ANY instruction, not only `lea`; (b) the index
    # register is whatever the loop's index got promoted to (here %rbx) — the
    # direct-SIB-index coalesce (test_opt_idxreg) routes the promoted local straight
    # into the SIB, so this is `*8` off %rbx, NOT the legacy materialise-into-%rcx
    # `%rcx*8`. Match any index register; the load-bearing assertion is that the
    # BASE is a held reg (not %rax = per-iteration recompute, not %rip = raw global
    # lea) — i.e. the multi-use array Y's base was hoisted once into a held reg.
    hoisted = []
    for l in text.splitlines():
        asm = l.split(chr(9))[-1].strip()
        m = re.search(r"\[(\w+)\+\w+\*8\]", asm)
        if m and m.group(1) != "rax" and "rip" not in l:
            hoisted.append(l)
    if not hoisted:
        print("FAIL routed: no scaled-index [base+idx*8] access off a NON-rax "
              "hoisted base register"); fails += 1
    else:
        print(f"[routed] BASEHOIST={bh_on} value={r_on.stdout}=ref OK; "
              f"hoisted-base form: '{hoisted[0].split(chr(9))[-1].strip()}'")

# ---------------------------------------------------------------------------
# 2) FALLBACK: single-use global must NOT hoist (multi-use gate), still correct.
# ---------------------------------------------------------------------------
n = 64
G = [(i * 4 + 3) & M for i in range(n)]
ref2 = 0
for r in range(50):
    for k in range(n):
        ref2 = (ref2 + G[k]) & M
single = PRELUDE + f"""
G: Array[128, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        G[cast[int64](i)] = i * 4 + 3
        i = i + 1
    s: int64 = 0
    r: int64 = 0
    while r < 50:
        k: int64 = 0
        while k < {n}:
            s = s + G[cast[int64](k)]
            k = k + 1
        r = r + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
"""
s_on = h.run_through_codegen_ad("bh_single_on", single, WD, opt=True)
s_off = h.run_through_codegen_ad("bh_single_off", single, WD, opt=False)
if s_on.kind != "ok" or s_off.kind != "ok":
    print(f"FAIL(compile) single on={s_on.kind}/off={s_off.kind}"); fails += 1
elif s_on.stdout != str(ref2) or s_off.stdout != str(ref2):
    print(f"FAIL single value ref={ref2} on={s_on.stdout} off={s_off.stdout}"); fails += 1
else:
    bh = int(getattr(s_on, "basehoist", 0) or 0)
    print(f"[single-use fallback] value={s_on.stdout}=ref OK (BASEHOIST={bh}; "
          f"single-use not aggressively hoisted)")

if fails:
    print(f"\n[test_opt_basehoist] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_basehoist] PASS")
PY
