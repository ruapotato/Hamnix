#!/usr/bin/env bash
# scripts/test_selfhost_wholetree_diff.sh — Track-3 self-hosting CUTOVER
# WHOLE-TREE differential (host-only, NO QEMU).
#
# The fuzz dry-run (test_selfhost_cutover_dryrun.sh) proves codegen.ad
# matches the Python seed across the FUZZ CORPUS — but the fuzzer only
# generates a narrow subset of the language. This gate asks the harder,
# real question the cutover actually depends on:
#
#   Does the self-hosted `.ad` host compiler (build/cutover/host_ac.elf)
#   ACCEPT and compile every REAL compilation unit the production build
#   feeds to the Python seed?
#
# It compiles each real userland `.ad` unit with BOTH backends:
#   * Python seed:  python3 -m compiler.adder compile --target=x86_64-adder-user
#   * .ad compiler: build/cutover/host_ac.elf <in.ad> <out.elf>
# and reports, per unit, whether each backend ACCEPTED the source.
#
# IMPORTANT — current state (see docs/subsystems/adder-compiler.md
# "Self-hosting cutover — WHOLE-TREE blocker"): the `.ad` compiler is a
# CLOSED-WORLD, single-translation-unit subset compiler. Capability #1 of
# the cutover (EXTERN LINKAGE) has LANDED: codegen.ad now synthesizes the
# `sys_*` syscall-wrapper bodies user/runtime.S provides (link_runtime_
# externs), so every single-TU unit whose only blocker was extern linkage
# now compiles + behaves identically to the seed (proven by
# test_selfhost_extern_link.sh). CAP#2 (IMPORT RESOLUTION) has ALSO LANDED:
# the host driver (fused_driver_host_main.ad) now discovers a unit's `import`
# closure, merges every module into one TU (import lines stripped), and
# compiles it — so this gate ATTEMPTS the multi-TU units too, and for every
# multi-TU unit host_ac accepts it PROVES the driver's merge is the same
# program the seed's collect_all_imports+merge_programs closure produces
# (identical function set). This script is a TRACKING / REGRESSION gate: it
# asserts the seed still compiles 100% of the tree, reports the `.ad`
# acceptance count + blocker breakdown, and must NOT regress the `.ad`-accepted
# baseline.
#
# STATE, MEASURED 2026-07-31: 265 of 266 units accepted, 128 of 129 multi-TU,
# every one of the 128 merge-equivalent to the seed closure. reason 7 = 0,
# reason 8 = 0, parse errors = 0 -- unsupported constructs are no longer the
# blocker. The ONE reject is `hambrowse`, on "[host_ac] FAIL: ELF emit error
# (overflow)": the .ad compiler parses and codegens the largest unit in the
# tree and then exhausts an emitter cap. That is the next capability, and it is
# a CAP, not a language hole.
#
# Usage:  bash scripts/test_selfhost_wholetree_diff.sh
#
# Env:
#   WT_BASELINE_AD_OK  expected minimum .ad-accepted units (default 265).
#                      Raise it whenever acceptance grows -- a ratchet left
#                      behind is a regression that reports PASS.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Post CAP#2 (import resolution): 119 single-TU + 10 multi-TU = 129 accepted.
# Post CAP#4 cast[Ptr[T]](expr)[i] indexed load/store: +2 multi-TU = 131.
# Post CAP#4b inline asm_volatile(...) lowering: +3 = 134.
# Post CAP#3b (kernel-target codegen lifts that ALSO help userland: SysV >6-arg
# calls, indirect calls through fn-ptr locals/globals, port-I/O + atomic
# intrinsics, container_of/sizeof, nested member access, indexed
# struct-array/Ptr member base, multi-dimensional array LOCALS,
# uint64-as-pointer scalar index base): 194 accepted (69 multi-TU).
# 2026-07-31 MEASURED: 265 of 266 accepted, 128 of 129 multi-TU. The ratchet had
# been left at 194 while acceptance grew, so 71 units of real progress were
# unguarded -- a regression back to 195 would have reported PASS. The single
# remaining reject is `hambrowse`, and it is NOT an unsupported construct: it
# reaches "[host_ac] FAIL: ELF emit error (overflow)", i.e. the .ad compiler
# parses and codegens the biggest unit in the tree and then runs out of an
# emitter cap. reason 7 = 0, reason 8 = 0, parse errors = 0.
BASELINE_AD_OK="${WT_BASELINE_AD_OK:-265}"

