#!/usr/bin/env python3
"""scripts/_kvmdark_scan.py — the KVM-DARK detector.

THE HOLE THIS MEASURES
======================
scripts/test_gate_registration.sh proves a gate is RUN by CI.
scripts/test_gate_softgreen.sh proves a gate does not report PASS for an
assertion it could not observe because the artifact would not BUILD.

Neither one asks the third question: does the gate observe its assertion on
the machine CI actually runs it on?  Every runner in .github/workflows is
`runs-on: ubuntu-latest`, which has NO /dev/kvm.  A gate whose first act is

    [ -e /dev/kvm ] || { echo "SKIP: /dev/kvm absent" >&2; exit 0; }

therefore exits 0 on EVERY GitHub run, has never asserted anything there, and
is indistinguishable in the log from a gate that ran and passed.  That is the
same false-coverage shape as an unregistered gate, one capability over: the
gate is registered, CI runs it, it goes green, and it observed nothing.

It is NOT a lying gate — on a KVM host it is completely honest, and a hard
skip is the right call for a boot that pure TCG cannot finish in the budget.
The defect is that nothing anywhere states the size of the hole.  So this
scanner counts it, and scripts/test_gate_kvmdark.sh ratchets the count and
prints it on every CI run, so a green run says plainly what it did not cover.

OUTPUT
======
One record per gate that reacts to a missing /dev/kvm:

    <kind>\t<script>\t<line>\t<source text>

KINDS
  DARK       kvm-absent -> `exit 0`, and the gate IS registered in CI.
             Vacuously green on every GitHub run.  This is the population
             the ratchet governs.
  DARKUNREG  kvm-absent -> `exit 0`, but nothing in CI runs the gate anyway.
             Informational: scripts/test_gate_registration.sh owns that hole.
  HONEST     kvm-absent -> INCONCLUSIVE (exit 125 / verdict_inconclusive).
             The correct shape: no verdict is claimed.  Counted, never failed.
  TCG        kvm-absent -> the gate carries on under software emulation.
             Real coverage on a GitHub runner.  Counted, never failed.

A DARK gate may opt out per-site, in the source, with a reason:

    # kvm-dark-ok: <why a silent exit 0 is the right call here>

Opt-outs are LISTED by the meta-gate rather than hidden, on the same
principle as `# soft-green-ok:` — an escape hatch nobody can see is an
escape hatch nobody audits.
"""
import glob
import os
import re
import sys

# A /dev/kvm CAPABILITY TEST, not a mention in prose or a -cpu/-accel string.
GUARD = re.compile(r'\[+\s*!?\s*-[a-z]\s+/dev/kvm\s*\]+'
                   r'|\[+\s*!?\s*-[a-z]\s+"?\$\{?KVM')
# The exit-0 site itself: a command-list position, not a substring of prose.
# re.M is load-bearing — the reaction is matched against a multi-line WINDOW,
# and without it `^`/`$` anchor to the whole window instead of each line, so
# the overwhelmingly common shape
#     if [ ! -e /dev/kvm ]; then
#         echo "SKIP" >&2
#         exit 0
#     fi
# goes undetected and every dark gate is misfiled as TCG.
EXIT0 = re.compile(r'(^|[;&|{(]|\bthen\b|\belse\b|\bdo\b)\s*exit\s+0\s*(;|\}|$)',
                   re.M)
INCONCL = re.compile(r'verdict_inconclusive|exit\s+125', re.M)
OPTOUT = re.compile(r'#\s*kvm-dark-ok:')
# A gate that can FAIL before it reaches the /dev/kvm guard still asserts
# SOMETHING on a KVM-less runner — test_de_office_suite.sh and
# test_de_desktop_icon_source.sh both prove their launchers are shipped
# before they try to boot. That is the shape the other 18 should grow, so the
# census distinguishes "partly covered" from "wholly vacuous" rather than
# lumping them together and overstating the hole.
PRE_ASSERT = re.compile(r'(^|[;&|{(]|\bthen\b|\belse\b|\bdo\b)\s*exit\s+1\b'
                        r'|\bverdict_fail\b', re.M)

