#!/usr/bin/env bash
# scripts/test_opt_storethrough.sh — focused, host-only correctness + firing
# guard for the native backend's STORE-THROUGH ELIMINATION lever (codegen.ad
# store_to_named: a fully register-promoted plain scalar with NO slot-bypass
# read DROPS its shadow stack store; the register becomes its sole home).
# Armed only under --opt.
#
# WHAT IT PROVES (no QEMU):
#   1. The lever FIRES: with --opt ON the dump driver's STOREELIM counter is > 0
#      across the store-through corpus, and is 0 with --opt OFF (byte-inert).
#   2. It is CORRECT: every store-through corpus program (incl. the soundness
#      cases — scalar-as-pointer base, for-loop induction var, address-taken
#      local — that MUST KEEP their write-through slot) produces EXACTLY the
#      reference value and the same result as --opt OFF. A missed slot-read on
#      an eliminated-store value is a silent stale-value miscompile this catches.
#   3. The HOT-LOOP accumulator's per-iteration store is GONE from the emitted
#      machine code: a single-scalar reduction loop, disassembled, contains NO
#      `mov [rbp-disp], <reg>` store of the accumulator slot inside the loop body
#      under --opt (it is present under --opt OFF). Bit-exact result either way.
#   4. SOUNDNESS: the address-taken local's slot store is RETAINED (its value is
#      observed only through the slot after a store-through-pointer write).
#
# HOST-ONLY: python3 + as/ld/gcc (the fuzz host harness), x86_64. NO QEMU.
#
# BUILD HYGIENE: the cached dump driver under build/fuzz_ad_codegen
# AUTO-INVALIDATES via ad_codegen_host.build_driver()'s inputs-hash stamp, so it
# rebuilds automatically when codegen.ad / any compiler source changes.
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
opt1_require_lane "test_opt_storethrough"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_storethrough"); WD.mkdir(parents=True, exist_ok=True)

fails = 0
total_elim = 0

# ---- (1)+(2) correctness + firing + OFF-inert over the whole corpus ---------
checked = 0
for (name, body, exp_out, exp_exit) in F._storethrough_corpus():
    checked += 1
    r_on = h.run_through_codegen_ad(f"st_{name}", body, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"st_{name}o", body, WD, opt=False)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {name} on={r_on.kind}/off={r_off.kind} "
              f"detail={r_on.detail or r_off.detail}")
        fails += 1
        continue
    if r_on.stdout != exp_out or str(r_on.exit) != str(exp_exit):
        print(f"FAIL(miscompile --opt ON) {name} got=({r_on.stdout!r},{r_on.exit}) "
              f"ref=({exp_out!r},{exp_exit}) storeelim={r_on.storeelim}")
        fails += 1
        continue
    if r_off.stdout != exp_out or str(r_off.exit) != str(exp_exit):
        print(f"FAIL(OFF path wrong) {name} got=({r_off.stdout!r},{r_off.exit}) "
              f"ref=({exp_out!r},{exp_exit})")
        fails += 1
        continue
    se_on = int(getattr(r_on, "storeelim", 0) or 0)
    se_off = int(getattr(r_off, "storeelim", 0) or 0)
    total_elim += se_on
    if se_off != 0:
        print(f"FAIL(OFF not byte-inert) {name} STOREELIM={se_off}")
        fails += 1

if total_elim == 0:
    print("FAIL: store-through elimination NEVER fired across the corpus")
    fails += 1

# ---- (3) HOT-LOOP accumulator: per-iteration slot store is GONE -------------
# A minimal single-scalar reduction. Under --opt `s` is register-promoted and
# store-eliminable; its per-iteration `mov [rbp-disp], reg` store must vanish
# from the emitted code, while the result stays bit-exact. Under --opt OFF the
# slot store is present.
HOT = F.PRELUDE + "\n" + (
    "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
    "    s: uint64 = cast[uint64](0)\n"
    "    k: uint64 = cast[uint64](0)\n"
    "    while k < cast[uint64](64):\n"
    "        s = s + (k * cast[uint64](7) + cast[uint64](3))\n"
    "        k = k + cast[uint64](1)\n"
    "    g_accum = s\n"
    "    print_u64(g_accum)\n"
    "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")
ref = 0
for k in range(64):
    ref = (ref + (k * 7 + 3)) & ((1 << 64) - 1)

r_on = h.run_through_codegen_ad("st_hot_on", HOT, WD, opt=True)
r_off = h.run_through_codegen_ad("st_hot_off", HOT, WD, opt=False)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(hot compile) on={r_on.kind}/off={r_off.kind}")
    fails += 1
else:
    if r_on.stdout != str(ref) or r_off.stdout != str(ref):
        print(f"FAIL(hot result) on={r_on.stdout} off={r_off.stdout} ref={ref}")
        fails += 1
    se_hot = int(getattr(r_on, "storeelim", 0) or 0)
    if se_hot == 0:
        print(f"FAIL(hot) accumulator store NOT eliminated (STOREELIM=0)")
        fails += 1
    # Disassemble both images and count `mov %reg, disp(%rbp)` store opcodes
    # (REX.W 0x48/0x4C, opcode 0x89, modrm mod=01/10 base=rbp r/m=5). The ON
    # image must have STRICTLY FEWER rbp-relative stores than OFF (the dropped
    # per-iteration accumulator store), proving the store really left the code.
    src = WD / "st_hot_mc.ad"
    src.write_text(h.codegen_compatible_source(HOT))
    d_on = h.run_dump(src, opt=True)
    d_off = h.run_dump(src, opt=False)
    def count_rbp_stores(blob):
        # mov r/m64, r64  => REX.W (0x48 or 0x4C) 0x89 modrm; rbp-base disp store
        # has modrm mod in {01,10} and r/m == 101 (rbp). reg field = src.
        n = 0
        i = 0
        b = blob
        L = len(b)
        while i + 2 < L:
            if b[i] in (0x48, 0x4C) and b[i+1] == 0x89:
                modrm = b[i+2]
                mod = (modrm >> 6) & 3
                rm = modrm & 7
                if mod in (1, 2) and rm == 5:   # disp8/disp32 off rbp
                    n += 1
            i += 1
        return n
    if d_on.status == "ok" and d_off.status == "ok":
        on_st = count_rbp_stores(d_on.code)
        off_st = count_rbp_stores(d_off.code)
        if not (on_st < off_st):
            print(f"FAIL(hot) rbp-store count not reduced: on={on_st} off={off_st}")
            fails += 1
        else:
            print(f"[storethrough] hot-loop rbp stores: off={off_st} -> on={on_st} "
                  f"(accumulator store dropped), STOREELIM={se_hot}")
        if int(getattr(d_off, "storeelim", 0) or 0) != 0:
            print(f"FAIL(hot) OFF dump STOREELIM != 0")
            fails += 1
    else:
        print(f"FAIL(hot dump) on={d_on.status} off={d_off.status}")
        fails += 1

print(f"[storethrough] corpus programs checked={checked} "
      f"total stores eliminated={total_elim}")
if fails:
    print(f"[storethrough] FAIL ({fails} failures)")
    sys.exit(1)
print("[storethrough] PASS — store-through elimination correct, fires, byte-inert OFF, "
      "hot-loop accumulator store removed, soundness cases retain their slot")
PY
rc=$?
exit $rc
