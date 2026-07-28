#!/usr/bin/env bash
# scripts/test_gate_softgreen.sh — QEMU-FREE meta-gate against the FALSE-GREEN
# class: a gate that exits 0 having asserted NOTHING.
#
# WHY THIS GATE EXISTS
# ====================
# scripts/test_gate_registration.sh closes the "hole shaped like coverage"
# where a gate exists but nothing runs it. This closes the strictly worse one:
# the gate IS registered, CI DOES run it, it reports GREEN — and it never
# observed its assertion.
#
# The shape found on 2026-07-28, and proven by construction (stub
# scripts/build_installer_img.sh to `exit 1`, run the gate, read $?):
#
#   $ bash scripts/test_de_visual_gate.sh
#   [visual_gate] ERROR: build_installer_img.sh failed
#   $ echo $?
#   0
#
# Every one of these printed a failed build and exited 0:
#   test_de_visual_gate           test_de_office_suite
#   test_de_desktop_icon_source   test_de_resolution_edge_to_edge
#   test_de_rl5_deterministic     test_de_stress_soak
#   test_de_term_child_reap       test_de_wallpaper_themes
#   test_de_wallpaper_fullscreen  test_de_app_churn
#   test_hambrowse_realpage_ondevice  test_middle_paste_ondevice
#   test_webkit                   test_de_panel_config (printed "RESULT: PASS")
#
# The root cause was one line of copied documentation. ensure_installer_img
# returns non-zero for two unrelated situations — "skipped because the CALLER
# asked (HAMNIX_SKIP_BUILD=1)" and "the build RAN AND FAILED" — and the
# published idiom was `|| exit 0`, which reports PASS for both. ~20 gates
# copied it. scripts/_installer_img.sh now separates them (1 = by request,
# 2 = unproducible) and offers installer_img_or_verdict, which exits 0 only
# for the honest case and 125 (INCONCLUSIVE) otherwise.
#
# THE RULE
# ========
# An `exit 0` may not be guarded by "the artifact I was about to boot could
# not be produced". There are three legitimate outcomes and they are NOT
# interchangeable (scripts/_verdict.sh):
#
#   PASS 0          the assertion was OBSERVED to hold
#   FAIL 1          the assertion was OBSERVED to be violated
#   INCONCLUSIVE 125  the run never got far enough to observe it
#
# A skip the CALLER asked for (HAMNIX_SKIP_BUILD=1 / SKIP_BUILD=1, the way the
# battery runs the slow image gates) is a genuine exit 0 and is exempt — the
# detector recognises the switch by name. Anything else is either fixed or
# opted out per site, in the source, with a reason the next reader can audit:
#
#     # soft-green-ok: <why exiting 0 here is honest>
#
# PARTS
#   1. `ensure_installer_img ... || exit 0` — BANNED outright, no baseline.
#   2. exit 0 on an unproducible-artifact path — new ones FAIL; the
#      pre-existing dark ones are frozen in scripts/ci_softgreen_baseline.txt.
#   3. That baseline is a RATCHET: counts may only shrink, and PART 3 diffs it
#      against HEAD so a new finding cannot be laundered by appending a line
#      (the exact hole that test_gate_registration.sh PART 3 had to close).
#   4. No manifest line may DISCARD its gate's exit status (`|| true`, `|| :`).
#      ci_run_battery_shard.sh runs each line through `bash -c`, so a trailing
#      `|| true` makes the gate unable to fail — a false green one level up.
#
# Deliberately NOT solved here: whether a registered gate PASSES, and whether
# a gate is vacuous for a *capability* reason (no /dev/kvm on a GitHub runner).
# The latter is real and is reported in the 2026-07-28 audit, but it is a
# coverage-siting question, not a lying-verdict question.
#
# Exit 0 = PASS, 1 = FAIL. No QEMU, ~1 s.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[gate_softgreen]"
BASELINE="scripts/ci_softgreen_baseline.txt"
MANIFEST="scripts/ci_battery_manifest.txt"
SCANNER="scripts/_softgreen_scan.py"

