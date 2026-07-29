#!/usr/bin/env python3
"""wpt_reftest_run.py -- run the vendored WPT REFTESTS against the native engine.

    python3 scripts/wpt_reftest_run.py --all --jsonl build/host/wpt_reftest.jsonl
    python3 scripts/wpt_reftest_run.py css/CSS2/floats/zero-width-floats.html
    python3 scripts/wpt_reftest_run.py --selftest

WHAT A REFTEST IS
-----------------
A test document plus a reference document plus a relationship:

    <link rel="match"    href="ref.html">    -- must render IDENTICALLY
    <link rel="mismatch" href="notref.html"> -- must render DIFFERENTLY

Crucially BOTH documents go through OUR renderer. That is what makes reftests
usable by an engine whose fonts and anti-aliasing differ from Chromium's: the
comparison is engine-internal, so there is no cross-engine font question and
therefore no need for a fuzz tolerance. We compare EXACTLY -- byte-for-byte on
the normalized framebuffer. See TOLERANCE below.

    match     PASS if the test render equals ANY candidate reference.
    mismatch  PASS if the test render differs from EVERY candidate.

Multiple candidates come from upstream's reference-chain semantics, resolved at
import time by scripts/wpt_reftest_import.py and recorded in
tests/wpt/REFTEST_MANIFEST.txt.

VIEWPORT NORMALIZATION
----------------------
`hambrowse_gfx` sizes its canvas to its CONTENT, so a test and its reference
routinely produce canvases of different height even when they agree on every
pixel that matters. Real reftest runners screenshot a FIXED viewport (Chromium's
is 800x600) and compare that. We do the same: both renders are composited
top-left onto a fixed WIDTHxHEIGHT canvas filled with the page background
(white), cropping anything past it. This is a property of the instrument applied
identically to both documents, not a per-test adjustment.

TOLERANCE: NONE, AND WHY THAT IS SAFE
-------------------------------------
Zero. `compare` is `==` on the normalized RGB bytes. This is not optimism, it is
a measured property: the renderer is deterministic (the same document rendered
twice is byte-identical), and both sides of every comparison are rendered by it,
so anti-aliasing, hinting and subpixel placement are IDENTICAL functions of the
same inputs. A tolerance would buy nothing and would turn the suite into a
rubber stamp -- at 6% fuzz, the value framediff uses for CROSS-engine work, a
50x50 misplaced box inside an 800x600 viewport is 0.5% of the frame and would be
waved through. If a future renderer ever becomes non-deterministic, --selftest's
determinism control fails and the lane goes INCONCLUSIVE rather than quietly
loosening.

DISCRIMINATION CONTROL -- THE ANTI-SOFT-GREEN MEASURE
-----------------------------------------------------
A reftest lane on an immature engine has a specific failure mode that upstream
runners do not have to worry about, and it produces FALSE PASSES:

    test: a 50px green float inside a 100px red block
    ref:  a 100px green div
    an engine that IGNORES CSS ENTIRELY renders both as the same bare
    paragraph of prose -- identical -- and the pair reads as PASS.

So for every pair we also render a NEGATIVE CONTROL: the same two documents
with all CSS removed (<style> blocks, style="" attributes, inlined external
stylesheets) and all scripts removed -- i.e. what an engine with no CSS support
at all would see. If those two renders are already identical, then a match
cannot be evidence of anything about CSS, and the pair is reported
NONDISCRIMINATING instead of PASS. Discriminating pairs are the only ones that
enter the score.

This is a NECESSARY condition, not a sufficient one; the Chromium cross-check
(scripts/wpt_reftest_chromium_check.py) is what bounds the residual false-pass
rate empirically.

PREPROCESSING -- AND WHY IT IS NOT TEST EDITING
-----------------------------------------------
Vendored tests and references are read-only and byte-identical to upstream.
Every transform below happens in a temp file, uniformly, for every document,
test and reference alike:

  1. `<link rel="stylesheet" href=...>` -> an inline <style> with the file's
     bytes. The engine has no CSS resource loader; this is exactly what a
     loader would do. Applied to test and reference equally, so it cannot bias
     the comparison.
  2. `<script src=...>` -> an inline <script> with the file's bytes, same
     reason.

Nothing changes a declaration, a selector, or an assertion.

VERDICTS
  PASS              the relationship holds, on a discriminating pair
  FAIL              the relationship does not hold
  NONDISCRIMINATING the pair cannot distinguish a CSS engine from no CSS engine
  ERROR             a document could not be rendered at all

NOT SOFT-GREEN. --selftest drives EIGHT controls through the real pipeline and
exits non-zero unless every one lands on its expected verdict; callers treat
that as INCONCLUSIVE (125), never PASS:

  positive / negative        a discriminating pair that holds, and one that does
                             not -- an always-green comparator dies here
  mismatch-holds / -violated the same for the mismatch relationship
  nondiscriminating          a pair a null engine would pass must NOT score
  determinism               the same document rendered twice is byte-identical;
                             the whole zero-tolerance argument rests on it
  inline css / inline js     an external stylesheet and an external script each
                             CHANGE the render. Zero vendored documents in the
                             round-1 tranche use either (the ones that did were
                             the Ahem tests, and Ahem arrives via a stylesheet),
                             so without these two the loader is untested code on
                             a path the lane depends on the moment @font-face
                             lands -- and a dead loader would present as a wave
                             of engine bugs.
"""

