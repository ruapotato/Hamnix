#!/usr/bin/env bash
# scripts/test_opt_idxstore_saveset.sh — focused, host-only regression gate for
# the --opt INDEXED-STORE scratch-reservation UNDER-COUNT miscompile that broke
# the optimized kernel (page-allocator free-list corruption / #DF at boot).
#
# ROOT CAUSE (codegen.ad): try_sel_assign_index PARKS the routed indexed store's
# RHS value in a freshly ACQUIRED callee-saved scratch register (`xr`) across the
# legacy address computation, then computes the RHS INTO xr (acquiring up to
# ir_scratch_max_live(rhs) MORE scratch). Its true simultaneous scratch demand is
# 1 + max_live(rhs). The reservation prescan (ir_scratch_prescan_*) formerly
# counted only max_live(rhs), so the parked `xr` (e.g. %r14) was NOT added to the
# prologue save-set and got clobbered — corrupting the caller's live value.
#
# WHAT IT PROVES (no QEMU): host_ac compiles the _pa_set_next shape --opt for
# x86_64-bare-metal and EVERY callee-saved register (%rbx,%r12..%r15) written in
# the function body is PUSHed in the prologue. A regression re-introduces an
# unsaved scratch write and fails loudly.
#
# HOST-ONLY: python3 + as/objdump (x86_64). NO QEMU.
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
opt1_require_lane "test_opt_idxstore_saveset"

fail() { echo "[idxstore-saveset] FAIL: $*" >&2; exit 1; }
command -v objdump >/dev/null 2>&1 || { echo "[idxstore-saveset] SKIP: no objdump"; exit 0; }

# shellcheck source=_adder_cc.sh
source scripts/_adder_cc.sh
ADDER_CC=adder PROJ_ROOT="$PROJ_ROOT" adder_cc_bootstrap >/dev/null 2>&1 \
    || fail "host_ac.elf bootstrap failed"
HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || fail "no host_ac.elf"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SRC="tests/opt/regress_idxstore_saveset.ad"
[ -f "$SRC" ] || fail "missing fixture $SRC"

OBJ="$TMP/repro.o"
"$HOST_AC" --opt --target=x86_64-bare-metal "$SRC" "$OBJ" >/dev/null 2>&1 \
    || fail "host_ac --opt bare-metal compile failed"
[ -s "$OBJ" ] || fail "no object emitted"

# Disassemble the target function `set_next` and split prologue (up to the frame
# setup `mov %rsp,%rbp`) from the body.
objdump -d "$OBJ" 2>/dev/null > "$TMP/dis.txt"
awk '/<set_next>:/{f=1} f{print} f&&/ret[ ]*$/{exit}' "$TMP/dis.txt" > "$TMP/fn.txt"
[ -s "$TMP/fn.txt" ] || fail "set_next not found in disassembly"

# Prologue = lines before the first `mov %rsp,%rbp`. Collect callee-saved regs
# PUSHed there.
PUSHED="$(awk '/mov +%rsp,%rbp/{exit} /push +%r(bx|1[2-5])/{print}' "$TMP/fn.txt" \
    | grep -oE 'r(bx|1[2-5])' | sort -u)"

# Body = everything AFTER the frame setup up to the epilogue. Collect callee-saved
# regs that are WRITTEN (a mov/xor/add/or/etc. with the reg as the destination —
# i.e. it appears as the LAST comma-separated operand, AT&T dst-last).
WRITTEN="$(awk 'p&&/leave|pop +%r(bp|bx|1[2-5])/{exit} p{print} /mov +%rsp,%rbp/{p=1}' "$TMP/fn.txt" \
    | grep -oE '%r(bx|1[2-5])$' | grep -oE 'r(bx|1[2-5])' | sort -u)"

echo "[idxstore-saveset] pushed:  ${PUSHED:-<none>}"
echo "[idxstore-saveset] written: ${WRITTEN:-<none>}"

# Every written callee-saved reg MUST be pushed.
rc=0
for r in $WRITTEN; do
    if ! echo "$PUSHED" | grep -qw "$r"; then
        echo "[idxstore-saveset] UNSAVED callee-saved write: %$r (used in body, not pushed in prologue)" >&2
        rc=1
    fi
done
[ "$rc" -eq 0 ] || fail "callee-saved register clobbered without save/restore (the miscompile)"

# Sanity: the routed indexed store must actually use >=2 callee-saved scratch regs
# here (the park + the operand), else the fixture no longer exercises the bug.
NW="$(echo "$WRITTEN" | grep -c 'r')"
[ "${NW:-0}" -ge 2 ] || fail "fixture no longer forces >=2 callee-saved scratch (bug not exercised)"

echo "[idxstore-saveset] PASS: every callee-saved scratch register is saved/restored."
