#!/usr/bin/env bash
# scripts/test_gate_pipefail_grepq.sh — QEMU-FREE meta-gate against the
# PIPEFAIL+SIGPIPE class: a gate link that reports the WRONG ANSWER when its
# assertion MATCHES.
#
# WHY THIS GATE EXISTS
# ====================
# scripts/test_gate_registration.sh closes "a gate exists but nothing runs
# it". scripts/test_gate_softgreen.sh closes "the gate runs, reports green,
# and never observed its assertion". This closes the third one: the gate
# runs, it DOES observe its assertion, and the plumbing inverts the answer.
#
#   if ! echo "$body" | grep -q 'PAT'; then fail; fi
#
# `grep -q` exits the instant it matches, closing the pipe under the
# still-writing `echo`; `echo` dies of SIGPIPE (141); `set -o pipefail`
# promotes 141 to the pipeline's status; `if !` inverts it. A MATCHING
# assertion reports FAILURE.
#
# This is not theory and it is not rare. Measured on this host 2026-07-31
# (full table in scripts/_pipefail_grepq_scan.py):
#
#   * scripts/test_de_focus_damage_host.sh — the case that started this. ~6%
#     per run; nearly filed as a compositor regression.
#   * scripts/test_de_terminal_namespace.sh — 26/400 runs failed on a clean
#     tree. 0/400 after the fix.
#   * scripts/test_de_scene_calc_edit_features.sh — 16/400. 0/400 after.
#   * scripts/test_de_rio_blit.sh — 14/300 under load. 0/300 after.
#   * scripts/test_de_new_apps.sh — the worst kind. Two ABSENT-assertions
#     over a 43 KB payload, where a match makes the `if` FALSE and the ELSE
#     branch reports PASS. Proven blind by mutation: with the offending
#     `/n/distros` line inserted at the FIRST code line, the gate reported
#     PASS on 7 of 7 runs. That guard could never have fired.
#
# The class is worth its own ratchet because it MANUFACTURES REDS THAT LOOK
# PERFECTLY REPRODUCIBLE while no tree change explains them — 21 of ~23 reds
# triaged in the week to 2026-07-31 were gate rot or gate defect, and at
# least three were this exact construct — and because in the absent-assertion
# sense it does the opposite, silently, forever.
#
# THE RULE
# ========
# Under `set -o pipefail`, do not pipe a multi-line payload into `grep -q`.
# Use a here-string, which is a redirection and not a pipeline:
#
#     if ! grep -q 'PAT' <<<"$body"; then
#
# or materialise the payload and grep the FILE. Both are already the house
# idiom (200+ uses across scripts/). Move the pattern VERBATIM — a retyped
# assertion is how a repair becomes a false green.
#
# A site where the payload really is bounded to a line or two is exempt, at
# the site, with a reason the next reader can audit:
#
#     # pipefail-grepq-ok: <why this payload is one line>
#
# PARTS
#   1. A script NOT in the baseline may not have a site at all.
#   2. A baselined script's count may only SHRINK, and entries that are no
#      longer needed must be deleted (a baseline that keeps stale entries is
#      a rubber stamp, not a ratchet).
#   3. The baseline may only shrink VS HEAD, so a new finding cannot be
#      laundered in by appending a line — the hole
#      test_gate_registration.sh PART 3 had to close on 2026-07-28.
#
# Deliberately NOT solved here: single-line payloads (measured 0/400 under
# load — flagging them would cry wolf over ~200 harmless sites), and whether
# a gate's pattern is strong enough. This gate is about plumbing, not
# assertions.
#
# Exit 0 = PASS, 1 = FAIL. No QEMU, ~1 s.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[gate_pipefail_grepq]"
BASELINE="scripts/ci_pipefail_grepq_baseline.txt"
SCANNER="scripts/_pipefail_grepq_scan.py"

FAILED=0

for f in "$SCANNER" "$BASELINE"; do
    [ -f "$f" ] || { echo "$TAG FAIL: missing $f" >&2; exit 1; }
done