import argparse
import html as htmlmod
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WPT = os.path.join(ROOT, "tests", "wpt")
TESTS = os.path.join(WPT, "tests")
MANIFEST = os.path.join(WPT, "REFTEST_MANIFEST.txt")
GFX_BIN = os.path.join(ROOT, "build", "host", "hambrowse_gfx")

# Chromium's reftest viewport. Ours matches so a cross-check compares like with
# like. The renderer is driven at VIEW_W and the canvas it returns is
# composited top-left onto VIEW_W x VIEW_H of page background.
VIEW_W = 800
VIEW_H = 600
BG = b"\xff\xff\xff"

LINK_RE = re.compile(rb"<link\b([^>]*)>", re.IGNORECASE)
ATTR_RE = re.compile(
    rb"""\b([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""")
SCRIPT_EL_RE = re.compile(rb"<script\b([^>]*)>(.*?)</script\s*>",
                          re.IGNORECASE | re.DOTALL)
SCRIPT_ANY_RE = re.compile(rb"<script\b[^>]*>.*?</script\s*>",
                           re.IGNORECASE | re.DOTALL)
SCRIPT_SELF_RE = re.compile(rb"<script\b[^>]*/?>", re.IGNORECASE)
STYLE_EL_RE = re.compile(rb"<style\b[^>]*>.*?</style\s*>",
                         re.IGNORECASE | re.DOTALL)
STYLE_ATTR_RE = re.compile(
    rb"""\sstyle\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)""", re.IGNORECASE)


def _attrs(blob):
    out = {}
    for m in ATTR_RE.finditer(blob):
        v = m.group(2) or m.group(3) or m.group(4) or b""
        out[m.group(1).decode("ascii", "replace").lower()] = htmlmod.unescape(
            v.decode("utf-8", "replace"))
    return out


def _local(doc_rel, href, root):
    """Resolve `href` as written in `doc_rel` to a real file under `root`.

    `root` is threaded explicitly rather than read off the module-global TESTS:
    Renderer takes a tests_root, and having resource resolution silently ignore
    it made every external stylesheet/script invisible under any root but the
    default -- which is exactly the configuration --selftest runs in.
    """
    href = (href or "").split("?")[0].split("#")[0]
    if not href or "://" in href or href.startswith("//"):
        return None
    t = href.lstrip("/") if href.startswith("/") else os.path.normpath(
        os.path.join(os.path.dirname(doc_rel), href)).replace(os.sep, "/")
    if t.startswith(".."):
        return None
    p = os.path.join(root, t)
    return p if os.path.isfile(p) else None


