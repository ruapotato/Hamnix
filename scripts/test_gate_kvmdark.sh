#!/usr/bin/env bash
# scripts/test_gate_kvmdark.sh — QEMU-FREE meta-gate against the
# CAPABILITY-VACUOUS class: a gate that IS registered, that CI DOES run, that
# reports GREEN — on a machine where it could never observe its assertion.
#
# WHY THIS GATE EXISTS
# ====================
# Three meta-gates, three different holes:
#
#   test_gate_registration.sh  nothing RUNS this gate
#   test_gate_softgreen.sh     this gate reports PASS for an assertion it
#                              could not observe (the artifact would not build)
#   test_gate_kvmdark.sh       this gate CANNOT observe its assertion on the
#                              machine CI runs it on, and says nothing about it
#
# Every runner in .github/workflows is `runs-on: ubuntu-latest`. ubuntu-latest
# has NO /dev/kvm. 20 gates named in scripts/ci_battery_manifest.txt open with
#
#     [ -e /dev/kvm ] || { echo "SKIP: /dev/kvm absent" >&2; exit 0; }
#
# and therefore exit 0 on EVERY GitHub run without booting anything. In the CI
# log that is indistinguishable from a gate that ran and passed. Measured on
# 2026-07-28, the vacuous set covered: the whole DE visual/wallpaper/icon
# surface, the on-device hambrowse family, the installer NVMe end-to-end, and
# webkit. A green run said nothing about any of it.
#
# THIS IS NOT A LYING GATE, and the fix is NOT to delete the guard. A pure-TCG
# OVMF boot cannot finish in the CI budget; a hard skip beats a battery that
# flaps red on runner load and trains everyone to ignore red. On a KVM host
# every one of these gates is completely honest and real coverage.
#
# The defect is that the hole was INVISIBLE. Nothing in a green run stated its
# size, so "CI is green" and "the desktop renders" read as the same sentence.
#
# THE RULE
# ========
#   1. The count is PRINTED on every CI run, with the gate names, so a green
#      run states plainly what it did not cover. That is this gate's primary
#      job — it is a census that happens to also ratchet.
#   2. scripts/ci_kvmdark_baseline.txt freezes the population. It is a
#      RATCHET: a NEW registered gate that goes silently vacuous on the runner
#      FAILS here. Either report INCONCLUSIVE (exit 125, scripts/_verdict.sh)
#      instead of exit 0, or fall back to TCG, or — if a silent skip really is
#      the right call — say so at the site:
#
#          # kvm-dark-ok: <why exiting 0 silently is honest here>
#
#      Do NOT add a line to the baseline. It may only SHRINK.
#   3. PART 3 diffs the baseline against HEAD, so a new finding cannot be
#      laundered by appending a line — the hole both sibling meta-gates had to
#      close, found only because somebody actually tried it.
#   4. The dark set MUST be runnable in one command on a KVM host:
#      scripts/ci_run_kvm_battery.sh. A hole you can see but cannot close is
#      only half the work.
#
# Why INCONCLUSIVE is the better shape for a NEW gate: exit 125 through
# scripts/ci_run_gate.sh becomes a ::warning:: annotation — not a build
# failure, but not counted as proof either. exit 0 is counted as proof.
#
# Exit 0 = PASS, 1 = FAIL. No QEMU, ~1 s.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[gate_kvmdark]"
BASELINE="scripts/ci_kvmdark_baseline.txt"
SCANNER="scripts/_kvmdark_scan.py"
RUNNER="scripts/ci_run_kvm_battery.sh"

FAILED=0

for f in "$SCANNER" "$BASELINE" "$RUNNER"; do
    [ -f "$f" ] || { echo "$TAG FAIL: missing $f" >&2; exit 1; }
done

SITES=$(python3 "$SCANNER" "$PROJ_ROOT") || {
    echo "$TAG FAIL: $SCANNER errored" >&2; exit 1; }

DARK=$(printf '%s\n' "$SITES" | awk -F'\t' '$1=="DARK"      {print $2}' | sort -u)
UNREG=$(printf '%s\n' "$SITES" | awk -F'\t' '$1=="DARKUNREG" {print $2}' | sort -u)
HONEST=$(printf '%s\n' "$SITES" | awk -F'\t' '$1=="HONEST"   {print $2}' | sort -u)
TCG=$(printf '%s\n' "$SITES" | awk -F'\t' '$1=="TCG"         {print $2}' | sort -u)
OPTOUT=$(printf '%s\n' "$SITES" | awk -F'\t' '$1=="OPTOUT"   {print $2"\t"$4}')

n() { printf '%s\n' "$1" | grep -c . || true; }
N_DARK=$(n "$DARK"); N_UNREG=$(n "$UNREG"); N_HONEST=$(n "$HONEST"); N_TCG=$(n "$TCG")

# --- THE CENSUS: the reason this gate runs on GitHub at all -----------------
echo "$TAG ############################################################"
if [ -e /dev/kvm ]; then
    echo "$TAG THIS HOST HAS /dev/kvm — the $N_DARK gate(s) below CAN run here."
    echo "$TAG Run them:  bash $RUNNER"
else
    echo "$TAG THIS RUNNER HAS NO /dev/kvm."
    echo "$TAG $N_DARK REGISTERED GATE(S) BELOW WILL EXIT 0 WITHOUT ASSERTING"
    echo "$TAG ANYTHING ON THIS RUN. A GREEN RESULT DOES NOT COVER THEM."
    # A GitHub annotation, so the count is visible on the run summary page and
    # not only to whoever expands the log.
    echo "::warning title=KVM-dark gates::$N_DARK registered gate(s) require /dev/kvm and exited 0 without asserting anything on this runner. Run 'bash $RUNNER' on a KVM host for real coverage."
