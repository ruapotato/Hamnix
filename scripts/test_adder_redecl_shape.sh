#!/usr/bin/env bash
# scripts/test_adder_redecl_shape.sh — regression gate: re-declaring a live
# name with a DIFFERENT storage shape must rebind it to a fresh slot.
#
# Adder has no block scoping, so a second `x: T2` in a sibling branch is a
# FRESH binding. The seed oracle (codegen_x86.alloc_local) implements exactly
# that: every VarDecl allocates a new slot and rebinds self.locals[name]. The
# native backend (codegen.ad) used to keep the FIRST slot forever and only
# re-tag its scalar metadata — fine while both declarations are 8-byte scalars,
# silently WRONG when the storage shapes differ:
#
#     tk: int32 = 0                 # branch A: an 8-byte scalar slot
#     ...
#     tk: Array[128, uint8]         # branch B: 128 reserved bytes
#     tn: int32 = _arg_bytes(0, &tk[0], 128)
#
# `&tk[0]` resolved to branch A's SCALAR slot, so native emitted
# `mov -off(%rbp),%rax` (load the slot's VALUE as a base address) with a
# default 8-byte element stride where the seed emits `lea -off(%rbp),%rax`
# with a 1-byte stride — the callee then wrote up to 128 bytes through
# whatever integer branch A had last left in that slot.
#
# That single cause was the WHOLE of test_native_vs_seed_objdiff.sh's red: 13
# diverged units, every one of them carrying lib/web/dom/canvas.ad's
# _js_host_dispatch (tk, nk, cq) or lib/hamsheetcore.ad's _eval_scalar_fn
# (acc). The whole-tree gate needs >20 minutes to say so; these four fixtures
# say it in seconds, over all four shape transitions:
#
#     scalar_to_array   scalar -> Array[N, uint8]   (canvas.ad tk / nk)
#     array_to_scalar   Array[N, uint8] -> scalar   (hamsheetcore.ad acc)
#     scalar_to_ptr     scalar -> Ptr[uint8]        (canvas.ad cq)
#     ptr_to_scalar     Ptr[uint8] -> uint64        (syscall.ad cur)
#
# Host-only (no QEMU); seconds.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FIX="tests/redecl"
WORK="build/redecl_check"
mkdir -p "$WORK"

fail() { echo "[redecl] FAIL: $*"; exit 1; }

# Clean the fuzz codegen scratch so the native host compiler rebuilds fresh
# (per the compiler-verify discipline).
rm -rf build/fuzz_ad_codegen

echo "[redecl] seed<->native byte-lockstep on the shape-changing re-declaration fixtures"
bash scripts/test_native_vs_seed_objdiff.sh \
    "$FIX/scalar_to_array.ad" "$FIX/array_to_scalar.ad" \
    "$FIX/scalar_to_ptr.ad" "$FIX/ptr_to_scalar.ad" \
    >"$WORK/objdiff.log" 2>&1 \
    || { tail -30 "$WORK/objdiff.log"; fail "seed<->native re-declaration objdiff diverged"; }
grep -q "zero semantic divergences" "$WORK/objdiff.log" \
    || { tail -30 "$WORK/objdiff.log"; fail "objdiff did not report zero divergences"; }
# All four fixtures must be native-ACCEPTED — an acceptance regression would
# silently drop a case from the differential and the gate would still be green.
grep -q "native-accepted=4" "$WORK/objdiff.log" \
    || { tail -30 "$WORK/objdiff.log"; fail "expected 4 native-accepted re-declaration fixtures"; }
echo "[redecl]   $(grep 'semantically CLEAN' "$WORK/objdiff.log")"

# The shipping sites this came from, so a future re-introduction of the
# single-slot behaviour is caught at the source and not only in the fixtures.
echo "[redecl] the in-tree sites that exercise it are still present"
for site in \
        "lib/web/dom/canvas.ad:tk" \
        "lib/web/dom/canvas.ad:nk" \
        "lib/web/dom/canvas.ad:cq" \
        "lib/hamsheetcore.ad:acc"; do
    f="${site%%:*}"; n="${site##*:}"
    c="$(grep -cE "^\s+${n}\s*:" "$f")"
    [ "$c" -ge 2 ] \
        || echo "[redecl]   NOTE $f no longer re-declares '$n' ($c decl) — fixtures still cover it"
done

echo "[redecl] PASS — a shape-changing re-declaration rebinds to its own slot,"
echo "[redecl]        seed==native byte-lockstep across all four shape transitions."
