#!/usr/bin/env bash
# scripts/test_adder_must_use.sh — UNCHECKED-RESULT and OWNERSHIP-ALIAS lints
# (adder/compiler/sema.py classes `must-use` and `own-alias`).
# HOST-ONLY, NO QEMU.
#
# WHY THIS EXISTS. A day spent scoring real defects in this tree found that
# the dominant class is not aliasing and not type confusion — it is SILENT
# FAILURE: an operation fails, reports it in its return value, and nobody is
# required to look.
#
#   * `_argv_push_cstr` dropped argument 64+ with no error and no status, so
#     `rm *` deleted 62 of 230 files and EXITED 0;
#   * `_alias_set` dropped the 65th alias and `alias x=y` still said "ok";
#   * `exec_def` silently ignored the 33rd `def`;
#   * `ensure_installer_img` returned a status ~20 gates never checked, so 17
#     gates reported PASS after a FAILED build.
#
# Every one is "an operation failed and nobody was required to look."
#
# `# must_use` marks a function whose result MUST be inspected; discarding it
# at a bare statement is a diagnostic. `# owns_return` marks a function whose
# returned pointer the caller OWNS; storing it in two escaping places is a
# diagnostic. Both are LINTS with cheap opt-outs — this gate pins the
# opt-outs as hard as it pins the reports, because a lint that cries wolf
# gets switched off and then protects nothing.
#
# Verifies:
#   (1) must-use FIRES on a bare-statement call, with location, caret, the
#       LIMIT that was hit, the declaration site, and what to do instead.
#   (2) must-use is SILENT on all five inspecting shapes (condition, local
#       bind, global store, `return f()`, `# ignore-result`) — 1 report from
#       a 6-call fixture, not 6.
#   (3) must-use never fires on unannotated code: the tree has ~11.3k bare
#       discarded-result statements and this class must see none of them.
#   (4) own-alias FIRES on one allocation with two owners, naming the
#       allocator, the first owner and the second.
#   (5) own-alias is SILENT on transfer, local copies, a realloc loop,
#       `unsafe:`, `# alias-ok`, and unannotated allocators — 1 report from a
#       9-function fixture.
#   (6) Both are WARNINGS: they never block a build by default, and
#       ADDER_SEMA=0 / the per-class knob turn them off.
#   (7) CODEGEN-INERT: assembly is byte-identical with the lints on and off.
#
# Usage:  bash scripts/test_adder_must_use.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[must-use] FAIL $*"; exit 1; }
ok()   { echo "[must-use] ok   $*"; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"

FIX="tests/sema"
WORK="build/must_use_check"
rm -rf "$WORK"; mkdir -p "$WORK"

# The mutation tests below EDIT tracked source files in place. If this script
# is killed between the edit and the restore (a CI timeout, a SIGTERM from the
# orchestrator) the probe is left behind and the next run of any gate compiles
# a tree nobody wrote. Register the restore up front so it happens on the way
# out whatever the exit path — this is not hypothetical, it happened.
MUTATED=()
restore_mutations() {
    local i
    for ((i = 0; i < ${#MUTATED[@]}; i += 2)); do
        [ -f "${MUTATED[i+1]}" ] && cp -f "${MUTATED[i+1]}" "${MUTATED[i]}"
    done
}
trap restore_mutations EXIT INT TERM

compile() {  # compile <src> <out> ; stderr -> $WORK/cerr
    python3 -m compiler.adder compile "$1" --target=x86_64-linux \
        -o "$2" >/dev/null 2>"$WORK/cerr"
}

# ---- (1)(2) must-use: exactly one report from six calls -------------------
compile "$FIX/sema_must_use.ad" "$WORK/mu.elf" \
    || { cat "$WORK/cerr"; fail "must-use is a WARNING; it must not block"; }

n=$(grep -c '\[must-use\]' "$WORK/cerr")
[ "$n" -eq 1 ] || { cat "$WORK/cerr"
    fail "expected exactly 1 [must-use] report from the 6-call fixture, got $n"; }

grep -qE "sema_must_use\.ad:[0-9]+:[0-9]+: warning: result of 'argv_push' is discarded \[must-use\]" \
    "$WORK/cerr" || { cat "$WORK/cerr"; fail "no located must-use diagnostic"; }
grep -qE '^ +\| *\^' "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "must-use diagnostic has no caret line"; }
# The report must be SELF-DESCRIBING: name the limit, the declaration, the fix.
grep -q "note: 'argv_push' returns int32: 1 = pushed, 0 = argv is FULL at ARGV_MAX" \
    "$WORK/cerr" || { cat "$WORK/cerr"; fail "must-use note does not name the limit"; }
grep -q 'note: declared `# must_use` at .*sema_must_use.ad:' "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "must-use note does not cite the declaration"; }
grep -q 'note: bind the result and branch on it, or write `# ignore-result`' \
    "$WORK/cerr" || { cat "$WORK/cerr"; fail "must-use note does not say what to do"; }
# ...and it must point at `bad`, not at any of the five inspecting shapes.
line=$(grep -oE "sema_must_use\.ad:[0-9]+" "$WORK/cerr" | head -1 | cut -d: -f2)
sed -n "${line}p" "$FIX/sema_must_use.ad" | grep -q '^    argv_push(s)$' \
    || { cat "$WORK/cerr"; fail "must-use flagged line $line, not the bare call"; }
ok "must-use: 1 report from 6 calls, at the bare-statement one, self-describing"

# ---- (3) never fires on unannotated code ---------------------------------
cat > "$WORK/plain.ad" <<'ADEOF'
n: uint64 = 0


def push(x: uint64) -> int32:
    n = n + x
    return 1


def main() -> int32:
    push(1)
    push(2)
    return 0
ADEOF
compile "$WORK/plain.ad" "$WORK/plain.elf" \
    || { cat "$WORK/cerr"; fail "unannotated program rejected"; }
grep -q '\[must-use\]' "$WORK/cerr" && { cat "$WORK/cerr"
    fail "must-use fired on UNANNOTATED code — the tree has ~11.3k such sites"; }
ok "must-use is silent on unannotated code (opt-in by annotation)"

# ---- (4)(5) own-alias: exactly one report from nine functions -------------
compile "$FIX/sema_own_alias.ad" "$WORK/oa.elf" \
    || { cat "$WORK/cerr"; fail "own-alias is a WARNING; it must not block"; }
n=$(grep -c '\[own-alias\]' "$WORK/cerr")
[ "$n" -eq 1 ] || { cat "$WORK/cerr"
    fail "expected exactly 1 [own-alias] report from the 9-function fixture, got $n"; }
grep -q "warning: owned pointer 'p' is stored in a second place ('slot_b')" \
    "$WORK/cerr" || { cat "$WORK/cerr"; fail "own-alias report names the wrong store"; }
grep -q "note: 'p' was allocated by 'alloc' at .*, which is declared \`# owns_return\`" \
    "$WORK/cerr" || { cat "$WORK/cerr"; fail "own-alias note does not cite the allocator"; }
grep -q "note: the first owner is 'slot_a', stored at " "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "own-alias note does not cite the FIRST owner"; }
grep -q "note: if the aliasing is deliberate" "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "own-alias note does not offer the escape hatch"; }
line=$(grep -oE "sema_own_alias\.ad:[0-9]+" "$WORK/cerr" | head -1 | cut -d: -f2)
sed -n "${line}p" "$FIX/sema_own_alias.ad" | grep -q '^    slot_b = p$' \
    || { cat "$WORK/cerr"; fail "own-alias flagged line $line, not the second store"; }
ok "own-alias: 1 report from 9 functions, at the second store, self-describing"

# ---- (6) the escape hatches ----------------------------------------------
ADDER_SEMA_MUST_USE=off python3 -m compiler.adder compile \
    "$FIX/sema_must_use.ad" --target=x86_64-linux -o "$WORK/mu_off.elf" \
    >/dev/null 2>"$WORK/cerr" || { cat "$WORK/cerr"; fail "per-class knob broke the build"; }
grep -q '\[must-use\]' "$WORK/cerr" \
    && { cat "$WORK/cerr"; fail "ADDER_SEMA_MUST_USE=off did not silence the class"; }
ADDER_SEMA=0 python3 -m compiler.adder compile "$FIX/sema_own_alias.ad" \
    --target=x86_64-linux -o "$WORK/oa_off.elf" >/dev/null 2>"$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "ADDER_SEMA=0 must bypass the checker"; }
grep -q '\[own-alias\]' "$WORK/cerr" \
    && { cat "$WORK/cerr"; fail "ADDER_SEMA=0 did not silence the class"; }
ok "ADDER_SEMA_MUST_USE=off and ADDER_SEMA=0 both silence the lints"

# ---- (6b) STRICT promotes them to errors ---------------------------------
ADDER_SEMA_MUST_USE=error python3 -m compiler.adder compile \
    "$FIX/sema_must_use.ad" --target=x86_64-linux -o "$WORK/mu_err.elf" \
    >/dev/null 2>"$WORK/cerr" \
    && { cat "$WORK/cerr"; fail "ADDER_SEMA_MUST_USE=error must reject"; }
grep -q 'error:.*\[must-use\]' "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "no error-severity must-use diagnostic"; }
# The summary must name the class AND its per-class knob, not just "set
# ADDER_SEMA=0" (which is the worst of the available remedies).
grep -q 'demote with ADDER_SEMA_MUST_USE=warning' "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "error summary does not name the per-class knob"; }
ok "the class can be promoted to error; the summary names its own knob"

# ---- (7) codegen-inert ----------------------------------------------------
python3 -m compiler.adder compile "$FIX/sema_must_use.ad" \
    --target=x86_64-linux --emit-asm -o "$WORK/on.elf" >/dev/null 2>&1
mv -f "$FIX/sema_must_use.s" "$WORK/on_keep.s" 2>/dev/null
ADDER_SEMA=0 python3 -m compiler.adder compile "$FIX/sema_must_use.ad" \
    --target=x86_64-linux --emit-asm -o "$WORK/off.elf" >/dev/null 2>&1
mv -f "$FIX/sema_must_use.s" "$WORK/off_keep.s" 2>/dev/null
[ -s "$WORK/on_keep.s" ] || fail "no assembly emitted with the lints on"
cmp -s "$WORK/on_keep.s" "$WORK/off_keep.s" \
    || fail "the lints perturbed codegen (on.s != off.s)"
ok "codegen byte-identical with the lints on and off"

# ---- (8) the annotated call sites in the tree are real --------------------
# The markers are only worth anything if they are attached to functions that
# still exist with the documented shape. Re-check a representative sample by
# NAME so a rename cannot silently orphan an annotation.
for spec in "user/hamsh.ad:_argv_push_cstr" \
            "mm/slab.ad:kmalloc" \
            "sys/src/9/port/devwsys.ad:_wsys_keys_push_byte" \
            "net/core/napi.ad:napi_register" \
            "kernel/time/clocksource.ad:clocksource_register"; do
    f="${spec%%:*}"; fn="${spec##*:}"
    ln=$(grep -n "^def ${fn}(" "$f" | head -1 | cut -d: -f1)
    [ -n "$ln" ] || fail "annotated function '$fn' no longer exists in $f"
    prev=$((ln - 1))
    sed -n "${prev}p" "$f" | grep -q '^# \(must_use\|owns_return\):' \
        || fail "$f:$fn lost its marker comment (must be the line above 'def')"
done
ok "annotated functions still exist and still carry their markers"

# ---- (9) the whole-tree ledger is SHRINK-ONLY ----------------------------
# sema_scan's per-entry sweep resolves link units by finding `def main`. The
# KERNEL has none — its entry is `kmain` — so the kernel, every driver and
# all of sys/src/9 are invisible to it. `must-use` does not need a resolved
# link unit (the marker is on the callee's `def`, the violation is a bare
# statement), so a whole-tree scan sees strictly more, and it is what found
# the devwsys_keys_write short-write and the never-polled NAPI queue.
BASE="scripts/sema_must_use_baseline.txt"
python3 scripts/sema_must_use_scan.py --quiet --baseline "$BASE" \
    > "$WORK/ledger" 2>&1 \
    || { cat "$WORK/ledger"; fail "new unchecked-result site(s) vs $BASE"; }
grep -q "ok: no new unchecked-result sites" "$WORK/ledger" \
    || { cat "$WORK/ledger"; fail "baseline check did not run"; }
ok "$(grep -oE '[0-9]+ known' "$WORK/ledger") unchecked-result sites, none new"

# MUTATION TEST: the gate must actually be able to go red. Introduce one new
# unchecked call to an annotated callee and confirm the ledger rejects it.
MUT="lib/hampkgcore.ad"
cp "$MUT" "$WORK/mut.bak"; MUTATED+=("$MUT" "$WORK/mut.bak")
cat >> "$MUT" <<'ADEOF'


def _must_use_mutation_probe() -> int32:
    hampkg_add_pkg(cast[Ptr[uint8]]("x"), 1, cast[Ptr[uint8]]("1"), 1,
                   cast[Ptr[uint8]]("d"), 1, 0)
    return 0
ADEOF
python3 scripts/sema_must_use_scan.py --quiet --baseline "$BASE" \
    > "$WORK/mut" 2>&1; mrc=$?
cp "$WORK/mut.bak" "$MUT"
[ "$mrc" -ne 0 ] || { cat "$WORK/mut"
    fail "MUTATION SURVIVED: a new unchecked-result site did not fail the gate"; }
grep -q "NEW UNCHECKED RESULT: lib/hampkgcore.ad:.*_must_use_mutation_probe() drops the result of hampkg_add_pkg()" \
    "$WORK/mut" || { cat "$WORK/mut"
    fail "mutation was rejected, but not with a site-naming diagnostic"; }
# ...and the restore must be exact, or the next gate inherits a dirty tree.
cmp -s "$WORK/mut.bak" "$MUT" || fail "mutation probe did not restore $MUT"
ok "mutation test: a NEW unchecked-result site fails the gate, by name"

# ---- (10) own-alias is CLEAN whole-tree, and has real coverage ------------
# `sema_scan --mode entry` cannot see a single kmalloc caller (they are all
# kernel code, and the kernel has no `def main`), so "0 own-alias" from that
# sweep would have been a measurement of nothing. This runs the lint over
# every file that mentions an annotated allocator.
#
# Zero reports is the honest result and it is a DISPROOF, not a null: a
# census of the same 121 files finds 154 tracked owning allocations and 35
# escaping stores of them, and none of those 35 is a second store of an
# already-stored pointer. The tree does not have this bug at this
# granularity — which is exactly the pushback that motivated ranking silent
# failure above aliasing in the first place. The lint stays on because its
# cost is provably zero and it will catch the first one that appears.
python3 scripts/sema_must_use_scan.py --own-alias > "$WORK/own" 2>&1; orc=$?
grep -q '^own-alias reports: 0$' "$WORK/own" \
    || { cat "$WORK/own"; fail "own-alias is no longer clean whole-tree"; }
[ "$orc" -eq 0 ] || { cat "$WORK/own"; fail "own-alias scan exit $orc with 0 reports"; }
n_own=$(sed -n 's/^`# owns_return` functions: \([0-9]*\).*/\1/p' "$WORK/own")
[ "${n_own:-0}" -ge 2 ] \
    || { cat "$WORK/own"; fail "expected >=2 annotated allocators, got $n_own"; }
n_cand=$(sed -n 's/^files mentioning one of them: \([0-9]*\)$/\1/p' "$WORK/own")
[ "${n_cand:-0}" -ge 100 ] || { cat "$WORK/own"
    fail "only $n_cand files analysed — the lint lost its coverage"; }
ok "own-alias: 0 reports over $n_cand files calling $n_own annotated allocators"

# MUTATION TEST: prove the whole-tree own-alias scan can go red.
MUT2="mm/slab.ad"
cp "$MUT2" "$WORK/mut2.bak"; MUTATED+=("$MUT2" "$WORK/mut2.bak")
cat >> "$MUT2" <<'ADEOF'


_own_alias_probe_a: uint64 = 0
_own_alias_probe_b: uint64 = 0


def _own_alias_mutation_probe() -> int32:
    p: uint64 = kmalloc(64)
    _own_alias_probe_a = p
    _own_alias_probe_b = p
    return 0
ADEOF
python3 scripts/sema_must_use_scan.py --own-alias > "$WORK/mut2" 2>&1; m2rc=$?
cp "$WORK/mut2.bak" "$MUT2"
[ "$m2rc" -ne 0 ] || { cat "$WORK/mut2"
    fail "MUTATION SURVIVED: a two-owner allocation did not fail the scan"; }
grep -q "owned pointer 'p' is stored in a second place ('_own_alias_probe_b')" \
    "$WORK/mut2" || { cat "$WORK/mut2"
    fail "mutation rejected, but not with the two-owner diagnostic"; }
cmp -s "$WORK/mut2.bak" "$MUT2" || fail "own-alias probe did not restore $MUT2"
ok "mutation test: a two-owner allocation fails the whole-tree own-alias scan"

echo "[must-use] PASS"
