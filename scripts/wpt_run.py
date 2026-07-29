#!/usr/bin/env python3
"""wpt_run.py -- run vendored Web Platform Tests against the native engine.

    python3 scripts/wpt_run.py --all                       # whole vendored suite
    python3 scripts/wpt_run.py dom/nodes/Node-nodeName.html # one test, verbose
    python3 scripts/wpt_run.py --area dom --jsonl out.jsonl
    python3 scripts/wpt_run.py --engine chromium --all      # cross-check

WHAT IT MEASURES
----------------
Per-SUBTEST results, not "did the page load". WPT tests are testharness.js
files: each `test(...)`/`async_test(...)` block self-reports PASS/FAIL/TIMEOUT
with a message. tests/wpt/hamnix_testharnessreport.js (our vendor hook) streams
those out over console.log; this script scrapes them off the host driver's
JSLOG lines and scores them.

That distinction is the point. A page-loaded check would have told us "708/708
load fine". The subtest scrape tells us WHICH of ~9,000 assertions fail and why,
which is what a roadmap needs.

PREPROCESSING -- AND WHY IT IS NOT TEST EDITING
-----------------------------------------------
Vendored tests are read-only and byte-identical to upstream. Everything below
happens in a temp file, uniformly, for every test:

  1. RESOURCE LOADING. `build/host/hambrowse_host` executes inline <script>
     bodies only; it has no resource loader, so `<script src=...>` is a no-op.
     We inline the referenced file's bytes. This is what a loader would do.

  2. THE VENDOR HOOK. `/resources/testharnessreport.js` resolves to WPT's
     deliberately-empty vendor stub. We substitute our own implementation of it
     (tests/wpt/hamnix_testharnessreport.js). That file is WPT's designated
     integration point.

  3. SCRIPT COALESCING (mode=combined, the default for our engine).
     ENGINE BUG, worked around here rather than hidden:
     lib/web/dom/canvas.ad:_run_scripts() drains the timer/microtask queue
     between consecutive <script> ELEMENTS instead of after the parse. Per HTML,
     a setTimeout scheduled by script #1 is a task that cannot run until the
     parser is done. Because it does run early, testharness.js's own watchdog
     timer -- armed while testharness.js itself is evaluating -- fires before
     the test's script block has even started. The harness declares TIMEOUT with
     zero tests registered, and every subsequent test() call is silently
     dropped. Measured directly (scripts/wpt_run.py --selftest): a two-script
     page logs S1-start, S1-end, S1-TIMER, S2-runs.

     So we concatenate all script bodies into one block, preserving document
     order. `--mode separate` keeps them apart and is what we hand chromium, so
     the cross-check proves the coalescing is semantically neutral (or names the
     tests where it is not).

  Nothing here changes an assertion, an expectation, or a test's logic.

STATUS CODES (testharness.js)
  subtest: 0 PASS  1 FAIL  2 TIMEOUT  3 NOTRUN  4 PRECONDITION_FAILED
  harness: 0 OK    1 ERROR 2 TIMEOUT  3 PRECONDITION_FAILED
"""

import argparse
import html as htmlmod
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WPT = os.path.join(ROOT, "tests", "wpt")
TESTS = os.path.join(WPT, "tests")
MANIFEST = os.path.join(WPT, "MANIFEST.txt")
REPORT_JS = os.path.join(WPT, "hamnix_testharnessreport.js")
HOST_BIN = os.path.join(ROOT, "build", "host", "hambrowse_host")

SUBTEST_NAMES = {0: "PASS", 1: "FAIL", 2: "TIMEOUT", 3: "NOTRUN",
                 4: "PRECONDITION_FAILED"}
HARNESS_NAMES = {0: "OK", 1: "ERROR", 2: "TIMEOUT", 3: "PRECONDITION_FAILED"}

# Matches a <script> element and splits it into attributes + body. Good enough
# for WPT: no test embeds the literal string "</script" inside a script body.
SCRIPT_RE = re.compile(
    rb"<script(?P<attrs>[^>]*)>(?P<body>.*?)</script\s*>",
    re.IGNORECASE | re.DOTALL)