WINDOW = 6          # lines after the guard in which the reaction must appear


def uncommented(path):
    out = []
    for line in open(path, errors='replace'):
        if line.lstrip().startswith('#'):
            continue
        out.append(line)
    return '\n'.join(out)


def registered_gates(root='.'):
    """The same definition scripts/test_gate_registration.sh uses."""
    all_gates = set(glob.glob('scripts/test_*.sh'))
    reg = set()
    manifest = 'scripts/ci_battery_manifest.txt'
    if os.path.exists(manifest):
        reg |= set(re.findall(r'scripts/test_[A-Za-z0-9_.-]+\.sh',
                              uncommented(manifest)))
    for wf in sorted(glob.glob('.github/workflows/*.yml')):
        body = uncommented(wf)
        for pat in re.findall(r'scripts/test_[A-Za-z0-9_.*-]+\.sh', body):
            if '*' in pat:
                reg.update(glob.glob(pat))
            else:
                reg.add(pat)
        for bare in re.findall(r'(?<![\w/$])(test_[a-z0-9_]+)(?![\w.])', body):
            cand = 'scripts/%s.sh' % bare
            if cand in all_gates:
                reg.add(cand)
    return reg & all_gates


def classify(path):
    """Yield (kind_without_registration, lineno, text) for <path>.

    Only the FIRST reaction to a missing /dev/kvm is reported: a gate that
    hard-skips at the top is dark regardless of what a later guard does.
    """
    try:
        lines = open(path, errors='replace').read().split('\n')
    except OSError:
        return
    for i, line in enumerate(lines):
        if line.lstrip().startswith('#'):
            continue
        if not GUARD.search(line):
            continue
        win_all = lines[i:i + WINDOW + 1]
        # The opt-out marker may sit ON the guard, just below it, or in the
        # three lines ABOVE — the same latitude scripts/_softgreen_scan.py
        # gives `# soft-green-ok:`. Searching downward only made a marker
        # written above the guard silently ineffective.
        optout = [c for c in lines[max(0, i - 3):i + WINDOW + 1]
                  if OPTOUT.search(c)]
        win = '\n'.join(c for c in win_all if not c.strip().startswith('#'))
        # An INCONCLUSIVE verdict in the window wins over a bare exit 0: the
        # honest gates print a message and then exit 125.
        if INCONCL.search(win):
            yield ('HONEST', i + 1, line.strip())
            return
        if EXIT0.search(win):
            if optout:
                yield ('OPTOUT', i + 1,
                       OPTOUT.split(optout[-1])[-1].strip() or '(no reason given)')
            else:
                # The shell prologue `cd "$(dirname "$0")/.." || exit 1` is
                # not an assertion about the product; counting it would
                # credit every gate in the tree with a structural half.
                pre = '\n'.join(c for c in lines[:i]
                                if not c.strip().startswith('#')
                                and not re.match(r'\s*(cd|source|\.|pushd|exec)\b', c))
                note = ' [structural half asserts first]' \
                    if PRE_ASSERT.search(pre) else ''
                yield ('DARK', i + 1, line.strip() + note)
            return
        yield ('TCG', i + 1, line.strip())
        return


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    os.chdir(root)
    reg = registered_gates(root)
    # The meta-gate itself probes /dev/kvm only to word its own census
    # ("this host has KVM" vs "this runner does not"); counting it as a
    # subject of the census is noise.
    SELF = {'scripts/test_gate_kvmdark.sh'}
    for g in sorted(glob.glob('scripts/test_*.sh')):
        if g in SELF:
            continue
        for kind, n, text in classify(g):
            if kind == 'DARK' and g not in reg:
                kind = 'DARKUNREG'
            print('%s\t%s\t%d\t%s' % (kind, g, n, text[:160]))


if __name__ == '__main__':
    main()
