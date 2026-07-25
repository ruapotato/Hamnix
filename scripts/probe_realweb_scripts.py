#!/usr/bin/env python3
"""scripts/probe_realweb_scripts.py — split a real-site fixture into its
individual <script> blocks and run EACH through the hambrowse JS engine alone,
so a page-wide "JSERR SyntaxError" can be attributed to a specific bundle, then
bisected down to the offending construct.

Usage: probe_realweb_scripts.py <fixture.html> [--bisect N]
  (no flag)   report per-script PASS/FAIL + the engine's error message
  --bisect N  binary-chop script #N by lines to find the first failing prefix
"""
import re
import subprocess
import sys
import tempfile
import os

BIN = "build/host/hambrowse_probe_host"


def run_js(src):
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write("<!doctype html><html><body><script>\n")
        f.write(src.replace("</script", "<\\/script"))
        f.write("\n</script></body></html>")
        p = f.name
    try:
        out = subprocess.run([BIN, p, "1024"], capture_output=True, text=True,
                             timeout=300).stdout
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    finally:
        os.unlink(p)
    for line in out.splitlines():
        if line.startswith("JSERR "):
            return line[6:]
    return None


def scripts_of(path):
    html = open(path, errors="replace").read()
    out = []
    for m in re.finditer(r"<script\b([^>]*)>(.*?)</script\s*>", html, re.I | re.S):
        attrs, body = m.group(1), m.group(2)
        if re.search(r"\bsrc\s*=", attrs, re.I):
            continue
        if body.strip():
            out.append((attrs.strip(), body))
    return out


def main():
    path = sys.argv[1]
    ss = scripts_of(path)
    if "--bisect" in sys.argv:
        n = int(sys.argv[sys.argv.index("--bisect") + 1])
        lines = ss[n][1].splitlines()
        lo, hi = 0, len(lines)
        # find smallest prefix that already errors
        while lo < hi:
            mid = (lo + hi) // 2
            if run_js("\n".join(lines[: mid + 1])):
                hi = mid
            else:
                lo = mid + 1
        print("first failing prefix ends at line %d of %d" % (lo + 1, len(lines)))
        for i in range(max(0, lo - 2), min(len(lines), lo + 3)):
            mark = ">>" if i == lo else "  "
            print("%s %5d | %s" % (mark, i + 1, lines[i][:300]))
        print("err:", run_js("\n".join(lines[: lo + 1])))
        return
    print("%s: %d inline scripts" % (path, len(ss)))
    for i, (attrs, body) in enumerate(ss):
        err = run_js(body)
        print("  [%2d] %7d B  %-28s  %s"
              % (i, len(body), attrs[:28], "OK" if err is None else "ERR " + err))


if __name__ == "__main__":
    main()