SRC_ATTR_RE = re.compile(
    rb"""\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""", re.IGNORECASE)
TYPE_ATTR_RE = re.compile(
    rb"""\btype\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""", re.IGNORECASE)

# Script types that are DATA, not code. Coalescing these into the executable
# block would execute them; leave them exactly where they are.
NON_EXEC_TYPES = ("application/json", "application/ld+json", "text/template",
                  "text/plain", "text/html", "text/x-template")


def manifest():
    out = []
    with open(MANIFEST) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line)
    return out


def area_of(rel):
    """Coarse bucket for the score breakdown."""
    parts = rel.split("/")
    if parts[0] == "dom":
        return "dom/" + (parts[1] if len(parts) > 2 else "misc")
    if parts[0] == "html" and len(parts) > 2:
        return "html/" + parts[2]
    if parts[0] == "css" and len(parts) > 1:
        return "css/" + parts[1]
    return parts[0]


def _attr(regex, attrs):
    m = regex.search(attrs)
    if not m:
        return None
    raw = (m.group(1) or m.group(2) or m.group(3) or b"").decode("utf-8", "replace")
    return htmlmod.unescape(raw)


def resolve(rel, src):
    """Resolve a script src (WPT-root-absolute or test-relative) to a real path."""
    src = src.split("?")[0].split("#")[0]
    if not src or "://" in src or src.startswith("//"):
        return None
    if src.startswith("/"):
        target = src.lstrip("/")
    else:
        target = os.path.normpath(os.path.join(os.path.dirname(rel), src))
    path = os.path.join(TESTS, target.replace("/", os.sep))
    return path if os.path.isfile(path) else None


def preprocess(rel, mode="combined", chromium_dump=False):
    """Return (html_bytes, missing_srcs). Never touches the vendored file."""
    src_path = os.path.join(TESTS, rel.replace("/", os.sep))
    doc = open(src_path, "rb").read()
    report = open(REPORT_JS, "rb").read()

    pieces = []        # executable script bodies, in document order
    spans = []         # (start, end, kind) of each <script> element's BODY
    missing = []

    for m in SCRIPT_RE.finditer(doc):
        attrs = m.group("attrs")
        stype = (_attr(TYPE_ATTR_RE, attrs) or "").strip().lower()
        if stype in NON_EXEC_TYPES:
            continue
        if stype == "module":
            # An ES module has its own scope and deferred timing; folding it
            # into a classic script would change both. Left in place.
            continue
        src = _attr(SRC_ATTR_RE, attrs)
        if src is None:
            body = m.group("body")
        else:
            if src.split("?")[0].endswith("/resources/testharnessreport.js"):
                body = report            # our vendor hook
            else:
                path = resolve(rel, src)
                if path is None:
                    missing.append(src)
                    body = b""
                else:
                    body = open(path, "rb").read()
        pieces.append(body)
        spans.append((m.start("body"), m.end("body")))

    if not pieces:
        return doc, missing

    out = bytearray()
    prev = 0
    if mode == "combined":
        # One block: the first script element carries every body, the rest are
        # emptied. The elements themselves stay in the DOM with their original
        # attributes, so document.scripts and querySelector('script[src]') still
        # see what the test wrote.
        blob = b"\n;\n".join(pieces)
        for i, (s, e) in enumerate(spans):
            out += doc[prev:s]
            out += blob if i == 0 else b""
            prev = e
    else:
        # Faithful: each element keeps its own body, src bodies inlined.
        for (s, e), body in zip(spans, pieces):
            out += doc[prev:s]
            out += body
            prev = e
    out += doc[prev:]

    if chromium_dump:
        # chromium --headless --dump-dom hands back markup, not a console
        # stream, so stash the buffered results on the root element.
        out += (b"<script>(function(){function d(){try{"
                b"document.documentElement.setAttribute('data-hamnix-wpt',"
                b"JSON.stringify(HAMNIX_WPT_OUT));}catch(e){}}"
                b"add_completion_callback(d);"
                b"addEventListener('load',function(){setTimeout(d,0);});"
                b"setTimeout(d,2500);})();</script>")
    return bytes(out), missing


# ---------------------------------------------------------------------------
# engines
# ---------------------------------------------------------------------------