SITES=$(python3 "$SCANNER" "$PROJ_ROOT") || {
    echo "$TAG FAIL: $SCANNER errored" >&2; exit 1; }

N_SITE=$(printf '%s\n' "$SITES" | grep -c '^PIPEQ' || true)
N_OPTOUT=$(printf '%s\n' "$SITES" | grep -c '^OPTOUT' || true)
echo "$TAG scanned $(ls scripts/test_*.sh | wc -l) gate scripts:" \
     "$N_SITE pipefail+grep-q site(s) on a multi-line payload," \
     "$N_OPTOUT declared pipefail-grepq-ok site(s)"
# The opt-out is deliberately un-ratcheted, so it is LISTED instead: an
# escape hatch nobody can see is an escape hatch nobody audits.
printf '%s\n' "$SITES" | awk -F'\t' -v t="$TAG" \
    '$1=="OPTOUT" {printf "%s   pipefail-grepq-ok %s:%s — %s\n", t, $2, $3, $4}'

CUR=$(printf '%s\n' "$SITES" | awk -F'\t' '$1=="PIPEQ" {print $2}' \
        | sort | uniq -c | awk '{printf "%s %s\n", $2, $1}' | sort)
BASE=$(sed 's/#.*//' "$BASELINE" | awk 'NF==2 {print $1, $2}' | sort)

# --- PART 1: no NEW script may acquire a site -------------------------------
echo "$TAG PART 1: no gate outside the frozen baseline"
NEW=$(comm -23 <(printf '%s\n' "$CUR"  | awk '{print $1}' | sort -u) \
               <(printf '%s\n' "$BASE" | awk '{print $1}' | sort -u))
if [ -n "$NEW" ]; then
    echo "$TAG FAIL: gate(s) newly piping a multi-line payload into grep -q:" >&2
    printf '%s\n' "$NEW" | sed "s|^|$TAG   |" >&2
    echo "$TAG   When that assertion MATCHES, grep -q exits, the writer takes" >&2
    echo "$TAG   SIGPIPE (141), pipefail promotes it, and the link reports the" >&2
    echo "$TAG   OPPOSITE of what it observed. Use a here-string instead:" >&2
    echo "$TAG       if ! grep -q 'PAT' <<<\"\$body\"; then" >&2
    echo "$TAG   Move the pattern verbatim. Do NOT add a line to $BASELINE." >&2
    FAILED=1
else
    echo "$TAG   ok  no gate outside the frozen baseline"
fi

# --- PART 2: baselined counts may only shrink, and must still be needed -----
echo "$TAG PART 2: the baseline is a ceiling, not a licence"
GREW=""
while read -r path n; do
    [ -n "$path" ] || continue
    b=$(printf '%s\n' "$BASE" | awk -v p="$path" '$1==p {print $2}')
    [ -n "$b" ] || continue           # already reported as NEW above
    [ "$n" -le "$b" ] || GREW="$GREW$path: $b -> $n"$'\n'
done < <(printf '%s\n' "$CUR")
if [ -n "$GREW" ]; then
    echo "$TAG FAIL: baselined gate(s) GREW new sites:" >&2
    printf '%s' "$GREW" | sed "s|^|$TAG   |" >&2
    FAILED=1
else
    echo "$TAG   ok  no baselined gate grew a new site"
fi

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
    echo "$TAG   Delete them. A baseline that keeps entries it no longer" >&2
    echo "$TAG   needs stops being a ratchet and becomes a rubber stamp." >&2
    FAILED=1
else
    echo "$TAG   ok  every baseline entry is still needed"
fi

# --- PART 3: the baseline is APPEND-FORBIDDEN (vs HEAD) ---------------------
echo "$TAG PART 3: the baseline may only SHRINK (vs HEAD)"
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
        echo "$TAG   This file is a FROZEN inventory. New sites get fixed, or" >&2
        echo "$TAG   get a \`# pipefail-grepq-ok: <reason>\` at the site." >&2
        FAILED=1
    else
        echo "$TAG   ok  no widening"
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    echo "$TAG FAIL"
    exit 1
fi
echo "$TAG PASS"
exit 0
