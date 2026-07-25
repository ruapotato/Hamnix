#!/usr/bin/env python3
"""scripts/probe_script_survival_chrome.py — the CHROMIUM oracle for
probe_script_survival.py.

Instruments a fixture exactly the same way (a SURVIVE marker appended to every
inline <script>) and runs it under `chromium --headless`, so hambrowse's
script-survival count can be compared against the number a real browser gets on
the SAME bytes. That matters because a snapshot fixture is not the live site:
inlining a stylesheet removes the <link> element it came from, so a script doing
`document.getElementById('ogb_ss').onload = …` legitimately throws in BOTH
engines. Without the oracle those look like hambrowse bugs.

Usage: probe_script_survival_chrome.py <fixture.html>
"""
import os
import re
import subprocess
import sys
import tempfile

CHROME = "chromium"


def instrument(html):
    n = [0]

    def repl(m):
        attrs, body = m.group(1), m.group(2)
        if re.search(r"\bsrc\s*=", attrs, re.I) or not body.strip():
            return m.group(0)
        i = n[0]
        n[0] += 1
        return ('<script%s>console.log("START %d");\n%s\n'
                ';console.log("SURVIVE %d");</script>' % (attrs, i, body, i))

    out = re.sub(r"<script\b([^>]*)>(.*?)</script\s*>", repl, html,
                 flags=re.I | re.S)
    return out, n[0]


def main():
    path = sys.argv[1]
    html, total = instrument(open(path, errors="replace").read())
    fd, tmp = tempfile.mkstemp(suffix=".html", dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w") as f:
        f.write(html)
    try:
        p = subprocess.run(
            [CHROME, "--headless", "--disable-gpu", "--no-sandbox",
             "--virtual-time-budget=8000", "--enable-logging=stderr",
             "--v=0", "--dump-dom", "file://" + os.path.abspath(tmp)],
            capture_output=True, text=True, timeout=180)
        log = p.stderr
    except subprocess.TimeoutExpired:
        print("TIMEOUT")
        return 2
    finally:
        os.unlink(tmp)

    survived = set(int(m) for m in re.findall(r'"SURVIVE (\d+)"', log))
    survived |= set(int(m) for m in re.findall(r"SURVIVE (\d+)", log))
    print("%s (chromium oracle)" % path)
    print("SCRIPTS %d  SURVIVED %d  DIED %d"
          % (total, len(survived), total - len(survived)))
    dead = [i for i in range(total) if i not in survived]
    if dead:
        print("DEAD: %s" % " ".join(str(i) for i in dead))
    return 0


if __name__ == "__main__":
    sys.exit(main())