fail() { echo "[wholetree] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v as  >/dev/null 2>&1 || fail "as not found (binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (binutils)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64"

WT="build/cutover/wt"
mkdir -p "$WT" build/cutover

# --- (1) Build host_ac.elf via the Python seed (the bootstrap/trust root).
echo "[wholetree] (1/2) build the .ad host compiler (host_ac.elf) via the Python seed"
python3 - <<'PY' || fail "concat host compiler source failed"
import importlib.util
spec = importlib.util.spec_from_file_location("ccs", "scripts/concat_compiler_source.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.DRIVER_MAIN = "fused_driver_host_main.ad"
raise SystemExit(m.main(["concat", "-o", "build/cutover/host_compiler.ad", "--with-driver"]))
PY
python3 -m compiler.adder compile --target=x86_64-linux \
    build/cutover/host_compiler.ad -o build/cutover/host_ac.elf \
    >/dev/null 2>build/cutover/host_ac.cerr \
    || { cat build/cutover/host_ac.cerr; fail "host_ac.elf failed to build"; }
[ -x build/cutover/host_ac.elf ] || fail "no host_ac.elf produced"
echo "[wholetree]   host_ac.elf OK: $(stat -c%s build/cutover/host_ac.elf) bytes"

# --- (2) Whole-tree differential over real userland units.
echo "[wholetree] (2/2) compile every real userland .ad unit with BOTH backends"

units="$(grep 'build_adder_user ' scripts/build_user.sh | awk '{print $2}')"

total=0; single_tu=0; multi_tu=0
seed_ok=0; seed_fail=0
ad_ok=0; ad_fail=0; ad_ok_multi=0
r7=0; r8=0; rparse=0; rother=0
ad_ok_names=""

for f in $units; do
    src="user/$f.ad"
    [ -f "$src" ] || src="tests/$f.ad"
    [ -f "$src" ] || continue
    total=$((total + 1))

    imp="$(grep -c '^from \|^import ' "$src")"
    is_multi=0
    if [ "$imp" != "0" ]; then
        multi_tu=$((multi_tu + 1))
        is_multi=1
    else
        single_tu=$((single_tu + 1))
    fi

    # Python seed (the oracle): MUST accept every real unit. The seed CLI
    # resolves imports itself (compile_with_imports), so the same invocation
    # works for single- AND multi-TU units.
    if python3 -m compiler.adder compile --target=x86_64-adder-user "$src" \
            -o "$WT/${f}.seed.elf" >/dev/null 2>"$WT/${f}.seed.err"; then
        seed_ok=$((seed_ok + 1))
    else
        seed_fail=$((seed_fail + 1))
        echo "[wholetree]   SEED REJECTED $src — oracle must accept the real tree"
    fi

    # .ad host compiler. CAP#2: host_ac.elf now resolves `import`s itself —
    # it discovers the closure from the unit path, merges (imports stripped),
    # and compiles the whole TU. A 4th arg dumps the merged source so the
    # equivalence check below can prove the merge matches the seed's closure.
    if build/cutover/host_ac.elf "$src" "$WT/${f}.ad.elf" "$WT/${f}.merged.ad" \
            >"$WT/${f}.ad.err" 2>&1; then
        ad_ok=$((ad_ok + 1))
        ad_ok_names="$ad_ok_names $f"
        if [ "$is_multi" = "1" ]; then
            ad_ok_multi=$((ad_ok_multi + 1))
        fi
    else
        ad_fail=$((ad_fail + 1))
        err="$(cat "$WT/${f}.ad.err")"
        case "$err" in
            *"reason=7"*) r7=$((r7 + 1)) ;;
            *"reason=8"*) r8=$((r8 + 1)) ;;
            *"parse error"*) rparse=$((rparse + 1)) ;;
            *) rother=$((rother + 1)) ;;
        esac
    fi
done

# --- (3) EQUIVALENCE: for every multi-TU unit host_ac accepts, prove its
# import merge is the SAME program the seed's collect_all_imports +
# merge_programs produces (identical function set: orig-name, param count,
# body length). Combined with the fuzz dry-run (codegen.ad == seed on a
# single TU), this proves the merged multi-TU programs are behaviourally
# equivalent to the seed's. Hamnix-syscall ELFs can't run on host Linux, so
# the function-set identity is the soundest host-observable equivalence.
equiv_ok=0
equiv_fail=0
for f in $units; do
    src="user/$f.ad"
    [ -f "$src" ] || src="tests/$f.ad"
    [ -f "$src" ] || continue
    [ "$(grep -c '^from \|^import ' "$src")" = "0" ] && continue   # multi-TU only
    # ONLY the multi-TU units host_ac ACCEPTED (a `.merged.ad` dump is written
    # for any unit host_ac parses, including ones it later rejects at codegen,
    # whose partial/over-cap merge is irrelevant — equivalence is asserted only
    # for the programs host_ac actually compiled).
    case " $ad_ok_names " in *" $f "*) : ;; *) continue ;; esac
    [ -f "$WT/${f}.merged.ad" ] || continue
    if WT_F="$f" WT_SRC="$src" WT_MERGED="$WT/${f}.merged.ad" python3 - <<'PY'
