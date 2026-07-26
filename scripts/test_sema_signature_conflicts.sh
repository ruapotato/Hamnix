#!/usr/bin/env bash
# scripts/test_sema_signature_conflicts.sh — ONE SYMBOL, ONE SIGNATURE.
# HOST-ONLY, NO QEMU.
#
# THE BUG THIS GATE EXISTS FOR (2026-07-17, commit ad33523f):
#   `sys_open` had TWO declarations — 1-arg `(path) -> int32` in the device
#   runtime, 3-arg `(path, flags, mode) -> int32` in `linux-runtime.S`. Every
#   `*_host.ad` harness declared the 3-arg extern while the `lib/` modules it
#   imports declared the 1-arg one. `merge_programs` keeps ONE decl per public
#   name and silently drops the rest, so `lib/hamtextbox`'s clipboard read
#   called the 3-arg host thunk with only %rdi set — open(2) got garbage
#   flags/mode — and 3-arg write-opens silently dropped their flags and opened
#   read-only. 14 host harnesses, 36 bad call sites.
#
# WHY IT WASN'T CAUGHT: `scripts/sema_scan.py` merged the WHOLE TREE into one
# program and DROPPED every public name two modules declared incompatibly
# (299 of them) rather than invent false positives. "Same symbol, two
# incompatible signatures" IS the bug, so the scan reported 0 arity errors
# tree-wide while a real per-entry-point sweep found 36 in 14 files.
#
# Verifies:
#   (1) SIGNATURE-CONFLICT DETECTOR, whole tree, vs the checked-in baseline
#       (scripts/sema_conflicts_baseline.txt). Any NEW conflicting public
#       name, or any baselined LANDMINE that has become LIVE (its two
#       spellings now co-occur in a real link unit), fails.
#   (2) TEETH — the exact `sys_open` shape, reconstructed: a synthetic module
#       redeclaring `sys_open` with 3 params alongside `lib/`'s 1-param
#       extern must be reported LIVE and must fail.
#   (3) TEETH — a fresh conflicting name in a throwaway subtree is reported
#       as NEW against an empty baseline.
#   (4) PER-ENTRY-POINT RESOLUTION still finds an arity error that the
#       whole-tree merge hides (the acceptance property of the rework).
#   (5) --full (opt-in, ~3 min): the whole per-entry-point sweep, 570 link
#       units resolved through the real collect_all_imports/merge_programs
#       path, must be free of error-severity diagnostics outside the
#       deliberately-ill-typed fixtures.
#
# Usage:  bash scripts/test_sema_signature_conflicts.sh [--full]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