FAILED=0

for f in "$SCANNER" "$BASELINE" "$MANIFEST"; do
    [ -f "$f" ] || { echo "$TAG FAIL: missing $f" >&2; exit 1; }
done

SITES=$(python3 "$SCANNER" "$PROJ_ROOT") || {
    echo "$TAG FAIL: $SCANNER errored" >&2; exit 1; }

N_IDIOM=$(printf '%s\n' "$SITES" | grep -c '^IDIOM' || true)
N_ARTIFACT=$(printf '%s\n' "$SITES" | grep -c '^ARTIFACT' || true)
N_OPTOUT=$(printf '%s\n' "$SITES" | grep -c '^OPTOUT' || true)
echo "$TAG scanned $(ls scripts/test_*.sh | wc -l) gate scripts:" \
     "$N_IDIOM banned-idiom site(s), $N_ARTIFACT unproducible-artifact site(s)," \
     "$N_OPTOUT declared soft-green-ok site(s)"
# The opt-out is deliberately un-ratcheted (a new legitimate one must be
# possible) — so it is LISTED instead. An escape hatch nobody can see is an
# escape hatch nobody audits; these lines are the review surface.
printf '%s\n' "$SITES" | awk -F'\t' -v t="$TAG" \
    '$1=="OPTOUT" {printf "%s   soft-green-ok %s:%s — %s\n", t, $2, $3, $4}'

# --- PART 1: the banned idiom, zero tolerance -------------------------------
echo "$TAG PART 1: \`ensure_installer_img ... || exit 0\` is BANNED"
IDIOM=$(printf '%s\n' "$SITES" | grep '^IDIOM' || true)
if [ -n "$IDIOM" ]; then
    echo "$TAG FAIL: $N_IDIOM site(s) treat a FAILED installer build as PASS:" >&2
    printf '%s\n' "$IDIOM" | awk -F'\t' -v t="$TAG" \
        '{printf "%s   %s:%s  %s\n", t, $2, $3, $4}' >&2
    echo "$TAG   ensure_installer_img returns 1 for a by-REQUEST skip and 2" >&2
    echo "$TAG   for an UNPRODUCIBLE image. \`|| exit 0\` reports PASS for a" >&2
    echo "$TAG   tree that does not build. Use instead:" >&2
    echo "$TAG       installer_img_or_verdict \"\$INSTALLER_IMG\" \"[my_gate]\"" >&2
    FAILED=1
else
    echo "$TAG   ok  no gate conflates a failed build with a requested skip"
fi

# --- PART 2: unproducible-artifact soft-greens, against the baseline --------
echo "$TAG PART 2: exit 0 after an artifact could not be produced"
CUR=$(printf '%s\n' "$SITES" | awk -F'\t' '$1=="ARTIFACT" {print $2}' \
        | sort | uniq -c | awk '{printf "%s %s\n", $2, $1}' | sort)
BASE=$(sed 's/#.*//' "$BASELINE" | awk 'NF==2 {print $1, $2}' | sort)

NEW=$(comm -23 <(printf '%s\n' "$CUR" | awk '{print $1}' | sort -u) \
               <(printf '%s\n' "$BASE" | awk '{print $1}' | sort -u))
if [ -n "$NEW" ]; then
    echo "$TAG FAIL: gate(s) newly exiting 0 on an unproducible artifact:" >&2
    printf '%s\n' "$NEW" | sed "s|^|$TAG   |" >&2
    echo "$TAG   Nothing was booted, so nothing was asserted. Report" >&2
    echo "$TAG   INCONCLUSIVE (exit 125, scripts/_verdict.sh) instead, or" >&2
    echo "$TAG   annotate the site \`# soft-green-ok: <reason>\` if the exit 0" >&2
    echo "$TAG   really is honest. Do NOT add a line to $BASELINE." >&2
    FAILED=1