import os, sys
from pathlib import Path
from compiler.adder import collect_all_imports, find_hamnix_root, merge_programs
from compiler.parser import parse
from compiler.ast_nodes import FunctionDef
root = find_hamnix_root()
src = root / os.environ["WT_SRC"]
merged = Path(os.environ["WT_MERGED"])
def fnset(prog):
    out = set()
    for d in prog.declarations:
        if isinstance(d, FunctionDef):
            # 2026-07-31 — this was `getattr(d, "orig_name", None) or d.name`,
            # and that compared two different things. merge_programs renames a
            # module-private function to its mangled post-merge name (d.name,
            # e.g. lib_9p_9p__p9_get_u32) and keeps the pre-merge spelling in
            # d.orig_name. The DRIVER side is a fresh parse of the merged TEXT,
            # which has no orig_name, so the seed contributed `_p9_get_u32` and
            # the driver contributed `lib_9p_9p__p9_get_u32` for the SAME
            # function and the sets could not intersect.
            #
            # It went unnoticed while only 11 multi-TU units were accepted (the
            # 3 with no module-private functions passed, and this gate never ran
            # in a sweep). CAP#3b took acceptance to 128 and 125 of them "failed"
            # equivalence on nothing but the name column: measured across all
            # 128, seed and driver agree on every function's post-merge name,
            # parameter count and body length.
            #
            # d.name on BOTH sides is the right key: it is the identity of the
            # program that actually gets compiled, and a divergent mangling
            # scheme would still be caught.
            out.add((d.name, len(d.params), len(d.body)))
    return out
seed = merge_programs(collect_all_imports(src, root))
drv = parse(merged.read_text(), str(merged))
sys.exit(0 if fnset(seed) == fnset(drv) else 1)
PY
    then
        equiv_ok=$((equiv_ok + 1))
    else
        equiv_fail=$((equiv_fail + 1))
        echo "[wholetree]   EQUIV FAIL $f — driver merge != seed closure"
    fi
done

echo
echo "===== WHOLE-TREE DIFFERENTIAL REPORT ====="
echo "real userland .ad units:        $total"
echo "  single-TU (0 imports):        $single_tu"
echo "  multi-TU (imports):           $multi_tu"
echo "Python seed (oracle):"
echo "  accepted:                     $seed_ok"
echo "  REJECTED:                     $seed_fail"
echo ".ad host compiler (host_ac.elf):"
echo "  accepted (total):             $ad_ok    [$ad_ok_names ]"
echo "    of which multi-TU:          $ad_ok_multi   (CAP#2 import resolution)"
echo "  rejected:                     $ad_fail"
echo "    reason 7 (no extern link):  $r7"
echo "    reason 8 (unsup construct): $r8"
echo "    parse error:                $rparse"
echo "    other:                      $rother"
echo "multi-TU import-merge equivalence (vs seed closure):"
echo "  proven equivalent:            $equiv_ok"
echo "  NOT equivalent:               $equiv_fail"
echo "=========================================="

# The Python seed is the oracle: it MUST compile 100% of the real tree.
[ "$seed_fail" -eq 0 ] || fail "Python seed rejected $seed_fail real unit(s) — oracle broken"

# Guard the .ad baseline against REGRESSION (it should only ever grow as
# codegen.ad/elf_emit.ad gain extern linkage + import resolution + constructs).
if [ "$ad_ok" -lt "$BASELINE_AD_OK" ]; then
    fail ".ad accepted $ad_ok < baseline $BASELINE_AD_OK — codegen.ad regressed"
fi

# Every multi-TU unit host_ac accepts MUST be import-merge-equivalent to the
# seed's closure (no silently-divergent merge).
[ "$equiv_fail" -eq 0 ] || fail "$equiv_fail multi-TU unit(s) merged differently from the seed closure"

echo "[wholetree] PASS — seed compiles 100%; .ad host compiler accepts" \
     "$ad_ok units ($ad_ok_multi multi-TU via CAP#2 import resolution), all" \
     "multi-TU merges proven equivalent to the seed closure. The one" \
     "remaining reject (hambrowse) is an ELF-emitter CAP overflow, not an" \
     "unsupported construct (see docs/subsystems/adder-compiler.md)."
exit 0
