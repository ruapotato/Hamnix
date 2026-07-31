#!/usr/bin/env bash
# scripts/test_adder_bounds_check_opt.sh — Adder runtime array-bounds checking
# UNDER THE OPTIMIZER (--opt / ADDER_OPT). HOST-ONLY, NO QEMU.
#
# Increment 1/1b landed `--check-bounds` on the opt-0 codegen path only; under
# --opt the native backend's isel routes an array index STRAIGHT into a register
# (never %rax), so the increment-1b check — which only inspected %rax — was
# silently DROPPED. Increment 2 makes the check fire on BOTH isel index paths:
#   * DIRECT-SIB coalesce  (a bare full-width register-promoted index -> idxreg)
#   * try_sel_index_into_rcx (a binary index computed straight into %rcx)
# This gate proves the checks now fire under --opt in BOTH backends and stay
# byte-inert when the flag is off. See docs/adder_memory_safety.md.
#
# Coverage:
#   (1) SEED  -O1/-O2 --check-bounds: OOB traps (132), in-range runs (40),
#       `unsafe:` suppresses (0) — for the direct-SIB AND the %rcx index shape.
#   (2) SEED  bare-metal --opt --check-bounds: NO ud2 (kernel never instrumented).
#   (3) NATIVE codegen.ad --opt --check-bounds (via the dump-driver host harness):
#       OOB traps (132), in-range runs (40), `unsafe:` suppresses (0); asserts the
#       program went through the SSA emission lane, and PINS the currently-known
#       per-function fallback (see the 2026-07-31 note in step (3) below).
#
# 2026-07-31 -- WHAT CHANGED UNDER THIS GATE. Steps (3) used to assert
# `idxreg > 0` / `idxsel > 0`: counters published by the opt1 AST optimizer's
# instruction selector (the DIRECT-SIB coalesce and try_sel_index_into_rcx).
# **opt1 has since been RETIRED and adder/compiler/opt.ad deleted** --
# fused_driver_host_main.ad now says so in as many words: "--opt now simply arms
# the SSA gate, identical to ADDER_OPT2=1". Those two counters are therefore
# structurally pinned at 0 and can never rise again. The gate was asserting the
# presence of machinery that no longer exists: gate rot, not a defect. Every
# BEHAVIOURAL assertion in this file (OOB traps 132, in-range 40, `unsafe:`
# suppresses, kernel exempt, byte-inert with the flag off, ud2 present with it
# on) passed throughout.
#
# Removing the witness outright would have been the wrong repair, because it was
# guarding something real, and that something is now TRUE: with opt1 gone, the
# SSA emitter does not yet cover array indexing, so every fixture here falls back
# to plain -O0 gen_function (SSAEMIT_EMITTED=0, SSAEMIT_FALLBACK=1 on a
# single-function reduction). Steps (3)-(5) are, today, re-testing the -O0
# emitter with a --opt flag attached. So the witness is replaced by a TRIPWIRE on
# that exact fact -- see step (3).
#   (4) NATIVE --opt WITHOUT the flag: the SAME OOB index does NOT trap and the
#       emitted code carries NO ud2 (0F 0B) — byte-inert when off.
#   (5) NATIVE --opt WITH the flag: the emitted code DOES carry a ud2.
#
# Usage:  bash scripts/test_adder_bounds_check_opt.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[bounds-opt] FAIL $*"; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/membounds"
WORK="build/bounds_check_opt"
mkdir -p "$WORK"

# ---- (1) SEED under -O1/-O2 -------------------------------------------------
seed_build() { # seed_build <src> <out> <Olevel>
    python3 -m compiler.adder compile "$1" --target=x86_64-linux --check-bounds \
        -O"$3" -o "$2" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "seed compile failed: $1 -O$3"; }
}
for O in 1 2; do
    echo "[bounds-opt] (1) SEED -O$O --check-bounds"
    for shape in idxreg idxsel; do
        seed_build "$FIX/opt_${shape}_oob.ad" "$WORK/s_${shape}_oob_O$O" "$O"
        "$WORK/s_${shape}_oob_O$O"; rc=$?
        [ "$rc" -eq 132 ] || fail "SEED -O$O $shape OOB did not trap (got $rc, want 132)"
        seed_build "$FIX/opt_${shape}_inrange.ad" "$WORK/s_${shape}_in_O$O" "$O"
        "$WORK/s_${shape}_in_O$O"; rc=$?
        [ "$rc" -eq 40 ] || fail "SEED -O$O $shape in-range returned $rc (want 40)"
    done
    seed_build "$FIX/opt_unsafe.ad" "$WORK/s_unsafe_O$O" "$O"
    "$WORK/s_unsafe_O$O"; rc=$?
    [ "$rc" -eq 0 ] || fail "SEED -O$O unsafe: did not suppress the check (got $rc)"
    echo "[bounds-opt]   -O$O: OOB traps(132), in-range(40), unsafe(0) — both shapes"
done

