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

# --- PART 5: RETIRED — owned by scripts/test_gate_kvmdark.sh ----------------
# PART 5 used to count manifest gates that open with `[ -e /dev/kvm ] || exit 0`
# and fail if the total exceeded an integer ceiling (21). It is gone, and
# nothing replaces it here, because scripts/test_gate_kvmdark.sh does the same
# job strictly better and two ratchets over one population is a maintenance
# tax that gets paid in stale numbers.
#
# Why the integer ceiling was the weaker instrument:
#
#   * It ratcheted a COUNT, not a SET. Deleting one vacuous gate bought a
#     licence to add a different one — the population churns and the number
#     does not move. kvmdark freezes the NAMES
#     (scripts/ci_kvmdark_baseline.txt) and its PART 3 forbids appending to
#     that file vs HEAD, so a new finding cannot be laundered in.
#   * The ceiling INCLUDED ITS OWN MATCH. This file's PART 5 source contained
#     the literal '/dev/kvm' within three lines of an 'exit 0', so the scanner
#     counted test_gate_softgreen.sh itself — 1 of the 21 was the ruler.
#   * It had no escape hatch, so a gate for which a silent skip really is
#     honest had nowhere to say so. kvmdark takes `# kvm-dark-ok: <why>` at
#     the site.
#   * It printed only a number. kvmdark prints the CENSUS — every uncovered
#     gate by name, plus a ::warning:: annotation — on every run, so a green
#     GitHub run states plainly what it did not cover. That is the part that
#     actually changes behaviour.
#
# Both gates are registered in scripts/ci_battery_manifest.txt and both run in
# ~1 s without QEMU, so nothing is lost by deleting the duplicate.
echo "$TAG PART 5: capability-vacuous population — see scripts/test_gate_kvmdark.sh"
echo "$TAG   (retired here 2026-07-28: kvmdark ratchets the NAMED SET and"
echo "$TAG    prints a per-gate census; this file's integer ceiling was"
echo "$TAG    strictly weaker and counted its own source as one of the 21.)"

if [ "$FAILED" -ne 0 ]; then
    echo "$TAG FAIL"
    exit 1
fi
echo "$TAG PASS"
exit 0