def run_hamnix(rel, timeout, mode="combined", keep=None):
    payload, missing = preprocess(rel, mode=mode)
    fd, tmp = tempfile.mkstemp(suffix=".html", prefix="wpt_")
    os.write(fd, payload)
    os.close(fd)
    try:
        try:
            p = subprocess.run([HOST_BIN, tmp, "800"], capture_output=True,
                               timeout=timeout)
            raw = p.stdout.decode("utf-8", "replace")
            rc = p.returncode
        except subprocess.TimeoutExpired:
            return {"harness": None, "harness_note": "engine wall-clock timeout",
                    "subtests": [], "missing": missing, "rc": None}
        if keep:
            open(keep, "wb").write(payload)
        return parse_console(raw, missing, rc)
    finally:
        os.unlink(tmp)


def parse_console(raw, missing, rc):
    subtests, harness, note = [], None, None
    jserr = False
    for line in raw.splitlines():
        if line.startswith("JSERR"):
            jserr = True
            continue
        if not line.startswith("JSLOG "):
            continue
        payload = line[6:]
        if payload.startswith("WPT#RESULT\t"):
            f = payload.split("\t")
            if len(f) >= 3:
                subtests.append({"status": int(f[1]), "name": f[2],
                                 "message": f[3] if len(f) > 3 else ""})
        elif payload.startswith("WPT#STATUS\t"):
            f = payload.split("\t")
            harness = int(f[1])
            note = f[2] if len(f) > 2 else ""
        elif payload.startswith("Uncaught"):
            note = payload
    res = {"harness": harness, "harness_note": note, "subtests": subtests,
           "missing": missing, "rc": rc}
    if harness is None and not subtests:
        res["harness_note"] = note or (
            "no WPT# output: engine produced no harness results"
            + (" (JSERR)" if jserr else ""))
    return res


def run_chromium(rel, timeout, mode="separate", binary="chromium"):
    payload, missing = preprocess(rel, mode=mode, chromium_dump=True)
    d = tempfile.mkdtemp(prefix="wptchrome_")
    tmp = os.path.join(d, "t.html")
    open(tmp, "wb").write(payload)
    try:
        p = subprocess.run(
            [binary, "--headless", "--disable-gpu", "--no-sandbox",
             "--allow-file-access-from-files", "--virtual-time-budget=6000",
             "--dump-dom", "file://" + tmp],
            capture_output=True, timeout=timeout)
        dom = p.stdout.decode("utf-8", "replace")
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return {"harness": None, "harness_note": "chromium: %s" % type(e).__name__,
                "subtests": [], "missing": missing, "rc": None}
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)

    m = re.search(r'data-hamnix-wpt="([^"]*)"', dom)
    if not m:
        return {"harness": None, "harness_note": "chromium: no result attribute",
                "subtests": [], "missing": missing, "rc": p.returncode}
    try:
        rows = json.loads(htmlmod.unescape(m.group(1)))
    except ValueError as e:
        return {"harness": None, "harness_note": "chromium: bad JSON %s" % e,
                "subtests": [], "missing": missing, "rc": p.returncode}
    subtests, harness = [], None
    for row in rows:
        if row[0] == "R":
            subtests.append({"status": row[1], "name": row[2], "message": row[3]})
        elif row[0] == "S":
            harness = row[1]
    return {"harness": harness, "harness_note": "", "subtests": subtests,
            "missing": missing, "rc": p.returncode}


# ---------------------------------------------------------------------------