def inline_resources(doc_rel, data, root=TESTS):
    """Inline <link rel=stylesheet> and <script src>. Uniform, both sides."""
    def sub_link(m):
        a = _attrs(m.group(1))
        if "stylesheet" not in (a.get("rel") or "").lower():
            return m.group(0)
        p = _local(doc_rel, a.get("href"), root)
        if not p:
            return m.group(0)
        try:
            css = open(p, "rb").read()
        except OSError:
            return m.group(0)
        return b"<style>" + css + b"</style>"

    data = LINK_RE.sub(sub_link, data)

    def sub_script(m):
        a = _attrs(m.group(1))
        if not a.get("src"):
            return m.group(0)
        p = _local(doc_rel, a["src"], root)
        if not p:
            return m.group(0)
        try:
            js = open(p, "rb").read()
        except OSError:
            return m.group(0)
        return b"<script>" + js + b"</script>"

    return SCRIPT_EL_RE.sub(sub_script, data)


def strip_css(data):
    """What an engine with NO CSS support would see. Negative control only."""
    data = STYLE_EL_RE.sub(b"", data)
    data = SCRIPT_ANY_RE.sub(b"", data)
    data = SCRIPT_SELF_RE.sub(b"", data)
    data = STYLE_ATTR_RE.sub(b"", data)

    def drop_css_link(m):
        a = _attrs(m.group(1))
        return b"" if "stylesheet" in (a.get("rel") or "").lower() else m.group(0)

    return LINK_RE.sub(drop_css_link, data)


