#!/usr/bin/env python3
"""scripts/_pipefail_grepq_scan.py — the PIPEFAIL+SIGPIPE detector.

Shared by scripts/test_gate_pipefail_grepq.sh (the meta-gate) and available
for ad-hoc use. Prints one record per detected site:

    <kind>\t<script>\t<line>\t<source text>

THE DEFECT
==========
Under `set -o pipefail`, this shape reports the WRONG ANSWER when it matches:

    if ! echo "$body" | grep -q 'PAT'; then fail; fi

`grep -q` exits the instant it matches. That closes the read end of the pipe
while the writer is still writing, so the writer dies of SIGPIPE (141);
`pipefail` promotes 141 to the pipeline's exit status; `if !` inverts it — and
a MATCHING assertion reports FAILURE.

It is not a rare race. bash's `echo`/`printf` builtins write UNBUFFERED, one
write(2) per output segment — measured at ~134 bytes per syscall — so a 30 KB
payload is ~237 separate syscalls and ~237 separate chances for grep to have
already gone. There is no pipe-buffer batching to hide behind.

MEASURED ON THIS HOST (2026-07-31), match at line 1, `echo "$p" | grep -q`:

    payload      quiet host        8 spinners
    ----------------------------------------------
    <=10 lines   0/400             0/400
    ~30 lines    -                 1/400
    4 KB         0/200             1/400
    8 KB         0/200             5/400
    12 KB        4/200             5/200
    15 KB        158/200           8/200
    >=20 KB      200/200           200/200

Two things follow. First, above ~16 KB it stops being a flake and becomes
DETERMINISTIC — the link simply always returns the wrong answer. Second, the
rate near the threshold swings wildly with load in BOTH directions (15 KB was
79% quiet and 4% loaded), because what matters is whether grep's exec beats
the writer's last syscall. A gate that is green on your laptop is not
evidence.

Match POSITION matters as much as size: a match in the last ~10% of the
stream is safe (grep has already drained the writer), which is why the
obvious mutation test — append the offending line at the END of the file —
reports the guard WORKING when it is in fact blind. See the 2026-07-31
finding in scripts/test_de_new_apps.sh.

BOTH SENSES ARE WRONG, AND THE QUIET ONE IS WORSE
=================================================
  positive assertion   `if ! writer | grep -q PAT; then fail`
        match present -> 141 -> `!` -> FAIL on a healthy tree.
        A FALSE RED. Noisy, wastes triage, but self-announcing.

  absent assertion     `if writer | grep -q PAT; then fail`
        match present -> 141 -> `if` false -> ELSE -> "passed".
        A FALSE GREEN. The regression the guard exists to catch walks
        straight through it, and nothing is ever printed.

scripts/test_de_new_apps.sh had two of the second kind over a 43 KB payload.
Proven blind by mutation: with the offending line inserted at the FIRST code
line, the gate reported PASS on 7 of 7 runs.

THE FIX
=======
Use a here-string, which is a REDIRECTION and not a pipeline — there is no
writer process, so there is nothing for SIGPIPE to kill and nothing for
pipefail to promote:

    if ! grep -q 'PAT' <<<"$body"; then

or, when the payload comes from a file or is reused, materialise it and grep
the FILE. Both are already the house idiom (200+ uses across scripts/).
Move the pattern VERBATIM; do not retype it. A typo in an assertion is a
silent false green, which is the very thing this gate is about.

WHAT IS FLAGGED
===============
Only sites where the payload can plausibly be MULTI-LINE, because that is
where the measurement shows exposure:

  * the writer is a filter/dumper (awk, sed, grep, cat, head, tail, strings,
    readelf, objdump, file, od, xxd), or
  * the writer is `echo`/`printf` of a variable that was assigned from a
    command substitution containing one of those.

A single-line payload (`echo "$one_word" | grep -q`) is NOT flagged: it is
one or two write() syscalls and measured 0/400 under load. Flagging those
would be crying wolf over ~200 harmless sites and would train people to
ignore this gate.

Deliberate exceptions are opted out per-site with a comment on, or within the
three lines above, the pipeline:

    # pipefail-grepq-ok: <why this payload is bounded to a line or two>
"""
import glob
import os
import re
import sys

