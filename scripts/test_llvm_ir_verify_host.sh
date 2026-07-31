#!/usr/bin/env bash
# test_llvm_ir_verify_host.sh — assert the Adder LLVM backend emits VALID LLVM
# IR, and that our two largest apps emit with ZERO SSA-subset bails.
#
# WHY THIS GATE EXISTS
# --------------------
# The LLVM lane had no check that the IR it emits is well-formed. clang is the
# only consumer, and clang's reaction to malformed IR is not reliably an error:
# on 2026-07-30, raising SSA_BB_MAX for the host build without raising
# ssa_llvm.ad's separately-spelled LL_BB_MAX made llvm_bb_live[] report every
# block id >= 1024 as dead, and phi emission SILENTLY DROPS operands whose
# predecessor is not live. `_handle_tag` came out with phis carrying missing or
# zero incoming entries — "PHINode should have one entry for each predecessor"
# to the verifier, and a SIGSEGV inside SimplifyCFG to clang-19 at every -O
# level (not a stack-depth issue; it reproduces at `ulimit -s 65536`). A crash
# was the lucky outcome. The same dropped-operand shape on a phi that LLVM
# happens to accept is a silent miscompile, and this lane has already shipped
# one of those (684 sites / 123 binaries, found only because Ed25519 broke
# loudly).
#
# So: run the IR through `opt -passes=verify` — the same check clang skips when
# it ingests textual .ll — before it ever reaches clang.
#
# WHAT IT ASSERTS
#   1. Every unit below emits IR that passes `opt -passes=verify`.
#   2. hambrowse and js emit with zero `; BAILED @` markers. They are the two
#      biggest apps and the last two to reach the LLVM lane; a bail in either
#      one drops it back to the native fallback lane (x86) or hard-fails the
#      link (arm64, which has no fallback). This is the ratchet that keeps
#      build_user.sh at 278/278.
#   3. The gate can still fail: a self-test feeds `opt` a knowingly-invalid
#      phi and requires the verifier to reject it.
#
# Host-only: no QEMU. Needs `opt` (llvm-19 or plain) and build/cutover/host_ac.elf.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT" || exit 1

OPT_BIN="${ADDER_LLVM_OPT:-}"
if [ -z "$OPT_BIN" ]; then
    for c in opt-19 opt-18 opt-17 opt; do
        command -v "$c" >/dev/null 2>&1 && { OPT_BIN="$c"; break; }
    done
fi
if [ -z "$OPT_BIN" ]; then
    echo "[llvm-ir-verify] SKIP: no llvm 'opt' on PATH (set ADDER_LLVM_OPT)"
    exit 0
fi

HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
if [ ! -x "$HOST_AC" ]; then
    echo "[llvm-ir-verify] building $HOST_AC ..."
    # shellcheck disable=SC1091
    source scripts/_adder_cc.sh
    adder_cc_bootstrap >/dev/null 2>&1 || {
        echo "[llvm-ir-verify] FAIL: could not bootstrap $HOST_AC"; exit 1; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0

# --- self-test: prove `opt -passes=verify` actually rejects what we care about.
# A phi with fewer incoming entries than the block has predecessors is EXACTLY
# the shape the LL_BB_MAX bug produced. If this passes, the gate is decorative.
cat >"$WORK/bad.ll" <<'EOF'
define i64 @f(i64 %c) {
entry:
  %t = icmp ne i64 %c, 0
  br i1 %t, label %a, label %b
a:
  br label %j
b:
  br label %j
j:
  %p = phi i64 [ 1, %a ]
  ret i64 %p
}
EOF
if "$OPT_BIN" -passes=verify -disable-output "$WORK/bad.ll" >/dev/null 2>&1; then
    echo "[llvm-ir-verify] SELFTEST FAIL: $OPT_BIN accepted a phi missing a predecessor entry"
    echo "[llvm-ir-verify]   this gate cannot detect the bug it exists for."
    exit 1
fi
echo "[llvm-ir-verify] selftest OK: verifier rejects a short phi"

# --- units. hambrowse and js are the ratchet; the rest are cheap breadth over
# the shapes the backend emits (kernel-ish, float, string, GUI, compiler).
ZERO_BAIL_UNITS="user/hambrowse.ad user/js.ad"
OTHER_UNITS="user/hamsh.ad user/hamsheet.ad adder/compiler/adder_cc_driver.ad"

for u in $ZERO_BAIL_UNITS $OTHER_UNITS; do
    [ -f "$u" ] || { echo "[llvm-ir-verify] skip (missing): $u"; continue; }
    base="$(basename "$u" .ad)"
    ll="$WORK/$base.ll"
    if ! "$HOST_AC" --backend=llvm "$u" "$ll" >"$WORK/$base.emit" 2>&1; then
        echo "[llvm-ir-verify] FAIL: emit failed for $u"
        tail -5 "$WORK/$base.emit"
        fail=1
        continue
    fi
    if ! "$OPT_BIN" -passes=verify -disable-output "$ll" >"$WORK/$base.verr" 2>&1; then
        echo "[llvm-ir-verify] FAIL: invalid LLVM IR emitted for $u"
        head -12 "$WORK/$base.verr"
        fail=1
        continue
    fi
    nb=$(grep -c '^; BAILED @' "$ll" 2>/dev/null || true)
    nb=${nb:-0}
    case " $ZERO_BAIL_UNITS " in
        *" $u "*)
            if [ "$nb" -ne 0 ]; then
                echo "[llvm-ir-verify] FAIL: $u must emit with ZERO bails, got $nb:"
                grep '^; BAILED @' "$ll" | head -5
                echo "[llvm-ir-verify]   a bail here drops $base off the LLVM lane on x86"
                echo "[llvm-ir-verify]   and HARD-FAILS the arm64 link (no native fallback there)."
                echo "[llvm-ir-verify]   The marker carries site=/line=/counters — read them."
                fail=1
            else
                echo "[llvm-ir-verify] OK: $u  IR valid, 0 bails"
            fi
            ;;
        *)
            echo "[llvm-ir-verify] OK: $u  IR valid ($nb bail(s), not ratcheted)"
            ;;
    esac
done

echo "[llvm-ir-verify] ============================================"
if [ "$fail" -ne 0 ]; then
    echo "[llvm-ir-verify] RESULT: FAIL"
    exit 1
fi
echo "[llvm-ir-verify] RESULT: PASS"
exit 0
