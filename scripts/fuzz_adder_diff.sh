#!/usr/bin/env bash
# scripts/fuzz_adder_diff.sh — DIFFERENTIAL gate for the self-hosted Adder
# backend (adder/compiler/codegen.ad) vs the trusted Python backend
# (adder/compiler/codegen_x86.py) + the by-construction oracle.
#
# WHY: codegen.ad is the Adder-in-Adder x86_64 backend (lexer.ad -> parser.ad
# -> codegen.ad). It normally only runs ON-DEVICE under QEMU. This gate runs it
# ENTIRELY ON THE HOST (no QEMU): a host driver ELF (tests/fuzz/
# ad_codegen_dump_driver.ad, compiled to --target=x86_64-linux) executes the
# codegen.ad pipeline on each fuzzer-generated program and dumps the raw
# machine-code + global-data bytes; tests/fuzz/ad_codegen_host.py wraps those
# bytes into a real x86_64-linux ELF (Linux exit_group stub) and runs it. The
# fuzzer's by-construction oracle (already validated against the Python
# backend) is the reference. A program codegen.ad ACCEPTED but ran with the
# WRONG answer is a genuine codegen.ad miscompile; a program codegen.ad cannot
# compile (e.g. 2-D array globals — outside its subset) is UNSUPPORTED, not a
# failure.
#
# It reports:
#   * accept-rate     = codegen.ad accepted / programs run
#   * correctness-rate= (accepted AND correct) / accepted
# and EXITS NONZERO ONLY on a genuine miscompile (codegen.ad accepted, wrong
# answer) or a primary (Python) backend disagreement with the oracle.
#
# HOST-ONLY: needs python3 + as/ld/gcc (binutils + a C driver to preprocess
# user/linux-runtime.S), an x86_64 host. NO QEMU, NO image build.
#
# Usage:
#   bash scripts/fuzz_adder_diff.sh                  # 500 programs, seed 1
#   FUZZ_COUNT=2000 bash scripts/fuzz_adder_diff.sh  # bigger soak
#   FUZZ_SEED=42 bash scripts/fuzz_adder_diff.sh     # different deterministic seed
#
# Deterministic/seeded: each program comes from a per-program seed derived from
# (FUZZ_SEED, index), so a failing program reproduces in isolation via
#   ADDER_FUZZ_DIFF_TARGET=ad-codegen python3 tests/fuzz/adder_fuzzer.py --repro <seed>

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FUZZ_COUNT="${FUZZ_COUNT:-500}"
FUZZ_SEED="${FUZZ_SEED:-1}"
WORK="$PROJ_ROOT/build/fuzz_ad_codegen"

fail() { echo "[fuzz_adder_diff] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v as  >/dev/null 2>&1 || fail "as not found (apt install binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (apt install binutils)"
command -v gcc >/dev/null 2>&1 || fail "gcc not found (preprocesses linux-runtime.S)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

mkdir -p "$WORK"

# ---- Build the host dump driver (codegen.ad pipeline -> raw bytes) ------
# Routed through ad_codegen_host.build_driver() so the cached binary is
# auto-invalidated whenever ANY real input changes (the dump driver .ad, the
# self-hosted compiler .ad set incl. opt.ad/codegen.ad, or the host Adder
# compiler .py set). No manual `rm -rf build/fuzz_ad_codegen` is needed for
# correctness — editing the optimizer and re-running this gate rebuilds.
echo "[fuzz_adder_diff] building host dump driver (codegen.ad -> x86_64-linux)"
python3 - <<'PY' || fail "host dump driver failed to compile"
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
h.build_driver()
PY

# ---- Regression: the codegen.ad gate must reproduce the known-answer
#      regression fixture (tests/fuzz/regress_codegen.ad) through codegen.ad.
#      This pins the three sub-8-byte scalar miscompiles + the cast fix +
#      the signed-load fix that codegen.ad must get right. -----------------
echo "[fuzz_adder_diff] regression: regress_codegen.ad through codegen.ad"
REG_OUT="$(python3 - <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
wd = Path("build/fuzz_ad_codegen")
r = h.run_through_codegen_ad("regress", open("tests/fuzz/regress_codegen.ad").read(), wd)
print(f"{r.kind} {r.stdout} {r.exit}")
PY
)"
echo "[fuzz_adder_diff] regression result: $REG_OUT (expect 'ok 18446742841164082190 14')"
[ "$REG_OUT" = "ok 18446742841164082190 14" ] \
    || fail "codegen.ad miscompiled the regression fixture: $REG_OUT"

# ---- Regression: FLOAT LITERALS (tests/fuzz/regress_float_literals.ad).
#      Pins the self-hosted float-literal fixes: a float-literal DIVISION emits
#      divsd (not integer div / the 0.0/0.0 #DE), and a fractional/exponent
#      literal (0.5, 1.5e1) carries its exact value (not the truncated integer
#      part). This was a fuzz gap — the fuzzer's by-construction oracle derives
#      floats via cast[floatN](int), so it never emitted a bare float literal.
echo "[fuzz_adder_diff] regression: regress_float_literals.ad through codegen.ad"
REGF_OUT="$(python3 - <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
wd = Path("build/fuzz_ad_codegen")
r = h.run_through_codegen_ad("regressf", open("tests/fuzz/regress_float_literals.ad").read(), wd)
print(f"{r.kind} {r.stdout} {r.exit}")
PY
)"
echo "[fuzz_adder_diff] float regression result: $REGF_OUT (expect 'ok 6051507 179')"
[ "$REGF_OUT" = "ok 6051507 179" ] \
    || fail "codegen.ad miscompiled the float-literal regression fixture: $REGF_OUT"