# `set -o pipefail` in any of its spellings (-euo, -eo, -o, ...).
PIPEFAIL = re.compile(r'^\s*set\s+-[a-z]*o\s+pipefail\b', re.M)

# A pipeline segment ending in a quiet grep. `-q` may be clustered (-qE, -qF,
# -qiE) or spelled --quiet/--silent.
GREPQ = re.compile(
    r'\|\s*(?:grep|egrep|fgrep|zgrep)\s+'
    r'(?:-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)\b')

# Commands whose output is a stream of lines, not a scalar.
MULTILINE_CMD = (r'awk|sed|grep|egrep|fgrep|cat|head|tail|strings|readelf'
                 r'|objdump|file|od|xxd|nm|dumpe2fs|debugfs|find|ls')

# writer is such a command, directly on the left of the pipe
DIRECT = re.compile(r'(?:^|\||;|&&|\|\||\(|\bif\b|\bthen\b|\belif\b|!)\s*'
                    r'(?:' + MULTILINE_CMD + r')\s')

# writer is echo/printf of a variable
ECHOVAR = re.compile(r'(?:echo|printf)\s+(?:-e\s+|\S*%s\S*\s+)?"\$\{?(\w+)\}?"')

OPTOUT = re.compile(r'#\s*pipefail-grepq-ok:')


def logical_lines(src):
    """Yield (1-based start line, text) with `\\`-continuations joined."""
    out, buf, start = [], '', None
    for i, raw in enumerate(src.split('\n'), 1):
        if start is None:
            start = i
        if raw.endswith('\\'):
            buf += raw[:-1] + ' '
            continue
        out.append((start, buf + raw))
        buf, start = '', None
    if buf:
        out.append((start or 1, buf))
    return out


def var_is_multiline(name, src):
    """True if NAME is ever assigned from a command substitution that runs a
    line-stream command — i.e. it can hold a captured multi-line body."""
    for m in re.finditer(r'^\s*(?:local\s+|export\s+)?' + re.escape(name)
                         + r'=(.*)$', src, re.M):
        rhs = m.group(1)
        if re.search(r'\$\(|`', rhs) and re.search(MULTILINE_CMD, rhs):
            return True
        # `read -r X < <(cmd)` and `X=$(<file)` also yield multi-line values
        if re.search(r'\$\(<', rhs):
            return True
    return False


def scan_file(path):
    try:
        src = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return []
    if not PIPEFAIL.search(src):
        return []
    raw_lines = src.split('\n')
    sites = []
    for start, text in logical_lines(src):
        stripped = text.lstrip()
        if stripped.startswith('#'):
            continue
        if not GREPQ.search(text):
            continue
        # opt-out on the line itself or the three lines above it
        window = raw_lines[max(0, start - 4):start]
        if OPTOUT.search(text) or any(OPTOUT.search(w) for w in window):
            sites.append(('OPTOUT', path, start, text.strip()[:160]))
            continue
        # split on REAL pipes only: `||` is an or-list, not a pipeline, and
        # treating it as one made the trailing `|| fail` look like a
        # mid-pipeline filter and flagged essentially every site.
        segs = re.split(r'(?<!\|)\|(?!\|)', text)
        writer = segs[0]
        multiline = bool(DIRECT.search(writer))
        if not multiline:
            m = ECHOVAR.search(writer)
            if m and var_is_multiline(m.group(1), src):
                multiline = True
        # a mid-pipeline filter also makes the payload a line stream
        if not multiline:
            for seg in segs[1:-1]:
                if re.match(r'\s*(?:' + MULTILINE_CMD + r')\s', seg):
                    multiline = True
                    break
        if multiline:
            sites.append(('PIPEQ', path, start, text.strip()[:160]))
    return sites


def main(root='.'):
    out = []
    for path in sorted(glob.glob(os.path.join(root, 'scripts', 'test_*.sh'))):
        out.extend(scan_file(path))
    for kind, path, line, text in out:
        rel = os.path.relpath(path, root)
        print(f'{kind}\t{rel}\t{line}\t{text}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else '.'))
