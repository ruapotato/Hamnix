#!/usr/bin/env bash
# scripts/ssa_census_lever_byte_identity.sh — prove that an analysis-lane census
# lever cannot change what the real --opt lane EMITS.
#
# WHY.  The ssa_census_* levers (ssa_census_mem_native / _mem_model / the six
# ssa_census_keep_*) exist so a subset target can be sized by counterfactual
# instead of by bail share.  They are only safe to carry in the compiler if the
# emit lane provably cannot observe them.  The argument is by construction:
#
#   * every lever defaults to a value that reproduces what ssa_emit_program arms,
#   * ssa_emit_program assigns ssa_mem_model / ssa_mem_native itself and never
#     reads a census lever,
#   * only ssa_run_program (the --dump-ssa ANALYSIS lane) writes them,
#   * and each ssa_mm_*() predicate reduces to a bare `ssa_mem_model` read when
#     its keep lever is 0.
#
# An argument by construction is exactly the kind that a later refactor breaks
# silently, so MEASURE it: compile a large corpus of REAL tree sources through
# `--opt` with two compilers -- one built from this revision, one built from a
# BASE revision -- and compare the md5 of every emitted CODEHEX blob.  Different
# compilers, byte-identical output.
#
# Usage:
#   bash scripts/ssa_census_lever_byte_identity.sh <base-git-rev> [n_files]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BASE_REV="${1:?usage: $0 <base-git-rev> [n_files]}"
NFILES="${2:-60}"
COMPILER_SRC="adder/compiler/ssa.ad tests/fuzz/ad_codegen_dump_driver.ad"

mkdir -p build/ssa_byte_identity
OUT=build/ssa_byte_identity

if ! git diff --quiet -- $COMPILER_SRC; then
  echo "FAIL: $COMPILER_SRC has uncommitted changes; commit first so the"
  echo "      checkout/restore below cannot lose work."
  exit 1
fi

# The corpus: the largest real .ad sources in the tree.  Large files carry the
# most SSA-accepted functions, so they exercise ssa_emit_program hardest.
mapfile -t CORPUS < <(find adder kernel lib mm fs net drivers sys init \
    -name '*.ad' -type f 2>/dev/null \
  | xargs -r ls -S 2>/dev/null | head -n "$NFILES")
echo "corpus: ${#CORPUS[@]} files"

emit_all() {   # $1 = tag
  local tag="$1" f
  python3 -c "import sys;sys.path.insert(0,'tests/fuzz');import ad_codegen_host as h;h.build_driver()" \
    >"$OUT/build_$tag.log" 2>&1 || { echo "FAIL: driver build ($tag)"; exit 1; }
  local drv="build/fuzz_ad_codegen/ad_codegen_dump"
  : > "$OUT/$tag.md5"
  for f in "${CORPUS[@]}"; do
    # --opt routes accepted functions through ssa_emit_program; CODEHEX is the
    # emitted machine code.  A lever that leaked into the emit lane would move
    # at least one of these.
    "$drv" --opt "$f" 2>/dev/null \
      | sed -n '/^CODEHEX/,$p' \
      | md5sum | sed "s|-|$f|" >> "$OUT/$tag.md5"
  done
}

echo "== emitting with THIS revision ($(git rev-parse --short HEAD)) =="
emit_all head

echo "== emitting with BASE revision ($(git rev-parse --short "$BASE_REV")) =="
git checkout "$BASE_REV" -- $COMPILER_SRC || exit 1
trap 'git checkout HEAD -- '"$COMPILER_SRC"'' EXIT
emit_all base
git checkout HEAD -- $COMPILER_SRC
trap - EXIT

echo
if diff -q "$OUT/head.md5" "$OUT/base.md5" >/dev/null; then
  echo "PASS  byte-identical --opt output across ${#CORPUS[@]} real sources"
  echo "      combined md5: $(md5sum < "$OUT/head.md5" | cut -d' ' -f1)"
  exit 0
fi
echo "FAIL  --opt output DIFFERS -- a census lever reached the emit lane:"
diff "$OUT/base.md5" "$OUT/head.md5" | head -40
exit 1