fail() { echo "[sigconf] FAIL $*"; exit 1; }
ok()   { echo "[sigconf] ok   $*"; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"

SCAN="scripts/sema_scan.py"
BASE="scripts/sema_conflicts_baseline.txt"
WORK="build/sema_sigconf"
JOBS="${SEMA_SCAN_JOBS:-$(nproc 2>/dev/null || echo 4)}"
[ "$JOBS" -gt 12 ] && JOBS=12
rm -rf "$WORK"; mkdir -p "$WORK"

[ -f "$BASE" ] || fail "missing baseline $BASE"

# ---- (1) whole-tree conflict detector vs the baseline ---------------------
python3 "$SCAN" --mode conflicts -j "$JOBS" --baseline "$BASE" \
    > "$WORK/conflicts.txt" 2>"$WORK/conflicts.err"
rc=$?
grep -qE '^conflicting public names: [0-9]+' "$WORK/conflicts.txt" \
    || { tail -20 "$WORK/conflicts.txt" "$WORK/conflicts.err"; \
         fail "detector produced no summary"; }
if [ "$rc" -ne 0 ]; then
    grep -E 'NEW CONFLICT|LANDMINE WENT LIVE|^FAIL' "$WORK/conflicts.txt"
    echo "[sigconf] A public name is declared with two different signatures."
    echo "[sigconf] Fix the declarations so ONE symbol has ONE signature."
    echo "[sigconf] If the divergence is genuinely unlinkable, add the name to"
    echo "[sigconf] $BASE with a note saying why."
    fail "new or newly-live signature conflict"
fi
sed -n '1,6p' "$WORK/conflicts.txt" | sed 's/^/[sigconf]      /'
ok "no new signature conflicts vs $BASE"

# ---- (2) TEETH: the sys_open shape must be caught -------------------------
# A module that redeclares sys_open with 3 params next to lib/'s 1-param
# extern. This is verbatim the ad33523f bug; the detector must call it LIVE.
mkdir -p "$WORK/teeth_sysopen"
cat > "$WORK/teeth_sysopen/harness.ad" <<'ADEOF'
from lib.hamgame_dev import hamgame_dev_probe

extern def sys_open(path: Ptr[uint8], flags: int32, mode: int32) -> int32


def main() -> int32:
    fd: int32 = sys_open("/dev/null", 0, 0)
    return fd
ADEOF
python3 "$SCAN" --mode conflicts -j "$JOBS" \
    "$WORK/teeth_sysopen" lib > "$WORK/teeth1.txt" 2>&1
grep -q "^sys_open " "$WORK/teeth1.txt" \
    || { cat "$WORK/teeth1.txt"; fail "teeth: sys_open conflict NOT reported"; }
awk '/^LIVE —/,/^LANDMINE —/' "$WORK/teeth1.txt" | grep -q "^sys_open " \
    || { cat "$WORK/teeth1.txt"; \
         fail "teeth: sys_open conflict reported but not classified LIVE"; }
grep -q "arity \[1, 3\]" "$WORK/teeth1.txt" \
    || { cat "$WORK/teeth1.txt"; fail "teeth: arity 1-vs-3 not named"; }
ok "teeth: a 3-arg sys_open next to the 1-arg extern is LIVE + arity [1, 3]"

# ---- (3) TEETH: a brand-new conflicting name fails against a baseline -----
mkdir -p "$WORK/teeth_new"
cat > "$WORK/teeth_new/a.ad" <<'ADEOF'
from build.sema_sigconf.teeth_new.b import zz_helper

extern def zz_probe(a: uint64) -> int32


def main() -> int32:
    return zz_probe(1)
ADEOF
cat > "$WORK/teeth_new/b.ad" <<'ADEOF'
extern def zz_probe(a: uint64, b: uint64, c: uint64) -> int32


def zz_helper(x: uint64) -> int32:
    return zz_probe(x, 0, 0)
ADEOF
: > "$WORK/empty_baseline.txt"
python3 "$SCAN" --mode conflicts -j "$JOBS" --baseline "$WORK/empty_baseline.txt" \
    "$WORK/teeth_new" > "$WORK/teeth2.txt" 2>&1
rc=$?
[ "$rc" -ne 0 ] || { cat "$WORK/teeth2.txt"; \
    fail "teeth: a new conflicting name did not fail the baseline check"; }
grep -q "NEW CONFLICT \[LIVE\]: zz_probe" "$WORK/teeth2.txt" \
    || { cat "$WORK/teeth2.txt"; fail "teeth: zz_probe not reported NEW+LIVE"; }
ok "teeth: a newly-introduced conflicting signature fails the gate"

# ---- (4) per-entry resolution finds what the merge hides ------------------
# tests/sema/sema_arity.ad is one link unit with a known too-few-arguments
# call. `--mode merged` is free to drop ambiguous names; `--mode entry` must
# resolve the unit and report it.
python3 "$SCAN" --mode entry -j "$JOBS" tests/sema/sema_arity.ad \
    > "$WORK/entry_smoke.txt" 2>&1
rc=$?
[ "$rc" -ne 0 ] || { cat "$WORK/entry_smoke.txt"; \
    fail "per-entry mode did not fail on a known-bad link unit"; }
grep -q "too few arguments to 'f'" "$WORK/entry_smoke.txt" \
    || { cat "$WORK/entry_smoke.txt"; fail "per-entry mode missed the arity error"; }
grep -q "^arity  *1 " "$WORK/entry_smoke.txt" \
    || { cat "$WORK/entry_smoke.txt"; fail "per-entry mode class table wrong"; }
ok "per-entry resolution reports an arity error in a real link unit"

# ---- (5) the full sweep (opt-in; ~3 min) ----------------------------------
if [ "$FULL" -eq 1 ]; then
    python3 "$SCAN" --mode entry -j "$JOBS" \
        --exclude 'tests/sema/*' --exclude 'tests/app_sugar/err_*.ad' \
        > "$WORK/sweep.txt" 2>"$WORK/sweep.err"
    rc=$?
    grep -q "^link units checked:" "$WORK/sweep.txt" \
        || { tail -20 "$WORK/sweep.txt" "$WORK/sweep.err"; \
             fail "full sweep produced no summary"; }
    if [ "$rc" -ne 0 ]; then
        sed -n '/^ERROR-severity sites/,$p' "$WORK/sweep.txt"
        fail "per-entry-point sweep found error-severity diagnostics"
    fi
    sed -n '1,3p;/^ERROR-severity/p' "$WORK/sweep.txt" | sed 's/^/[sigconf]      /'
    ok "full per-entry-point sweep clean"
fi

echo "[sigconf] PASS"
