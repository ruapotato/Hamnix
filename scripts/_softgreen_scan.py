#!/usr/bin/env python3
"""scripts/_softgreen_scan.py — the SOFT-GREEN detector.

Shared by scripts/test_gate_softgreen.sh (the meta-gate) and available for
ad-hoc use. Prints one record per detected site:

    <kind>\t<script>\t<line>\t<source text>

KINDS
  IDIOM   `ensure_installer_img ... || exit 0` (and the `|| { ...; exit 0; }`
          brace form). BANNED outright: ensure_installer_img returns non-zero
          for BOTH "skipped by request" and "the build FAILED", so `|| exit 0`
          reports PASS for a tree that does not build. Use
          installer_img_or_verdict (scripts/_installer_img.sh), which exits 0
          only for the by-request case and 125 (INCONCLUSIVE) otherwise.

  ARTIFACT
          An `exit 0` guarded by a message saying the artifact the gate is
          about to boot could not be produced — "build failed", "still
          missing after", "no usable <img>", "<img> unavailable". Same false
          green, written out longhand instead of via the helper.

Deliberate exceptions are opted out per-site with a comment on, or within the
three lines above, the exit:

    # soft-green-ok: <reason the by-request skip is honest here>

so that "deliberate" is distinguishable from "forgotten" by the next reader —
the same rule scripts/test_gate_registration.sh applies to dark gates.
"""
import glob
import os
import re
import sys

# The exit-0 site itself: a command-list position, not a substring of prose.
EXIT0 = re.compile(r'(^|[;&|{(]|\bthen\b|\belse\b|\bdo\b)\s*exit\s+0\s*(;|\}|$)')

# "the artifact could not be produced" — deliberately NOT a generic
# "unavailable": a missing libvulkan or a missing system awk is a DEPENDENCY
# skip, a different (and often legitimate) call. This matches only the
# artifact-we-were-going-to-boot.
ARTIFACT = re.compile(
    r'(build[a-z_.]*\s+failed'
    r'|build\s+failed'
    r'|failed/gated'
    r'|could not build'
    r'|still missing'
    r'|still absent'
    r'|no usable'
    r'|image unavailable'
    r'|\$\{?(INSTALLER_)?IMG\}?\s+(is\s+)?unavailable'
    r'|\$\{?GOLDEN_NVME\}?\s+unavailable'
    r'|installer image\s+\S*\s*unavailable'
    r'|golden installed disk\s+\S*\s*unavailable'
    r'|build gated'
    r')', re.I)

OPTOUT = re.compile(r'#\s*soft-green-ok:')
IDIOM = re.compile(r'ensure_installer_img\b[^\n]*\|\|')

# A skip the CALLER asked for is honest: the battery deliberately runs the
# slow image gates with HAMNIX_SKIP_BUILD=1 and no image is expected. Only a
# skip after an ATTEMPTED-and-FAILED build is a false green. When the guard
# itself names the by-request switch, the site is by definition the former.
BY_REQUEST = re.compile(r'\bHAMNIX_SKIP_BUILD\b|\bSKIP_BUILD\b|\bHAMNIX_SOAK\b')


def scan(path):
    """Yield (kind, lineno, text) for every soft-green site in <path>."""
    try:
        lines = open(path, errors='replace').read().split('\n')
    except OSError:
        return
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('#'):
            continue
        if not EXIT0.search(line):
            continue
        # Context: this line plus the three above it, comments included so the
        # opt-out marker is visible, prose-only lines excluded from matching.
        ctx_all = lines[max(0, i - 3):i + 1]
        optout = [c for c in ctx_all if OPTOUT.search(c)]
        if optout:
            # Reported, not silent: an escape hatch nobody can see is an
            # escape hatch nobody audits.
            yield ('OPTOUT', i + 1,
                   OPTOUT.split(optout[-1])[-1].strip() or '(no reason given)')
            continue
        ctx = '\n'.join(c for c in ctx_all if not c.strip().startswith('#'))
        # Lines that QUOTE the idiom inside an echo (a gate explaining the
        # rule to its reader) contain escaped quotes; they are prose.
        if '\\"' in stripped:
            continue
        if IDIOM.search(ctx):
            yield ('IDIOM', i + 1, stripped)
        elif ARTIFACT.search(ctx) and not BY_REQUEST.search(ctx):
            yield ('ARTIFACT', i + 1, stripped)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    os.chdir(root)
    for g in sorted(glob.glob('scripts/test_*.sh')):
        for kind, n, text in scan(g):
            print('%s\t%s\t%d\t%s' % (kind, g, n, text[:160]))


if __name__ == '__main__':
    main()
