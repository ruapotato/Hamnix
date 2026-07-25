#!/usr/bin/env python3
"""scripts/probe_script_survival.py — measure how many of a real page's <script>
blocks RUN TO COMPLETION inside hambrowse, in the page's own context.

WHY THIS AND NOT probe_realweb_scripts.py: that harness runs each script in
ISOLATION, so every script that legitimately depends on a global defined by an
earlier one is scored FAIL. That over-counts. The number that actually matters
for a user ("does google work?") is: given the real page, executed in order, how
many scripts reach their last statement?

METHOD: append `;console.log("SURVIVE <n>")` to each inline script and count the
markers. A script that dies part-way (uncaught throw, fatal ReferenceError,
SyntaxError) never prints its marker. Also reports each script's FIRST error.

Usage: probe_script_survival.py <fixture.html> [engine-binary]
"""
import os
import re
import subprocess
import sys
import tempfile

BIN_DEFAULT = "build/host/hambrowse_probe_host"


def instrument(html):
    """Append a survival marker to every inline (non-src) <script>."""
    n = [0]
    total = [0]

    def repl(m):
        attrs, body = m.group(1), m.group(2)
        if re.search(r"\bsrc\s*=", attrs, re.I) or not body.strip():
            return m.group(0)
        i = n[0]
        n[0] += 1
        total[0] += 1
        return ('<script%s>console.log("START %d");\n%s\n'
                ';console.log("SURVIVE %d");</script>' % (attrs, i, body, i))

    out = re.sub(r"<script\b([^>]*)>(.*?)</script\s*>", repl, html, flags=re.I | re.S)
    return out, total[0]


def main():
    path = sys.argv[1]
    binp = sys.argv[2] if len(sys.argv) > 2 else BIN_DEFAULT
    html = open(path, errors="replace").read()
    inst, total = instrument(html)
    fd, tmp = tempfile.mkstemp(suffix=".html", dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w") as f:
        f.write(inst)
    try:
        p = subprocess.run([binp, tmp, "1024"], capture_output=True,
                           text=True, timeout=900)
        out = p.stdout
    except subprocess.TimeoutExpired:
        print("TIMEOUT")
        return 2
    finally:
        os.unlink(tmp)

    # Scripts run in document order, so every error line belongs to the LOWEST
    # script index that has not yet printed its SURVIVE marker. That attributes
    # each failure to the script that actually caused it.
    survived = set()
    errs = {}
    started = set()
    cur = 0
    for line in out.splitlines():
        m = re.match(r"JSLOG SURVIVE (\d+)$", line)
        if m:
            survived.add(int(m.group(1)))
            continue
        m = re.match(r"JSLOG START (\d+)$", line)
        if m:
            cur = int(m.group(1))
            started.add(cur)
            continue
        msg = None
        if line.startswith("JSERR "):
            msg = line[6:]
        elif line.startswith("JSLOG ") and re.search(r"(Error|Uncaught)", line):
            msg = line[6:]
        if msg is not None:
            errs.setdefault(cur, []).append(msg)

    print("%s" % path)
    print("SCRIPTS %d  SURVIVED %d  DIED %d" %
          (total, len(survived), total - len(survived)))
    never = sorted(i for i in range(total) if i not in started)
    if never:
        print("NEVER-STARTED: %s" % " ".join(str(i) for i in never))
    dead = [i for i in range(total) if i not in survived]
    if dead:
        print("DEAD: %s" % " ".join(str(i) for i in dead))
    for i in sorted(errs):
        seen = set()
        for e in errs[i]:
            if e in seen:
                continue
            seen.add(e)
            print("  [%2d] %s%s" % (i, "DIED  " if i in dead else "caught", e))
    return 0


if __name__ == "__main__":
    sys.exit(main())