# ---- Regression: UNSAFE-BLOCK LIVENESS (tests/fuzz/regress_unsafe_liveness.ad).
#      Pins the --opt register-allocator miscompile that blanked the desktop: an
#      `unsafe:` body's 2nd+ statements were unscanned by the CFG, truncating a
#      promoted integer local's live range so two genuinely-overlapping locals
#      shared one register. Run through codegen.ad with the native optimizer ON
#      *and* OFF; both must print 333 (pre-fix --opt printed 444). `unsafe:` is a
#      kernel-only construct the differential fuzzer never emits, so this fixed
#      case is the guard.
echo "[fuzz_adder_diff] regression: regress_unsafe_liveness.ad (opt ON+OFF)"
REGU_OUT="$(python3 - <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
wd = Path("build/fuzz_ad_codegen")
body = open("tests/fuzz/regress_unsafe_liveness.ad").read()
off = h.run_through_codegen_ad("regru_off", body, wd, opt=False)
on  = h.run_through_codegen_ad("regru_on",  body, wd, opt=True)
print(f"{off.kind}/{on.kind} off={off.stdout} on={on.stdout}")
PY
)"
echo "[fuzz_adder_diff] unsafe-liveness result: $REGU_OUT (expect 'ok/ok off=333 on=333')"
[ "$REGU_OUT" = "ok/ok off=333 on=333" ] \
    || fail "codegen.ad --opt miscompiled the unsafe-block liveness fixture: $REGU_OUT"

# ---- Regression: MATCH-BODY LIVENESS (tests/fuzz/regress_match_liveness.ad).
#      The GENERAL form of the same --opt clobber: the CFG's opaque-statement
#      fallback routes `match` (and try/with/defer) through a single opaque
#      instruction whose body chains were scanned with cfg_scan_uses — which
#      threads nd_next only of a node's a/b children, so a use living in the
#      SECOND match arm's body was MISSED, truncating a promoted local's live
#      range (two overlapping locals then shared one register). FIX: the fallback
#      now uses cfg_scan_uses_deep, a chain-aware full-subtree use scan. Enum
#      `match` is the one fallback-routed chain-body construct codegen.ad
#      actually compiles, so it is the runnable guard for the whole class. Both
#      opt ON and OFF must print 333 (pre-fix --opt printed 444: x got y's reg).
echo "[fuzz_adder_diff] regression: regress_match_liveness.ad (opt ON+OFF)"
REGM_OUT="$(python3 - <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
wd = Path("build/fuzz_ad_codegen")
body = open("tests/fuzz/regress_match_liveness.ad").read()
off = h.run_through_codegen_ad("regrm_off", body, wd, opt=False)
on  = h.run_through_codegen_ad("regrm_on",  body, wd, opt=True)
print(f"{off.kind}/{on.kind} off={off.stdout} on={on.stdout}")
PY
)"
echo "[fuzz_adder_diff] match-liveness result: $REGM_OUT (expect 'ok/ok off=333 on=333')"
[ "$REGM_OUT" = "ok/ok off=333 on=333" ] \
    || fail "codegen.ad --opt miscompiled the match-body liveness fixture: $REGM_OUT"