else
    echo "$TAG   ok  no gate outside the frozen baseline"
fi

GREW=""
while read -r path n; do
    [ -n "$path" ] || continue
    b=$(printf '%s\n' "$BASE" | awk -v p="$path" '$1==p {print $2}')
    [ -n "$b" ] || continue           # already reported as NEW above
    [ "$n" -le "$b" ] || GREW="$GREW$path: $b -> $n"$'\n'
done < <(printf '%s\n' "$CUR")
if [ -n "$GREW" ]; then
    echo "$TAG FAIL: baselined gate(s) GREW new soft-green sites:" >&2
    printf '%s' "$GREW" | sed "s|^|$TAG   |" >&2
    echo "$TAG   The baseline is a ceiling, not a licence." >&2
    FAILED=1
else
    echo "$TAG   ok  no baselined gate grew a new site"
fi

# Entries that no longer need to be there — the ratchet must actually turn.
STALE=""
while read -r path n; do
    [ -n "$path" ] || continue
    if [ ! -f "$path" ]; then
        STALE="$STALE$path (script no longer exists)"$'\n'
        continue
    fi
    c=$(printf '%s\n' "$CUR" | awk -v p="$path" '$1==p {print $2}')
    [ -n "$c" ] || STALE="$STALE$path (now clean — remove the line)"$'\n'
done < <(printf '%s\n' "$BASE")
if [ -n "$STALE" ]; then
    echo "$TAG FAIL: baseline entries that are no longer needed:" >&2
    printf '%s' "$STALE" | sed "s|^|$TAG   |" >&2
    echo "$TAG   Delete them from $BASELINE. A baseline that keeps entries" >&2
    echo "$TAG   it no longer needs stops being a ratchet and becomes a" >&2
    echo "$TAG   rubber stamp." >&2
    FAILED=1
else
    echo "$TAG   ok  every baseline entry is still needed"
fi

# --- PART 3: the baseline is APPEND-FORBIDDEN (vs HEAD) ---------------------
echo "$TAG PART 3: the baseline may only SHRINK (vs HEAD)"
# Without this, PART 2 is trivially launderable: a new false green goes green
# by appending one line here. That is the same move, one file over. This is
# the hole test_gate_registration.sh PART 3 had to close on 2026-07-28, found
# only because somebody actually tried it.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "$TAG   note: not a git checkout — append check skipped"
elif ! git cat-file -e "HEAD:$BASELINE" 2>/dev/null; then
    echo "$TAG   note: $BASELINE not in HEAD yet — append check skipped"
else
    HEADBASE=$(git show "HEAD:$BASELINE" | sed 's/#.*//' | awk 'NF==2 {print $1, $2}' | sort)
    ADDED=$(comm -13 <(printf '%s\n' "$HEADBASE" | awk '{print $1}' | sort -u) \
                     <(printf '%s\n' "$BASE"     | awk '{print $1}' | sort -u))
    RAISED=""
    while read -r path n; do
        [ -n "$path" ] || continue
        h=$(printf '%s\n' "$HEADBASE" | awk -v p="$path" '$1==p {print $2}')
        [ -n "$h" ] || continue
        [ "$n" -le "$h" ] || RAISED="$RAISED$path: $h -> $n"$'\n'
    done < <(printf '%s\n' "$BASE")
    if [ -n "$ADDED" ] || [ -n "$RAISED" ]; then
        echo "$TAG FAIL: $BASELINE was widened since HEAD:" >&2
        [ -n "$ADDED" ] && printf '%s\n' "$ADDED" | sed "s|^|$TAG   + |" >&2
        [ -n "$RAISED" ] && printf '%s' "$RAISED" | sed "s|^|$TAG   ^ |" >&2
        echo "$TAG   This file is a FROZEN inventory of the soft-greens that" >&2
        echo "$TAG   already existed. New ones get fixed, or get a" >&2
        echo "$TAG   \`# soft-green-ok: <reason>\` at the site. Not a line here." >&2
        FAILED=1
    else
        echo "$TAG   ok  no widening"
    fi