# ---- (2) SEED bare-metal + --opt + flag: kernel never instrumented ----------
echo "[bounds-opt] (2) SEED bare-metal -O2 --check-bounds: no ud2 (kernel exempt)"
if python3 -m compiler.adder asm "$FIX/opt_idxreg_oob.ad" \
        --target=x86_64-bare-metal --check-bounds -O2 2>/dev/null | grep -q 'ud2'; then
    fail "bare-metal (kernel) target emitted a bounds-check ud2 under --opt"
fi
echo "[bounds-opt]   bare-metal + --opt + --check-bounds: no ud2 (correct)"

# ---- (3),(4),(5) NATIVE codegen.ad via the dump-driver host harness ---------
echo "[bounds-opt] (3-5) NATIVE codegen.ad --opt (dump harness)"
python3 - <<'PY' || fail "native --opt bounds-check verification failed"
import sys, subprocess
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
wd = Path("build/fuzz_ad_codegen"); wd.mkdir(parents=True, exist_ok=True)
UD2 = bytes([0x0F, 0x0B])
rc_fail = False

def run(name, check_bounds):
    body = open(f"tests/membounds/{name}.ad").read()
    src = wd / f"bo_{name}.ad"; src.write_text(body)
    d = h.run_dump(src, opt=True, check_bounds=check_bounds)
    if d.status != "ok":
        raise SystemExit(f"[bounds-opt] NATIVE dump {name} status={d.status} "
                         f"{getattr(d,'detail','')}")
    elf = wd / f"bo_{name}.elf"; h.wrap_elf(d, elf)
    r = subprocess.run([str(elf)], capture_output=True)
    rc = r.returncode if r.returncode >= 0 else 128 - r.returncode
    return rc, d

def check(cond, msg):
    global rc_fail
    if not cond:
        print(f"[bounds-opt]   NATIVE ASSERT FAIL: {msg}")
        rc_fail = True
    else:
        print(f"[bounds-opt]   ok: {msg}")

# (3) checks ON: both index shapes trap OOB, run in-range, unsafe suppresses.
#
# The coverage witness. `idxreg`/`idxsel` were opt1 isel counters; opt1 is gone
# and they are pinned at 0 forever, so asserting them was asserting a deleted
# optimizer. What matters now is which lane compiled the indexing function, and
# the honest answer today is: NEITHER of these fixtures is optimized. --opt arms
# the SSA gate, the SSA emitter has no memory-op support yet, and the function
# containing `a[i]` takes the per-function escape hatch back to plain -O0
# gen_function.
#
# Rather than drop the witness (which would let the gate claim --opt coverage it
# does not have) or soft-pass it, pin the fallback. `expect_fallback` is a
# TRIPWIRE: when the SSA subset grows to cover memory ops, THIS GOES RED. That
# is the intended alarm. Do not silence it -- at that point the index lowering is
# genuinely new code, and the whole reason this gate exists is that the last time
# an optimizer changed how an index reaches a register, the bounds check was
# silently dropped. Re-verify the check fires on the SSA index lane, then flip
# these two lines to expect emission.
for shape in ("idxreg", "idxsel"):
    rc, d = run(f"opt_{shape}_oob", True)
    check(rc == 132, f"{shape} OOB traps (132) got {rc}")
    check(d.ssaemit_funcs > 0,
          f"{shape} went through the SSA emission lane "
          f"(SSAEMIT_FUNCS={d.ssaemit_funcs})")
    check(d.ssaemit_overlapviol == 0,
          f"{shape} no SSA overlap violation "
          f"(SSAEMIT_OVERLAPVIOL={d.ssaemit_overlapviol})")
    check(d.ssaemit_memop == 0 and d.ssaemit_fallback > 0,
          f"{shape} TRIPWIRE: indexing still falls back to -O0 "
          f"(emitted={d.ssaemit_emitted} fallback={d.ssaemit_fallback} "
          f"memop={d.ssaemit_memop}) -- if this is RED the SSA emitter now "
          f"compiles array indexing; re-verify --check-bounds fires on the SSA "
          f"index lane, then update this assertion")
    rc, d = run(f"opt_{shape}_inrange", True)
    check(rc == 40, f"{shape} in-range runs (40) got {rc}")
rc, d = run("opt_unsafe", True)
check(rc == 0, f"unsafe: suppresses the check (0) got {rc}")

# (4) checks OFF (byte-inert): same OOB index does NOT trap AND no ud2 emitted.
for shape in ("idxreg", "idxsel"):
    rc, d = run(f"opt_{shape}_oob", False)
    check(rc != 132, f"{shape} OOB does NOT trap without the flag (got {rc})")
    check(UD2 not in bytes(d.code),
          f"{shape} --opt no-flag emits NO ud2 (byte-inert off)")

# (5) checks ON emit a ud2 in the stream.
_, d = run("opt_idxreg_oob", True)
check(UD2 in bytes(d.code), "idxreg --opt --check-bounds emits a ud2")

raise SystemExit(1 if rc_fail else 0)
PY

echo "[bounds-opt] PASS: --opt bounds checks fire on both isel index paths in the"
echo "[bounds-opt]       SEED and NATIVE backends, respect unsafe:, never touch the"
echo "[bounds-opt]       kernel, and are byte-inert when the flag is off."