def selftest():
    """Prove the harness reports FAILURE as failure -- an always-green harness
    is worse than no harness. Runs two synthetic testharness pages through the
    real pipeline: one whose assertions hold, one whose assertions do not."""
    ok = True
    fd, tmp = tempfile.mkstemp(suffix=".html", prefix="wptself_")
    os.close(fd)
    th = open(os.path.join(TESTS, "resources", "testharness.js"), "rb").read()
    rep = open(REPORT_JS, "rb").read()
    for label, body, want_pass, want_fail in [
        ("positive", b"test(function(){assert_equals(1+1,2);},'a');"
                     b"test(function(){assert_true(true);},'b');", 2, 0),
        ("negative", b"test(function(){assert_equals(1,2);},'a');"
                     b"test(function(){throw new Error('boom');},'b');", 0, 2),
    ]:
        with open(tmp, "wb") as f:
            f.write(b"<!doctype html><meta charset=utf-8><body><div id=log></div>"
                    b"<script>\n" + th + b"\n;\n" + rep + b"\n;\n" + body +
                    b"\n</script></body>")
        p = subprocess.run([HOST_BIN, tmp, "800"], capture_output=True, timeout=120)
        r = parse_console(p.stdout.decode("utf-8", "replace"), [], p.returncode)
        got_pass = sum(1 for s in r["subtests"] if s["status"] == 0)
        got_fail = sum(1 for s in r["subtests"] if s["status"] != 0)
        good = (got_pass == want_pass and got_fail == want_fail)
        ok &= good
        print("[wpt-selftest] %-8s want pass=%d fail=%d  got pass=%d fail=%d  %s"
              % (label, want_pass, want_fail, got_pass, got_fail,
                 "OK" if good else "BROKEN"))
    os.unlink(tmp)
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tests", nargs="*", help="test paths relative to tests/wpt/tests")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--area", action="append", default=[],
                    help="substring filter on the test path (repeatable)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--engine", default="hamnix", choices=["hamnix", "chromium"])
    ap.add_argument("--mode", default=None, choices=["combined", "separate"])
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--jsonl", help="write one JSON object per test here")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if args.engine == "hamnix" and not os.path.isfile(HOST_BIN):
        print("[wpt] INCONCLUSIVE: %s absent; build it with "
              "scripts/test_hambrowse_host.sh" % HOST_BIN, file=sys.stderr)
        return 125

    mode = args.mode or ("combined" if args.engine == "hamnix" else "separate")

    sel = list(args.tests)
    if args.all or args.area or not sel:
        sel = manifest()
    if args.area:
        sel = [t for t in sel if any(a in t for a in args.area)]
    if args.limit:
        sel = sel[:args.limit]

    jf = open(args.jsonl, "w") if args.jsonl else None
    tot_p = tot_f = tot_o = 0
    files_ok = files_err = 0
    for i, rel in enumerate(sel):
        if args.engine == "chromium":
            r = run_chromium(rel, args.timeout, mode=mode)
        else:
            r = run_hamnix(rel, args.timeout, mode=mode)
        p = sum(1 for s in r["subtests"] if s["status"] == 0)
        f = sum(1 for s in r["subtests"] if s["status"] == 1)
        o = len(r["subtests"]) - p - f
        tot_p += p; tot_f += f; tot_o += o
        if r["subtests"]:
            files_ok += 1
        else:
            files_err += 1
        rec = {"test": rel, "area": area_of(rel), "engine": args.engine,
               "mode": mode, "harness": r["harness"], "note": r["harness_note"],
               "pass": p, "fail": f, "other": o, "subtests": r["subtests"],
               "missing_src": r["missing"]}
        if jf:
            jf.write(json.dumps(rec) + "\n")
            jf.flush()
        if not args.quiet:
            print("[%4d/%4d] %-6s %-70s pass=%-4d fail=%-4d other=%-4d %s"
                  % (i + 1, len(sel), HARNESS_NAMES.get(r["harness"], "-"),
                     rel[-70:], p, f, o,
                     "" if r["subtests"] else "(" + str(r["harness_note"])[:60] + ")"))
            if len(sel) == 1:
                for s in r["subtests"]:
                    print("    %-6s %s%s" % (SUBTEST_NAMES.get(s["status"], "?"),
                                             s["name"],
                                             "  -- " + s["message"] if s["message"] else ""))
    if jf:
        jf.close()
    tot = tot_p + tot_f + tot_o
    print("\n[wpt] engine=%s mode=%s files=%d (with results %d, no results %d)"
          % (args.engine, mode, len(sel), files_ok, files_err))
    print("[wpt] subtests=%d  PASS=%d  FAIL=%d  OTHER=%d  score=%.2f%%"
          % (tot, tot_p, tot_f, tot_o, 100.0 * tot_p / tot if tot else 0.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
