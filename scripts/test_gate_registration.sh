#!/usr/bin/env bash
# scripts/test_gate_registration.sh — QEMU-FREE meta-gate against the
# UNREGISTERED-GATE class: a scripts/test_*.sh that exists in the tree, looks
# like coverage in every report and every code review, and asserts NOTHING
# because no CI job ever runs it.
#
# WHY THIS GATE EXISTS
# ====================
# Counted on 55c842b9: 1495 scripts/test_*.sh exist; 528 are named in
# scripts/ci_battery_manifest.txt and a further ~97 are run directly by
# .github/workflows/ci.yml (including the test_opt_* / test_compiler_*
# globs). That left 879 gate scripts that NO CI job runs. This is not a
# hypothetical:
#
#   * scripts/test_hambrowse_tagquote_host.sh existed but was unregistered.
#     The layout tokenizer was made quote-aware rounds ago; because nothing
#     ran the gate, 35 other scanners kept naive `while src_ptr[j] != '>'`
#     walks and Wikipedia over-reported textContent by +21378 chars.
#   * scripts/test_de_panel_config.sh unregistered -> a ghost window
#     swallowing clicks shipped.
#   * scripts/test_installer_nvme_inram.sh unregistered -> the installer
#     shipped broken with no end-to-end gate.
#   * The ARM64 lane had no CI gate -> it silently stopped building on main.
#
# An unregistered gate is WORSE than a missing one. A missing gate is an
# honest hole. An unregistered gate is a hole that reads as coverage.
#
# THE RULE
# ========
# Every scripts/test_*.sh must be exactly one of:
#
#   (1) REGISTERED  — named in scripts/ci_battery_manifest.txt, or run
#                     directly by a .github/workflows/*.yml step (literal
#                     name or one of the ci.yml globs), or
#   (2) DELIBERATE  — carries an explicit on-demand rationale in its header
#                     comment block: a line containing
#                       "not in ci_battery_manifest.txt because"
#                     The point is that the NEXT reader can tell "deliberate"
#                     from "forgotten" without re-litigating it, or
#   (3) BASELINED   — listed in scripts/ci_ondemand_baseline.txt, the
#                     checked-in inventory of the pre-existing dark gates.
#
# A NEW gate that is none of the three FAILS here. The baseline is a RATCHET,
# not an amnesty: it may only shrink. A baseline entry that has since become
# registered or annotated must be REMOVED from the baseline (that is a FAIL
# too, so the list cannot quietly rot back into a rubber stamp), and a
# baseline entry naming a script that no longer exists must be removed as
# well.
#
# Deliberately NOT solved here: this gate does not care whether a registered
# gate PASSES. That is the battery's job. It only enforces that every gate in
# the tree has a known, stated relationship to CI.
#
# Exit 0 = PASS, 1 = FAIL. No QEMU, ~1 s.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[gate_registration]"
MANIFEST="scripts/ci_battery_manifest.txt"
BASELINE="scripts/ci_ondemand_baseline.txt"

FAILED=0

for f in "$MANIFEST" "$BASELINE"; do
    [ -f "$f" ] || { echo "$TAG FAIL: missing $f" >&2; exit 1; }
done

REPORT=$(python3 - "$MANIFEST" "$BASELINE" <<'PY'
import glob, os, re, sys

manifest_path, baseline_path = sys.argv[1], sys.argv[2]

all_gates = set(glob.glob('scripts/test_*.sh'))

def uncommented(path):
    out = []
    for line in open(path, errors='replace'):
        if line.lstrip().startswith('#'):
            continue
        out.append(line)
    return '\n'.join(out)

# (1a) named in the bare-metal battery manifest
registered = set(re.findall(r'scripts/test_[A-Za-z0-9_.-]+\.sh',
                            uncommented(manifest_path)))

# (1b) run directly by a workflow — literal names AND the ci.yml globs
#      (scripts/test_opt_*.sh, scripts/test_compiler_*.sh, ...). Bare
#      `test_foo` names inside a shell `for t in ... ; do bash "scripts/$t.sh"`
#      list count too.
#      YAML comment lines are stripped first: ci.yml's own header prose says
#      "scripts/test_*.sh", and honouring that glob would mark the ENTIRE
#      tree registered — the exact false-green this gate exists to prevent.
for wf in sorted(glob.glob('.github/workflows/*.yml')):
    body = uncommented(wf)
    for pat in re.findall(r'scripts/test_[A-Za-z0-9_.*-]+\.sh', body):
        if '*' in pat:
            registered.update(glob.glob(pat))
        else:
            registered.add(pat)
    for bare in re.findall(r'(?<![\w/$])(test_[a-z0-9_]+)(?![\w.])', body):
        cand = 'scripts/%s.sh' % bare
        if cand in all_gates:
            registered.add(cand)

registered &= all_gates

# (2) explicit on-demand rationale in the script header
# The header is COMMENT-WRAPPED prose, so the phrase routinely straddles a
# line break ("... not in\n# ci_battery_manifest.txt because ..."). Strip the
# comment markers and collapse whitespace before matching, or the rule
# silently fails to see rationales that are plainly there.
RATIONALE = re.compile(r'not in ci_battery_manifest\.txt because', re.I)
annotated = set()
for g in sorted(all_gates):
    with open(g, errors='replace') as fh:
        head = [next(fh, '') for _ in range(80)]
    prose = ' '.join(re.sub(r'^\s*#+\s?', '', l).strip() for l in head)
    if RATIONALE.search(re.sub(r'\s+', ' ', prose)):
        annotated.add(g)

# (3) baselined
baseline = set()
for line in open(baseline_path, errors='replace'):
    line = line.split('#', 1)[0].strip()
    if line:
        baseline.add(line)

dark = all_gates - registered - annotated - baseline
stale_covered = sorted(baseline & (registered | annotated))
stale_gone = sorted(b for b in baseline if not os.path.exists(b))

print('COUNT_ALL %d' % len(all_gates))
print('COUNT_REGISTERED %d' % len(registered))
print('COUNT_ANNOTATED %d' % len(annotated))
print('COUNT_BASELINE %d' % len(baseline))
for g in sorted(dark):
    print('DARK %s' % g)
for g in stale_covered:
    print('STALE_COVERED %s' % g)
for g in stale_gone:
    print('STALE_GONE %s' % g)
PY
) || { echo "$TAG FAIL: inventory pass errored" >&2; exit 1; }