fi

# --- PART 4: no manifest line may discard its gate's exit status ------------
echo "$TAG PART 4: no manifest line discards its gate's verdict"
# ci_run_battery_shard.sh runs each line via `bash -c "$cmd"` and reads $?.
# A trailing `|| true` makes the gate structurally incapable of failing.
LAUNDER=$(grep -n -E '(\|\|[[:space:]]*(true|:)|;[[:space:]]*true)[[:space:]]*$' \
            "$MANIFEST" | grep -v -E '^[0-9]+:[[:space:]]*#' || true)
if [ -n "$LAUNDER" ]; then
    echo "$TAG FAIL: manifest line(s) whose gate cannot fail:" >&2
    printf '%s\n' "$LAUNDER" | sed "s|^|$TAG   $MANIFEST:|" >&2
    echo "$TAG   \`|| true\` discards the verdict: the gate runs, reports FAIL," >&2
    echo "$TAG   and the shard records PASS. If the gate is opt-in, gate it on" >&2
    echo "$TAG   the env var alone and let its real exit status through." >&2
    FAILED=1
else
    echo "$TAG   ok  every manifest line lets its gate's exit status through"
fi

# --- PART 5: the capability-vacuous ceiling ---------------------------------
# Every CI runner in .github/workflows is `runs-on: ubuntu-latest`, which has
# NO /dev/kvm — scripts/ci_run_gate.sh's own header says so. A manifest gate
# that opens with `[ -e /dev/kvm ] || exit 0` therefore exits 0 on EVERY CI
# run, forever, having observed nothing. That is not a lying verdict (the gate
# is honest about skipping and it does assert when run on a KVM host, which is
# how the orchestrator runs it), so it is not a FAIL here — but the population
# must not grow unnoticed while everyone reads the battery as coverage.
#
# The ceiling is a RATCHET. Lower it by moving a gate to a KVM-capable runner,
# or by giving it a structural half that asserts before the capability check.
# Do NOT raise it.
CAP_CEILING=21
echo "$TAG PART 5: manifest gates that exit 0 at a capability check (ceiling $CAP_CEILING)"
CAPVAC=$(python3 - "$MANIFEST" <<'PY'
import re, sys
man = open(sys.argv[1], errors='replace').read()
live = '\n'.join(l for l in man.split('\n') if not l.lstrip().startswith('#'))
out = []
for g in sorted(set(re.findall(r'scripts/test_[A-Za-z0-9_.-]+\.sh', live))):
    try:
        src = open(g, errors='replace').read().split('\n')
    except OSError:
        continue
    for i, l in enumerate(src):
        if l.lstrip().startswith('#'):
            continue
        if '/dev/kvm' in l and re.search(r'exit\s+0', '\n'.join(src[i:i + 3])):
            out.append(g)
            break
print('\n'.join(out))
PY
)
N_CAP=$(printf '%s\n' "$CAPVAC" | grep -c . || true)
if [ "$N_CAP" -gt "$CAP_CEILING" ]; then
    echo "$TAG FAIL: $N_CAP registered gate(s) exit 0 when /dev/kvm is absent," >&2
    echo "$TAG   which is EVERY ubuntu-latest CI run. Ceiling is $CAP_CEILING:" >&2
    printf '%s\n' "$CAPVAC" | sed "s|^|$TAG   |" >&2
    echo "$TAG   These manifest lines report green without observing anything." >&2
    FAILED=1
else
    echo "$TAG   ok  $N_CAP of $CAP_CEILING (these assert only on a KVM host)"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "$TAG FAIL"
    exit 1
fi
echo "$TAG PASS"
exit 0