# --------------------------------------------------------------------------
# PPM handling
# --------------------------------------------------------------------------
def parse_ppm(path):
    """(w, h, rgb_bytes) for a binary P6 PPM, or None."""
    try:
        raw = open(path, "rb").read()
    except OSError:
        return None
    if not raw.startswith(b"P6"):
        return None
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(raw) and raw[i:i + 1].isspace():
            i += 1
        if raw[i:i + 1] == b"#":
            while i < len(raw) and raw[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(raw) and not raw[j:j + 1].isspace():
            j += 1
        try:
            fields.append(int(raw[i:j]))
        except ValueError:
            return None
        i = j
    i += 1                                   # single whitespace after maxval
    w, h, maxval = fields
    if maxval != 255:
        return None
    need = w * h * 3
    return (w, h, raw[i:i + need]) if len(raw) - i >= need else None


def viewport(ppm, w=VIEW_W, h=VIEW_H):
    """Composite a render top-left onto a fixed w x h page-background canvas."""
    if ppm is None:
        return None
    sw, sh, px = ppm
    row = BG * w
    out = bytearray(row * h)
    n = min(sw, w) * 3
    for y in range(min(sh, h)):
        out[y * w * 3:y * w * 3 + n] = px[y * sw * 3:y * sw * 3 + n]
    return bytes(out)


WORK_PREFIX = ".hamnix_reftest_"


def sweep_stale(root=TESTS):
    """Remove work files a killed run left inside the vendored tree.

    Renderer writes its preprocessed copy NEXT TO the vendored document so that
    relative <img src> and the engine's base-URL handling still resolve. The
    normal path deletes it in a `finally`, but a SIGKILL does not run one, and
    the leftovers land in a git-TRACKED directory -- so the next reader sees a
    dirty tests/wpt/ and cannot tell vendored content from harness debris.
    """
    n = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.startswith(WORK_PREFIX):
                try:
                    os.unlink(os.path.join(dirpath, fn))
                    n += 1
                except OSError:
                    pass
    return n


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
class Renderer:
    def __init__(self, tmpdir, bin_path=GFX_BIN, tests_root=TESTS):
        self.tmp = tmpdir
        self.bin = bin_path
        self.root = tests_root
        self.n = 0
        self.cache = {}

    def render(self, doc_rel, css=True):
        """Normalized viewport bytes for `doc_rel`, or None on failure."""
        key = (doc_rel, css)
        if key in self.cache:
            return self.cache[key]
        src = os.path.join(self.root, doc_rel)
        try:
            data = open(src, "rb").read()
        except OSError:
            self.cache[key] = None
            return None
        data = inline_resources(doc_rel, data, self.root)
        if not css:
            data = strip_css(data)
        self.n += 1
        # Keep the extension AND the directory: relative <img src> and the
        # engine's own base-URL handling must still resolve.
        work = os.path.join(os.path.dirname(src),
                            "%s%d_%s" % (WORK_PREFIX, self.n,
                                         os.path.basename(src)))
        out = os.path.join(self.tmp, "r%d.ppm" % self.n)
        try:
            with open(work, "wb") as f:
                f.write(data)
            rc = subprocess.run([self.bin, work, out, str(VIEW_W)],
                                capture_output=True, timeout=60)
            got = viewport(parse_ppm(out)) if rc.returncode == 0 else None
        except (OSError, subprocess.SubprocessError):
            got = None
        finally:
            for p in (work, out):
                try:
                    os.unlink(p)
                except OSError:
                    pass
        self.cache[key] = got
        return got


def run_one(rend, test, kind, refs):
    """-> dict record. See VERDICTS in the module docstring."""
    rec = {"test": test, "kind": kind, "refs": refs}
    t = rend.render(test)
    if t is None:
        rec.update(verdict="ERROR", detail="test document did not render")
        return rec
    rendered = {}
    for r in refs:
        rendered[r] = rend.render(r)
        if rendered[r] is None:
            rec.update(verdict="ERROR", detail="reference did not render: " + r)
            return rec

    equal = [r for r in refs if rendered[r] == t]
    holds = bool(equal) if kind == "match" else not equal
    rec["equal_refs"] = equal

    # ---- negative controls (see DISCRIMINATION CONTROL in the docstring) ----
    # (1) null_holds: would an engine with NO CSS support at all also see the
    #     relationship hold? If so, a pass proves nothing about CSS.
    # (2) css_active: did OUR engine's output actually change because of the
    #     CSS in this pair? If not, we passed without applying the CSS.
    t0 = rend.render(test, css=False)
    r0 = [rend.render(r, css=False) for r in refs]
    if t0 is not None and all(x is not None for x in r0):
        eq0 = [refs[i] for i, x in enumerate(r0) if x == t0]
        null_holds = bool(eq0) if kind == "match" else not eq0
        css_active = (t != t0) or any(rendered[r] != r0[i]
                                      for i, r in enumerate(refs))
        rec["null_holds"] = null_holds
        rec["css_active"] = css_active
        if holds and (null_holds or not css_active):
            rec.update(
                verdict="NONDISCRIMINATING",
                detail=("a null engine would also pass" if null_holds
                        else "our render is unchanged by this pair's CSS"))
            return rec
    else:
        rec["null_holds"] = None
        rec["css_active"] = None

    rec["verdict"] = "PASS" if holds else "FAIL"
    return rec


def load_manifest():
    rows = []
    with open(MANIFEST) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            rows.append((parts[0], parts[1],
                         [r for r in parts[2].split(",") if r]))
    return rows


# --------------------------------------------------------------------------
# self-test: prove the instrument reports failure as failure
# --------------------------------------------------------------------------
SELFTEST = {
    # (name, kind, test html, ref html, expected verdict)
    # A GENUINELY discriminating positive: without CSS the test shows an extra
    # paragraph the reference does not have, so a null engine sees them DIFFER
    # and cannot pass by accident. With CSS honoured they must coincide.
    "positive": ("match",
                 "<p>kept</p><style>.gone{display:none}</style>"
                 "<p class=gone>this must not be painted</p>",
                 "<p>kept</p>",
                 "PASS"),
    "negative": ("match",
                 "<style>#a{width:80px;height:40px;background:#008000}</style>"
                 "<div id=a></div>",
                 "<style>div{width:80px;height:40px;background:#ff0000}</style>"
                 "<div></div>",
                 "FAIL"),
    "mismatch-holds": ("mismatch",
                       "<style>#a{width:80px;height:40px;background:#008000}"
                       "</style><div id=a></div>",
                       "<style>div{width:80px;height:40px;background:#ff0000}"
                       "</style><div></div>",
                       "PASS"),
    "mismatch-violated": ("mismatch",
                          "<style>#a{width:80px;height:40px;"
                          "background:#008000}</style><div id=a></div>",
                          "<style>div{width:80px;height:40px;"
                          "background:#008000}</style><div></div>",
                          "FAIL"),
    # Identical prose, no CSS that changes anything -> an engine that ignored
    # CSS would "pass" this too. Must NOT be counted as a PASS.
    "nondiscriminating": ("match",
                          "<p>Test passes if this line appears.</p>",
                          "<p>Test passes if this line appears.</p>",
                          "NONDISCRIMINATING"),
}


def selftest_inliner(root, rend):
    """Prove inline_resources() actually loads external CSS and JS.

    NOT redundant, and specifically NOT covered by the vendored lane: as of the
    round-1 tranche ZERO vendored documents carry a <link rel=stylesheet> or a
    <script src> (the ones that did were the Ahem tests, and Ahem arrives *via*
    a stylesheet, so they are excluded). That makes the inliner untested code on
    a path the lane will depend on the moment @font-face lands or another area
    is imported -- exactly the shape of thing that rots silently and then
    produces a wave of "engine bugs" that are really a dead resource loader.
    Each control must CHANGE the render; a no-op inliner fails it.
    """
    ok = True
    open(os.path.join(root, "ext.css"), "w").write(
        "#box{width:70px;height:35px;background:#0000ff}")
    # backgroundColor, not the `background` shorthand: the engine's CSSOM
    # implements the longhand only, and a control must fail for the reason it
    # names (a dead resource loader) rather than for an unrelated engine gap.
    open(os.path.join(root, "ext.js"), "w").write(
        "document.getElementById('box').style.backgroundColor = '#00ff00';")
    open(os.path.join(root, "il_css.html"), "w").write(
        '<link rel="stylesheet" href="ext.css"><div id=box></div>')
    open(os.path.join(root, "il_js.html"), "w").write(
        '<style>#box{width:70px;height:35px;background:#0000ff}</style>'
        '<div id=box></div><script src="ext.js"></script>')
    for name, what in (("il_css.html", "external CSS"),
                       ("il_js.html", "external JS")):
        raw = open(os.path.join(root, name), "rb").read()
        grew = inline_resources(name, raw, root) != raw
        with_inline = rend.render(name)
        # render the SAME file with the inliner bypassed
        rc = subprocess.run([rend.bin, os.path.join(root, name),
                             os.path.join(rend.tmp, "noinl.ppm"),
                             str(VIEW_W)], capture_output=True)
        without = viewport(parse_ppm(os.path.join(rend.tmp, "noinl.ppm"))) \
            if rc.returncode == 0 else None
        good = grew and with_inline is not None and with_inline != without
        ok = ok and good
        print("[reftest-selftest] %-20s want=%-18s got=%-18s %s"
              % ("inline " + what.split()[1].lower(), "render changes",
                 "changed" if good else "NO EFFECT", "ok" if good else "MISMATCH"))
        if not good:
            print("[reftest-selftest]   %s is not being loaded; documents that "
                  "depend on it\n[reftest-selftest]   would be scored as if the "
                  "resource did not exist." % what)
    return ok


def selftest():
    tmp = tempfile.mkdtemp(prefix="wpt-reftest-selftest-")
    root = os.path.join(tmp, "docs")
    os.makedirs(root)
    ok = True
    try:
        rend = Renderer(tmp, tests_root=root)
        if not os.access(GFX_BIN, os.X_OK):
            print("[reftest-selftest] FAIL: %s not executable" % GFX_BIN)
            return False
        for name, (kind, thtml, rhtml, want) in sorted(SELFTEST.items()):
            tn, rn = "st_%s.html" % name, "st_%s_ref.html" % name
            open(os.path.join(root, tn), "w").write(thtml)
            open(os.path.join(root, rn), "w").write(rhtml)
            rec = run_one(rend, tn, kind, [rn])
            good = rec["verdict"] == want
            ok = ok and good
            print("[reftest-selftest] %-20s want=%-18s got=%-18s %s"
                  % (name, want, rec["verdict"], "ok" if good else "MISMATCH"))

        # determinism control: the whole no-tolerance argument rests on it.
        open(os.path.join(root, "det.html"), "w").write(
            "<style>div{width:33px;height:17px;background:#123456}</style>"
            "<div></div><p>ragged proportional text to exercise the rasterizer</p>")
        a = Renderer(tmp, tests_root=root).render("det.html")
        b = Renderer(tmp, tests_root=root).render("det.html")
        det = a is not None and a == b
        ok = ok and det
        print("[reftest-selftest] %-20s want=%-18s got=%-18s %s"
              % ("determinism", "identical",
                 "identical" if det else "DIVERGED", "ok" if det else "MISMATCH"))
        if not det:
            print("[reftest-selftest]   the renderer is not deterministic, so "
                  "exact comparison is not a valid pass condition.")

        ok = selftest_inliner(root, Renderer(tmp, tests_root=root)) and ok
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("test", nargs="?")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--jsonl")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return 0 if selftest() else 1

    if not os.path.isfile(MANIFEST):
        print("[reftest-run] INCONCLUSIVE: %s absent" % MANIFEST,
              file=sys.stderr)
        return 125
    if not os.access(GFX_BIN, os.X_OK):
        print("[reftest-run] INCONCLUSIVE: %s absent/not executable" % GFX_BIN,
              file=sys.stderr)
        return 125

    rows = load_manifest()
    if args.test:
        rows = [r for r in rows if r[0] == args.test or r[0].endswith(
            "/" + args.test.lstrip("/"))]
        if not rows:
            print("[reftest-run] no such reftest in the manifest: %s" % args.test,
                  file=sys.stderr)
            return 2
    elif not args.all:
        ap.error("give a test path or --all")

    stale = sweep_stale()
    if stale:
        print("[reftest-run] removed %d stale work file(s) from a killed run"
              % stale)

    tmp = tempfile.mkdtemp(prefix="wpt-reftest-")
    counts = {}
    records = []
    try:
        rend = Renderer(tmp)
        for test, kind, refs in rows:
            rec = run_one(rend, test, kind, refs)
            records.append(rec)
            counts[rec["verdict"]] = counts.get(rec["verdict"], 0) + 1
            if not args.quiet:
                print("%-18s %-9s %s" % (rec["verdict"], kind, test))
                if rec.get("detail"):
                    print("    %s" % rec["detail"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        sweep_stale()

    if args.jsonl:
        os.makedirs(os.path.dirname(os.path.abspath(args.jsonl)), exist_ok=True)
        with open(args.jsonl, "w") as f:
            for rec in records:
                f.write(json.dumps(rec, sort_keys=True) + "\n")

    npass = counts.get("PASS", 0)
    nfail = counts.get("FAIL", 0)
    nnd = counts.get("NONDISCRIMINATING", 0)
    nerr = counts.get("ERROR", 0)
    scored = npass + nfail
    print("[reftest-run] %d reftests, %d renders" % (len(records), rend.n))
    print("[reftest-run] PASS %d  FAIL %d  NONDISCRIMINATING %d  ERROR %d"
          % (npass, nfail, nnd, nerr))
    if scored:
        print("[reftest-run] score %d/%d = %.1f%% of DISCRIMINATING pairs"
              % (npass, scored, 100.0 * npass / scored))
    if not records:
        return 125
    return 0


if __name__ == "__main__":
    sys.exit(main())
