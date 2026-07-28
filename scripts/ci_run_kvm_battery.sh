#!/usr/bin/env bash
# scripts/ci_run_kvm_battery.sh — run the gates GitHub CI can never run.
#
# WHY THIS EXISTS
# ===============
# Every runner in .github/workflows is `runs-on: ubuntu-latest`, which has no
# /dev/kvm. 20 gates named in scripts/ci_battery_manifest.txt open with a hard
#
#     [ -e /dev/kvm ] || { echo "SKIP: /dev/kvm absent" >&2; exit 0; }
#
# so on GitHub they exit 0 without booting anything. They are honest gates —
# a pure-TCG OVMF boot cannot finish in the budget, and a hard skip beats a
# flapping red — but the consequence is that a green CI run has said nothing
# about desktop rendering, the on-device browser, the installer, or webkit.
#
# The set is only dark BECAUSE OF WHERE IT RUNS. On a KVM host it is real
# coverage, and there is no reason not to have it: this script is the entry
# point that makes running it routine rather than an archaeology project.
#
# scripts/test_gate_kvmdark.sh keeps the population honest (it is the ratchet
# and it prints the count on every CI run); this script RUNS it.
#
# USAGE
#   bash scripts/ci_run_kvm_battery.sh              # all of them, serially
#   bash scripts/ci_run_kvm_battery.sh -n           # list, run nothing
#   bash scripts/ci_run_kvm_battery.sh test_webkit  # substring filter
#
#   KVM_BATTERY_SKIP_BUILD=1   do not pre-build the installer image
#   KVM_BATTERY_TIMEOUT=900    per-gate wall-clock cap (default 900 s)
#
# SERIALISED ON PURPOSE. These are heavy OVMF boots; two at once starve each
# other's guest timers and manufacture false reds (see the -smp2 confounder
# note in the project memory). One QEMU at a time, no exceptions.
#
# EXIT STATUS
#   0  every gate PASSed or was INCONCLUSIVE
#   1  at least one gate FAILed
# The per-gate verdict is the three-valued one (scripts/_verdict.sh), run
# through scripts/ci_run_gate.sh so 125 (INCONCLUSIVE) is not confused with a
# regression. The hambrowse family additionally uses a LOCAL exit 2 for
# inconclusive; that is normalised here so it is not reported as a failure.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[kvm_battery]"
SCANNER="scripts/_kvmdark_scan.py"
PER_GATE_TIMEOUT="${KVM_BATTERY_TIMEOUT:-900}"
DRY=0
FILTER=""

for a in "$@"; do
    case "$a" in
        -n|--dry-run) DRY=1 ;;
        -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
        *) FILTER="$a" ;;
    esac
done

[ -f "$SCANNER" ] || { echo "$TAG FAIL: missing $SCANNER" >&2; exit 1; }

if [ ! -e /dev/kvm ]; then
    echo "$TAG This host has no /dev/kvm. That is precisely the condition"
    echo "$TAG under which these gates assert nothing — there is no point"
    echo "$TAG running them here. Run on a KVM host."
    exit 0
fi
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "$TAG /dev/kvm exists but is not readable/writable by $(id -un)." >&2
    echo "$TAG Add yourself to the 'kvm' group. Refusing to run: every gate" >&2
    echo "$TAG would fall back or fail for an environment reason." >&2
    exit 1
fi

mapfile -t GATES < <(python3 "$SCANNER" "$PROJ_ROOT" \
                     | awk -F'\t' '$1=="DARK" {print $2}' | sort)
if [ -n "$FILTER" ]; then
    mapfile -t GATES < <(printf '%s\n' "${GATES[@]}" | grep -- "$FILTER" || true)
fi

N=${#GATES[@]}
if [ "$N" -eq 0 ]; then
    echo "$TAG no gates selected${FILTER:+ (filter: $FILTER)}" >&2
    exit 0
fi

echo "$TAG $N KVM-dark gate(s) — the set a GitHub run does NOT cover:"
printf '%s\n' "${GATES[@]}" | sed "s|^|$TAG   |"
[ "$DRY" -eq 1 ] && exit 0

# --- a FRESH image, once, up front ------------------------------------------
# Each gate would otherwise rebuild it, and a stale image is the single most
# reliable source of a false red in this battery.
if [ "${KVM_BATTERY_SKIP_BUILD:-0}" != "1" ]; then
    # shellcheck source=scripts/_installer_img.sh
    . scripts/_installer_img.sh
    IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
    echo "$TAG ensuring a fresh $IMG before any boot"
    if ! ensure_installer_img "$IMG" "$TAG"; then
        echo "$TAG RESULT: INCONCLUSIVE — $IMG could not be produced, so" >&2
        echo "$TAG   nothing was booted and nothing was asserted." >&2
        exit 125
    fi
    echo "$TAG image ready: $(installer_img_age_str "$IMG")"
fi

RESULTS=""
NPASS=0; NFAIL=0; NINC=0
T0=$(date +%s)

for g in "${GATES[@]}"; do
    name="$(basename "$g" .sh)"
    echo
    echo "$TAG ===== $name ====="
    gt0=$(date +%s)
    # HAMNIX_SKIP_BUILD=1: the image was just built above; a gate rebuilding
    # it mid-battery would make every later verdict describe a DIFFERENT build.
    HAMNIX_SKIP_BUILD=1 SKIP_BUILD=1 \
        timeout "$PER_GATE_TIMEOUT" bash scripts/ci_run_gate.sh "$g"
    rc=$?
    gt=$(( $(date +%s) - gt0 ))
    case "$rc" in
        0)   v=PASS;         NPASS=$((NPASS+1)) ;;
        # 2 = the hambrowse family's LOCAL inconclusive code. ci_run_gate.sh
        # maps only 125; without this line those runs read as failures.
        2)   v=INCONCLUSIVE; NINC=$((NINC+1)) ;;
        124) v=TIMEOUT;      NINC=$((NINC+1)) ;;
        125) v=INCONCLUSIVE; NINC=$((NINC+1)) ;;
        143) v=KILLED;       NINC=$((NINC+1)) ;;
        *)   v=FAIL;         NFAIL=$((NFAIL+1)) ;;
    esac
    echo "$TAG $name: $v (rc=$rc, ${gt}s)"
    RESULTS="$RESULTS$(printf '%-42s %-13s %5ss rc=%s' "$name" "$v" "$gt" "$rc")"$'\n'
done

TOTAL=$(( $(date +%s) - T0 ))
echo
echo "$TAG ============================================================"
echo "$TAG KVM-dark battery summary — $N gate(s), $((TOTAL/60))m$((TOTAL%60))s"
echo "$TAG ============================================================"
printf '%s' "$RESULTS" | sed "s|^|$TAG   |"
echo "$TAG   PASS $NPASS   FAIL $NFAIL   INCONCLUSIVE $NINC"
echo "$TAG A GitHub run covers NONE of the above."

[ "$NFAIL" -eq 0 ] || exit 1
exit 0