echo "$TAG PART 1: every scripts/test_*.sh is registered, annotated, or baselined"
echo "$REPORT" | grep '^COUNT_' | sed "s|^|$TAG   |"

DARK=$(echo "$REPORT" | sed -n 's/^DARK //p')
if [ -n "$DARK" ]; then
    N=$(echo "$DARK" | wc -l)
    echo "$TAG FAIL: $N gate script(s) that NO CI job runs and that state no reason:" >&2
    echo "$DARK" | sed "s|^|$TAG   |" >&2
    echo "$TAG   A gate nothing runs is not coverage — it is a hole shaped" >&2
    echo "$TAG   like coverage. Pick one:" >&2
    echo "$TAG     (1) add a line to $MANIFEST (cheap host gates are" >&2
    echo "$TAG         nearly free; measure the runtime first — the battery" >&2
    echo "$TAG         is 12-way sharded under a 50-minute cap), or" >&2
    echo "$TAG     (2) put the reason in the script header, verbatim:" >&2
    echo "$TAG           # Not in ci_battery_manifest.txt because <reason>." >&2
    echo "$TAG   Do NOT satisfy this by adding it to $BASELINE:" >&2
    echo "$TAG   that list is a shrinking ratchet over PRE-EXISTING gates." >&2
    FAILED=1
else
    echo "$TAG   ok  no unaccounted-for gate scripts"
fi

echo "$TAG PART 2: the on-demand baseline is a RATCHET (may only shrink)"
STALE=$(echo "$REPORT" | sed -n 's/^STALE_COVERED //p')
if [ -n "$STALE" ]; then
    echo "$TAG FAIL: baselined gates that are now registered or annotated." >&2
    echo "$TAG   Remove them from $BASELINE — a baseline that keeps" >&2
    echo "$TAG   entries it no longer needs stops being a ratchet:" >&2
    echo "$STALE" | sed "s|^|$TAG   |" >&2
    FAILED=1
else
    echo "$TAG   ok  no baseline entry is redundant"
fi

GONE=$(echo "$REPORT" | sed -n 's/^STALE_GONE //p')
if [ -n "$GONE" ]; then
    echo "$TAG FAIL: baseline names script(s) that no longer exist:" >&2
    echo "$GONE" | sed "s|^|$TAG   |" >&2
    echo "$TAG   Delete the stale line(s) from $BASELINE." >&2
    FAILED=1
else
    echo "$TAG   ok  every baseline entry names a real script"
fi

echo "$TAG PART 3: the baseline is APPEND-FORBIDDEN (vs HEAD)"
# Without this part the gate is trivially launderable: PART 1 accepts anything
# listed in the baseline, so a new dark gate could be waved through by
# appending one line to it — the same "looks like coverage, asserts nothing"
# move the gate exists to stop, just one file over. Proven by negative test on
# 2026-07-28: with only PARTS 1-2, a brand-new probe script went from RED to
# GREEN purely by appending it to the baseline.
#
# So diff the tracked baseline against HEAD's and reject NEW entries. Removals
# are always fine — that is the ratchet turning. Outside a git checkout (or
# before the file exists in HEAD) this part reports and skips rather than
# inventing a verdict.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "$TAG   note: not a git checkout — append check skipped"
elif ! git cat-file -e "HEAD:$BASELINE" 2>/dev/null; then
    echo "$TAG   note: $BASELINE not in HEAD yet — append check skipped"
else
    ADDED=$(comm -13 \
        <(git show "HEAD:$BASELINE" | sed 's/#.*//' | tr -d '[:blank:]' \
            | grep -v '^$' | sort -u) \
        <(sed 's/#.*//' "$BASELINE" | tr -d '[:blank:]' | grep -v '^$' | sort -u))
    if [ -n "$ADDED" ]; then
        echo "$TAG FAIL: entries ADDED to $BASELINE since HEAD:" >&2
        echo "$ADDED" | sed "s|^|$TAG   |" >&2
        echo "$TAG   The baseline is a frozen inventory of the gates that were" >&2
        echo "$TAG   already dark. It may only SHRINK. A gate you are adding" >&2
        echo "$TAG   now gets a manifest line (measure its runtime first) or a" >&2
        echo "$TAG   header rationale — not an entry here." >&2
        FAILED=1
    else
        echo "$TAG   ok  no new baseline entries"
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    echo "$TAG FAIL"
    exit 1
fi
echo "$TAG PASS"
exit 0