fi
echo "$TAG ############################################################"
printf '%s\n' "$SITES" | awk -F'\t' -v t="$TAG" '$1=="DARK" {
    partial = ($4 ~ /structural half asserts first/)
    printf "%s   %s %s\n", t, (partial ? "partly covered:" : "UNCOVERED:    "), $2
}'
N_PARTIAL=$(printf '%s\n' "$SITES" \
            | awk -F'\t' '$1=="DARK" && $4 ~ /structural half asserts first/' \
            | grep -c . || true)
echo "$TAG census: $N_DARK dark+registered (of which $N_PARTIAL still assert a" \
     "structural half on a KVM-less runner), $N_UNREG dark+unregistered," \
     "$N_HONEST report INCONCLUSIVE, $N_TCG fall back to TCG"
echo "$TAG   'partly covered' is the shape the other $((N_DARK - N_PARTIAL)) should grow:"
echo "$TAG   assert what CAN be asserted (the launcher IS shipped, the asset IS"
echo "$TAG   in the image) BEFORE the capability check, so the GitHub run is not"
echo "$TAG   a complete blank."
if [ -n "$OPTOUT" ]; then
    printf '%s\n' "$OPTOUT" | awk -F'\t' -v t="$TAG" \
        '{printf "%s   kvm-dark-ok %s — %s\n", t, $1, $2}'
fi
# The unregistered dark gates are a DIFFERENT hole and belong to
# test_gate_registration.sh. Named, not failed, so the two counts cannot be
# confused with each other.
echo "$TAG   ($N_UNREG further gate(s) are KVM-dark AND unregistered — that is"
echo "$TAG    scripts/test_gate_registration.sh's hole, not this one.)"

# --- PART 1: the population may not GROW ------------------------------------
echo "$TAG PART 1: no NEW registered gate may go silently vacuous on the runner"
BASE=$(sed 's/#.*//' "$BASELINE" | awk 'NF==1 {print $1}' | sort -u)
NEW=$(comm -23 <(printf '%s\n' "$DARK") <(printf '%s\n' "$BASE"))
if [ -n "$NEW" ]; then
    echo "$TAG FAIL: registered gate(s) newly exiting 0 when /dev/kvm is absent:" >&2
    printf '%s\n' "$NEW" | sed "s|^|$TAG   |" >&2
    echo "$TAG   On a GitHub runner this reports GREEN having asserted nothing." >&2
    echo "$TAG   Report INCONCLUSIVE instead (exit 125, scripts/_verdict.sh) so" >&2
    echo "$TAG   ci_run_gate.sh emits a warning rather than counting it as" >&2
    echo "$TAG   proof, or fall back to TCG, or annotate the guard:" >&2
    echo "$TAG       # kvm-dark-ok: <why a silent exit 0 is honest here>" >&2
    echo "$TAG   Do NOT add a line to $BASELINE." >&2
    FAILED=1
else
    echo "$TAG   ok  no gate outside the frozen population"
fi

# --- PART 2: the ratchet must actually turn ---------------------------------
echo "$TAG PART 2: baseline entries that are no longer needed"
STALE=""
while read -r path; do
    [ -n "$path" ] || continue
    if [ ! -f "$path" ]; then
        STALE="$STALE$path (script no longer exists)"$'\n'
    elif ! printf '%s\n' "$DARK" | grep -qx "$path"; then
        STALE="$STALE$path (no longer dark — remove the line)"$'\n'
    fi
done < <(printf '%s\n' "$BASE")
if [ -n "$STALE" ]; then
    echo "$TAG FAIL: stale baseline entries:" >&2
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
    HEADBASE=$(git show "HEAD:$BASELINE" | sed 's/#.*//' | awk 'NF==1 {print $1}' | sort -u)
    ADDED=$(comm -13 <(printf '%s\n' "$HEADBASE") <(printf '%s\n' "$BASE"))
    if [ -n "$ADDED" ]; then
        echo "$TAG FAIL: $BASELINE was widened since HEAD:" >&2
        printf '%s\n' "$ADDED" | sed "s|^|$TAG   + |" >&2
        echo "$TAG   Appending here is the same false green, one file over." >&2
        FAILED=1
    else
        echo "$TAG   ok  the baseline did not grow"
    fi
fi

# --- PART 4: the hole must be closable in one command -----------------------
echo "$TAG PART 4: the dark set is runnable on a KVM host"
if ! bash -n "$RUNNER" 2>/dev/null; then
    echo "$TAG FAIL: $RUNNER does not parse" >&2
    FAILED=1
elif ! RUN_LIST=$(bash "$RUNNER" -n 2>&1); then
    echo "$TAG FAIL: $RUNNER -n failed" >&2
    printf '%s\n' "$RUN_LIST" | sed "s|^|$TAG   |" >&2
    FAILED=1
else
    MISSING=""
    while read -r path; do
        [ -n "$path" ] || continue
        printf '%s\n' "$RUN_LIST" | grep -q "$path" || MISSING="$MISSING$path"$'\n'
    done < <(printf '%s\n' "$DARK")
    # On a runner with no /dev/kvm the script correctly refuses to enumerate
    # nothing — it still LISTS. Only a genuine omission is a failure.
    if [ -n "$MISSING" ] && printf '%s\n' "$RUN_LIST" | grep -q 'KVM-dark gate'; then
        echo "$TAG FAIL: $RUNNER does not cover:" >&2
        printf '%s' "$MISSING" | sed "s|^|$TAG   |" >&2
        FAILED=1
    else
        echo "$TAG   ok  $RUNNER enumerates the whole dark set"
    fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "$TAG RESULT: PASS ($N_DARK KVM-dark registered gate(s), population frozen)"
    exit 0
fi
echo "$TAG RESULT: FAIL" >&2
exit 1