# ---- Regression: POINTER/CAST/MEMBER ELEMENT SIGNEDNESS
#      (tests/fuzz/regress_ptr_signedness.ad).
#      ssa.ad's ssa_expr_sgn decides signed-vs-unsigned for `>>` `/` `%` and
#      every ordered compare, and it SILENTLY DEFAULTED every base kind it did
#      not resolve to 0 = "unknown" — which the shift/div selector reads as
#      UNSIGNED and the compare selector reads as SIGNED, so an unresolved base
#      is wrong in BOTH directions at once. `o[i] >> 16` on a `Ptr[int64]`
#      parameter emitted lshr, which is the whole of lib/ed25519.ad's field
#      arithmetic: EVERY valid signature was rejected and /bin/hpm refused its
#      own signed index (fixed in c9585fd2). Same root cause, still live after
#      it: a cast value/base, a call base, and any struct reached through a
#      `Ptr[Struct]` parameter — LANGUAGE.md's canonical `ptr[0].field` idiom.
#      The fuzzer never generated signed arithmetic through a pointer-typed
#      parameter with a NEGATIVE value in range, so this shape needs a fixture.
#      codegen.ad's native lane resolves all of these, so opt ON vs OFF is a
#      real differential: both must print 18446744073709550828 (= -788).
echo "[fuzz_adder_diff] regression: regress_ptr_signedness.ad (opt ON+OFF)"
REGP_OUT="$(python3 - <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
wd = Path("build/fuzz_ad_codegen")
body = open("tests/fuzz/regress_ptr_signedness.ad").read()
off = h.run_through_codegen_ad("regrp_off", body, wd, opt=False)
on  = h.run_through_codegen_ad("regrp_on",  body, wd, opt=True)
print(f"{off.kind}/{on.kind} off={off.stdout} on={on.stdout}")
PY
)"
echo "[fuzz_adder_diff] ptr-signedness result: $REGP_OUT" \
     "(expect 'ok/ok off=18446744073709550828 on=18446744073709550828')"
[ "$REGP_OUT" = "ok/ok off=18446744073709550828 on=18446744073709550828" ] \
    || fail "element-signedness miscompile (ssa_expr_sgn unknown-default): $REGP_OUT"

# ---- Regression: --opt / SSA-lane CALL SHAPES
#      (tests/fuzz/regress_opt2_call_shapes.ad).
#      codegen.ad's legacy -O0 path does NOT lower every ND_CALL as `call <sym>`:
#      gen_call/gen_expr intercept several shapes BY NAME, and gen_call also
#      RE-SHAPES an argument list through normalize_call_args. The SSA builder
#      never enters gen_call and reproduced neither, giving two live --opt bugs:
#        1. an OMITTED TRAILING DEFAULT was marshalled positionally in written
#           order — `defaulted(3)` for `def defaulted(a, b = 7)` returned 30
#           instead of 37, a silent wrong answer with no diagnostic;
#        2. a statement-position `__syscall1(...)` (inline `syscall`, no symbol)
#           emitted `call rel32` + a fixup naming "__syscall1" — cg_fail(7) on a
#           userland target and, far worse, a SILENT PLT32 extern relocation
#           against a nonexistent symbol on a kernel target. Enum-variant
#           constructors, `len(slice)`, `asm_volatile` and the port-I/O
#           intrinsics are the same class.
#      The fixture also pins the shapes a WHITELIST must keep accepting, which is
#      the point: the first attempt at this fix enumerated the intercepted
#      families as a BLACKLIST, missed enum constructors, and turned
#      regress_match_liveness.ad (whose main calls `repro(Second(...))`) from a
#      correct binary into STATUS cgfail reason=7. Both lanes must print 399;
#      pre-fix, --opt printed 392 and (with shape 5) cgfail'd outright.
echo "[fuzz_adder_diff] regression: regress_opt2_call_shapes.ad (opt ON+OFF)"
REGC_OUT="$(python3 - <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
wd = Path("build/fuzz_ad_codegen")
body = open("tests/fuzz/regress_opt2_call_shapes.ad").read()
off = h.run_through_codegen_ad("regrc_off", body, wd, opt=False)
on  = h.run_through_codegen_ad("regrc_on",  body, wd, opt=True)
print(f"{off.kind}/{on.kind} off={off.stdout} on={on.stdout}")
PY
)"
echo "[fuzz_adder_diff] call-shapes result: $REGC_OUT (expect 'ok/ok off=399 on=399')"
[ "$REGC_OUT" = "ok/ok off=399 on=399" ] \
    || fail "codegen.ad --opt miscompiled the SSA call-shape fixture: $REGC_OUT"

# ---- Seeded differential batch -----------------------------------------
echo "[fuzz_adder_diff] differential: count=$FUZZ_COUNT seed=$FUZZ_SEED"
python3 tests/fuzz/adder_fuzzer.py --ad-codegen \
    --count "$FUZZ_COUNT" --seed "$FUZZ_SEED" --max-fail 25
RC=$?
[ "$RC" -eq 0 ] || fail "codegen.ad differential found a genuine miscompile (see report above)"

# ---- ADDER_OPT=1 legacy optimizer lane: REMOVED ------------------------
# opt1 (the AST optimizer opt.ad + its linear-scan allocator) has been RETIRED
# — `--opt` now routes through the SSA pipeline (identical to ADDER_OPT2=1). The
# old ADDER_OPT=1 native-optimizer differential lane exercised opt.ad, which no
# longer exists, so it is gone. The SSA optimizer's correctness is covered by
# running this same gate under ADDER_OPT2=1 (which drives ssa_emit_program), and
# by the OPT2 corpus in adder_fuzzer.py.

echo "[fuzz_adder_diff] PASS"
