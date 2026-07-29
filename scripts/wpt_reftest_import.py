#!/usr/bin/env python3
"""wpt_reftest_import.py -- import a PINNED SUBSET of WPT *REFTESTS* into tests/wpt/.

WHY THIS EXISTS
---------------
scripts/wpt_import.py imports only testharness.js tests -- the ones that
self-report PASS/FAIL over console.log. It SKIPS reftests with the comment
"reftests need pixel comparison, which is framediff_gfx_all.sh's job". That was
wrong twice over:

  * framediff_gfx_all.sh renders TEN corpus pages and scores them against
    Chromium/Firefox screenshots. It is a *parity* instrument, not a
    conformance suite. "Its job" described work nobody was doing.
  * css/CSS2 alone holds 11,318 test-shaped files, 6,265 of them carrying a
    rel=match/mismatch link. Skipping them excluded the single largest body of
    external evidence about whether our layout engine is correct. A browser
    meant to be an OS's primary browser has to pass CSS reftests.

THE REFTEST MODEL (what we implement)
-------------------------------------
A reftest is a pair of documents plus a relationship, declared in the TEST:

    <link rel="match"    href="foo-ref.html">   -- must render IDENTICALLY
    <link rel="mismatch" href="foo-notref.html"> -- must render DIFFERENTLY

Both documents are rendered by the SAME engine, so the pass condition is
engine-internal: no cross-engine font or anti-aliasing question arises.

REFERENCE CHAINS. A reference may itself carry rel="match" links (upstream uses
this to share one canonical rendering between many tests). Upstream semantics:
the test passes if it matches its reference OR any document reachable through
that reference's own match links. We resolve the chain at IMPORT time, copy
every document in it, and record the full chain in the manifest so the runner
can try each candidate. Chains are cycle-guarded and depth-capped.

MULTIPLE REFERENCES. A test may declare several rel="match" links; upstream
treats them as alternatives (any one matching is a pass). Recorded as such.

WHAT IS IMPORTED, AND WHY THAT SLICE
------------------------------------
Round 1 imports the CSS2 *normal flow and floats* family:

    css/CSS2/normal-flow  css/CSS2/floats  css/CSS2/floats-clear
    css/CSS2/box-display

That is the CSS2 box model: how blocks stack, how floats displace them, how
clearance works, what `display` does to a box. It is the layer every other
CSS feature is built on top of, our own layout engine's core, and it is
self-contained (no compositor, no media, no network). Getting the LANE working
end to end on a coherent 171-file slice is the deliverable; volume comes next.

NEVER EDIT A VENDORED TEST OR REFERENCE. Exclusions are recorded, with a
reason, in tests/wpt/REFTEST_EXCLUSIONS.md. "We fail it" is never a reason --
a failing external test is the entire point of importing an external suite.

SCALING TO THE FULL css/CSS2 (measured, not guessed)
----------------------------------------------------
css/CSS2 holds 11,318 test-shaped files; 6,265 carry a rel=match/mismatch link.
What actually gates coverage is NOT runner throughput -- the pixel backend
renders in 13 ms and the lane needs ~3 renders per pair, so all 6,265 would run
in about FOUR MINUTES. Two capability walls gate it instead, in this order:

  1. AN XML PARSE MODE -- worth ~5,300 reftests, by far the biggest lever.
     10,501 of the 11,318 files are .xht, served as application/xhtml+xml. An
     HTML tokenizer mis-parses `<style><![CDATA[...]]></style>`, self-closing
     `<div/>` and the XHTML DTD doctype, so the pixels are not an observation of
     the test. Estimated cost: an XML tokenizer feeding the existing tree
     builder (well-formed input only -- XHTML has no error recovery to
     emulate, which makes it much smaller than the HTML parser it sits beside).

  2. @font-face / THE AHEM FONT -- worth several hundred reftests, and it
     compounds: Ahem is how reftests make text geometry pixel-predictable, so
     every text-layout area (linebox, text, bidi-text, fonts: ~800 reftests
     between them) leans on it. lib/htmlpaint already loads TrueType
     (htmlpaint_load_ttf), so this is a CSS-plumbing job, not a rasterizer one.

  3. AREA-BY-AREA IMPORT thereafter is a one-line change to AREAS below. The
     honest sequencing is to import an area only once the lane can say
     something about it, because 500 uniform FAILs teach less than 50 that
     bisect a specific bug -- and every import grows the NONDISCRIMINATING
     bucket, which is the number to watch, not the ratio.

Before ANY of that, the two systemic box-model defects the round-1 baseline
exposed are worth more than volume: on a bare `div{width:Npx;height:Npx}`,
computed width overshoots by exactly +8px at every size and computed height is
quantized upward to whole text rows (50->54, 100->108, 200->234, 300->342).
Nearly every CSS2 box-model reftest fails on those two before reaching its own
subject matter, so 6,265 imported tests today would mostly measure the same two
bugs 6,265 times.

To refresh:
    python3 scripts/wpt_reftest_import.py --wpt /path/to/wpt-checkout
"""

import argparse
import fnmatch
import html
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEST = os.path.join(ROOT, "tests", "wpt")

# Same pin as scripts/wpt_import.py. The two importers MUST agree: one vendored
# tree, one revision, one comparable score over time.
PINNED_SHA = "8ab228c702a6cfeacb3c986b06a16a744b493a8d"

# Directories imported this round. See the module docstring for the rationale.
AREAS = [
    "css/CSS2/normal-flow",
    "css/CSS2/floats",
    "css/CSS2/floats-clear",
    "css/CSS2/box-display",
]

MAX_CHAIN_DEPTH = 6

# ---------------------------------------------------------------------------
# EXCLUSIONS. Each says what our RUNNER CANNOT OBSERVE. Never "we fail it".
# ---------------------------------------------------------------------------
XML_REASON = (
    "XHTML (.xht/.xhtml). WPT serves these as application/xhtml+xml and they "
    "must be parsed by an XML parser: `<style><![CDATA[ ... ]]></style>`, "
    "self-closing `<div/>`, and the XHTML DTD doctype all mean something "
    "different to an HTML tokenizer. Our engine has ONE parser and it is the "
    "HTML one, so an .xht document is not mis-rendered -- it is mis-PARSED, "
    "and the resulting pixels are not an observation of the test. This is the "
    "single biggest lever on CSS2 coverage: 10,501 of the 11,318 files under "
    "css/CSS2 are .xht. Re-import the moment an XML parse mode exists."
)

AHEM_REASON = (
    "Requires the Ahem test font, pulled in via `@font-face` from WPT's "
    "/fonts/ tree. Ahem is a metrics-exact font (every glyph a solid em "
    "square) that reftests use to make text geometry pixel-predictable. Our "
    "engine has no webfont loader, so both documents fall back to DejaVu and "
    "the comparison measures our fallback metrics rather than the test's "
    "assertion -- it can pass or fail for reasons the test is not about. "
    "Re-import when @font-face loading lands."
)

EXCLUDE_GLOBS = [
    ("*.tentative.html",
     "Tentative: tests a spec proposal that has not stabilised. Scoring "
     "against it would make the number move for reasons unrelated to our "
     "engine."),
    ("*-manual.html", "Requires a human to perform the interaction."),
    ("*.optional-manual.html", "Requires a human to perform the interaction."),
    ("*.sub.html",
     "Server-side substitution (.sub) -- the {{host}}/{{ports}} placeholders "
     "are expanded by the wptserve HTTP server, which we do not run. The file "
     "on disk is not a valid test."),
]

# NOT-A-TEST filters. These are about SELECTION, not observability: the file is
# perfectly renderable, it just is not a test in its own right. They must never
# be applied when resolving a reference -- a reference living in
# `css/reference/` is exactly where a shared reference is SUPPOSED to live. (An
# earlier revision of this importer applied them to both and silently dropped
# 47 otherwise-runnable tests whose reference was shared.)
NOT_A_TEST_DIRS = [
    ("/support/", "Support fixtures loaded BY tests; not tests themselves."),
    ("/reference/", "Reference documents, imported as part of a test's chain."),
    ("/crashtests/",
     "Crashtests assert only 'the engine did not crash'; they carry no "
     "reference and no assertion, so they are not reftests."),
]

NOT_A_TEST_GLOBS = [
    ("*-ref.html", "Reference file for a reftest, not a test itself."),
    ("*-ref[0-9].html", "Reference file for a reftest, not a test itself."),
    ("*-notref.html",
     "The 'must NOT look like this' document of a mismatch reftest, not a "
     "test itself."),
    ("*-notref[0-9].html",
     "The 'must NOT look like this' document of a mismatch reftest, not a "
     "test itself."),
]

EXCLUDE_IF_REFERENCES = [
    ("/common/",
     "Pulls shared fixtures from WPT's /common/ tree, which frequently assume "
     "the wptserve HTTP origin (cross-origin frames, redirects, headers)."),
    ("testdriver.js",
     "testdriver.js injects trusted input events through the browser's "
     "automation protocol. Our headless host harness has no driver back-end, "
     "so these tests hang rather than fail -- an unobservable result."),
    ("Ahem", AHEM_REASON),
    ("<iframe",
     "Nested browsing context: the engine has one document per render and no "
     "frame tree, so the sub-document never renders at all."),
    ("<object",
     "<object> embeds an external resource through a plugin-style fallback "
     "chain the engine does not implement."),
]

LINK_RE = re.compile(
    rb"""<link\b([^>]*)>""", re.IGNORECASE)
ATTR_RE = re.compile(
    rb"""\b([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""")
SCRIPT_SRC_RE = re.compile(
    rb"""<script\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""",
    re.IGNORECASE)
IMG_SRC_RE = re.compile(
    rb"""<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""",
    re.IGNORECASE)


def _attrs(blob):
    out = {}
    for m in ATTR_RE.finditer(blob):
        val = m.group(2) or m.group(3) or m.group(4) or b""
        out[m.group(1).decode("ascii", "replace").lower()] = html.unescape(
            val.decode("utf-8", "replace"))
    return out


def resolve(rel, href):
    """Resolve `href` (as written in document `rel`) to a WPT-root-relative path."""
    href = href.split("?")[0].split("#")[0]
    if not href or "://" in href or href.startswith("//"):
        return None
    if href.startswith("/"):
        target = href.lstrip("/")
    else:
        target = os.path.normpath(
            os.path.join(os.path.dirname(rel), href)).replace(os.sep, "/")
    return None if target.startswith("..") else target


def read(wpt, rel):
    try:
        return open(os.path.join(wpt, rel), "rb").read()
    except OSError:
        return None


def ref_links(wpt, rel, data=None):
    """[(kind, target_rel)] for rel=match / rel=mismatch links in document `rel`."""
    if data is None:
        data = read(wpt, rel)
    if data is None:
        return []
    out = []
    for m in LINK_RE.finditer(data):
        a = _attrs(m.group(1))
        kind = (a.get("rel") or "").strip().lower()
        if kind not in ("match", "mismatch"):
            continue
        target = resolve(rel, a.get("href") or "")
        if target:
            out.append((kind, target))
    return out


def support_of(wpt, rel):
    """Local files document `rel` loads: <script src>, <link rel=stylesheet>, <img src>."""
    data = read(wpt, rel)
    if data is None:
        return []
    out = []
    for regex in (SCRIPT_SRC_RE, IMG_SRC_RE):
        for m in regex.finditer(data):
            raw = (m.group(1) or m.group(2) or m.group(3) or b"").decode(
                "utf-8", "replace")
            t = resolve(rel, html.unescape(raw))
            if t:
                out.append(t)
    for m in LINK_RE.finditer(data):
        a = _attrs(m.group(1))
        if "stylesheet" not in (a.get("rel") or "").lower():
            continue
        t = resolve(rel, a.get("href") or "")
        if t:
            out.append(t)
    return [t for t in out if os.path.isfile(os.path.join(wpt, t))]


def is_xml(rel):
    return rel.endswith((".xht", ".xhtml", ".xml", ".svg"))


def not_a_test(rel):
    """(kind, reason) if `rel` is renderable but is not a TEST in its own right."""
    base = os.path.basename(rel)
    for part, reason in NOT_A_TEST_DIRS:
        if part in "/" + rel:
            return "dir:" + part, reason
    for glob, reason in NOT_A_TEST_GLOBS:
        if fnmatch.fnmatch(base, glob):
            return "glob:" + glob, reason
    return None, None


def excluded_for(wpt, rel, data=None):
    """(kind, reason) if document `rel` cannot be OBSERVED by our runner.

    Observability ONLY. Applies equally to a test and to a reference; see
    not_a_test() for the selection-side filters.
    """
    if is_xml(rel):
        return "xml:" + os.path.splitext(rel)[1], XML_REASON
    base = os.path.basename(rel)
    for glob, reason in EXCLUDE_GLOBS:
        if fnmatch.fnmatch(base, glob):
            return "glob:" + glob, reason
    if data is None:
        data = read(wpt, rel)
    if data is None:
        return "missing", ("Referenced document is not present in the "
                           "checkout at this pin.")
    for needle, reason in EXCLUDE_IF_REFERENCES:
        if needle.encode() in data:
            return "ref:" + needle, reason
    return None, None


def chain_for(wpt, test):
    """Resolve a test's reference chain.

    Returns (kind, [candidate_rel, ...], all_docs, problem) where `kind` is
    "match" or "mismatch". Upstream semantics: several rel=match links are
    ALTERNATIVES, and a reference's own rel=match links extend the set of
    acceptable renderings. `all_docs` is every document that must be vendored.
    """
    links = ref_links(wpt, test)
    if not links:
        return None, [], set(), "no rel=match/mismatch link"
    kinds = {k for k, _ in links}
    if len(kinds) > 1:
        # A test declaring both match and mismatch needs both to hold; we do
        # not model the conjunction yet, so say so rather than guess.
        return None, [], set(), "declares both match and mismatch"
    kind = kinds.pop()

    candidates, docs, seen = [], set(), set()
    queue = [(t, 0) for _, t in links]
    while queue:
        target, depth = queue.pop(0)
        if target in seen or depth > MAX_CHAIN_DEPTH:
            continue
        seen.add(target)
        data = read(wpt, target)
        if data is None:
            return None, [], docs, "reference missing: " + target
        k, reason = excluded_for(wpt, target, data)
        if k:
            return None, [], docs, "reference unobservable (%s): %s" % (k, target)
        candidates.append(target)
        docs.add(target)
        # Chain: this reference's OWN match links are further acceptable
        # renderings of the same thing. mismatch links inside a reference are
        # upstream's way of asserting the reference is not degenerate; they are
        # not alternatives for us, so they are not followed.
        for k2, t2 in ref_links(wpt, target, data):
            if k2 == "match":
                queue.append((t2, depth + 1))
    return kind, candidates, docs, None


def collect(wpt):
    tests, excluded = [], []
    for area in AREAS:
        adir = os.path.join(wpt, area)
        if not os.path.isdir(adir):
            print("[reftest-import] WARNING: area missing: %s" % area,
                  file=sys.stderr)
            continue
        for dirpath, dirnames, filenames in os.walk(adir):
            dirnames.sort()
            for fn in sorted(filenames):
                if not fn.endswith((".html", ".htm", ".xht", ".xhtml")):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, fn),
                                      wpt).replace(os.sep, "/")
                data = read(wpt, rel)
                if data is None:
                    continue
                if b'rel="match"' not in data and b'rel="mismatch"' not in data \
                        and b"rel='match'" not in data \
                        and b"rel='mismatch'" not in data:
                    continue          # not a reftest
                k, reason = not_a_test(rel)
                if k:
                    continue          # silently skipped: not an exclusion
                k, reason = excluded_for(wpt, rel, data)
                if k:
                    excluded.append((rel, k, reason))
                    continue
                kind, cands, docs, problem = chain_for(wpt, rel)
                if problem:
                    if problem.startswith("reference unobservable"):
                        rk = problem.split("(")[1].split(")")[0]
                        rreason = None
                        if rk.startswith("xml:"):
                            rreason = XML_REASON
                        for needle, rsn in EXCLUDE_IF_REFERENCES:
                            if rk == "ref:" + needle:
                                rreason = rsn
                        for g, rsn in EXCLUDE_GLOBS:
                            if rk == "glob:" + g:
                                rreason = rsn
                        excluded.append((rel, "chain-" + rk,
                                         "The test itself is observable, but its "
                                         "REFERENCE is not, so the pair cannot be "
                                         "compared. " + (rreason or problem)))
                    else:
                        excluded.append((rel, "chain:" + problem.split(":")[0],
                                         "Reference chain could not be resolved: "
                                         + problem))
                    continue
                tests.append((rel, kind, cands, docs))
    return tests, excluded


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wpt", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    wpt = os.path.abspath(args.wpt)

    sha = subprocess.run(["git", "-C", wpt, "rev-parse", "HEAD"],
                         capture_output=True, text=True).stdout.strip()
    if sha and sha != PINNED_SHA:
        print("[reftest-import] ERROR: checkout is at %s but PINNED_SHA is %s."
              % (sha, PINNED_SHA), file=sys.stderr)
        return 2

    tests, excluded = collect(wpt)

    copy = set()
    for rel, kind, cands, docs in tests:
        copy.add(rel)
        copy |= docs
    # transitive support material for every vendored document
    queue, seen = list(copy), set(copy)
    while queue:
        rel = queue.pop()
        for dep in support_of(wpt, rel):
            if dep in seen:
                continue
            seen.add(dep)
            copy.add(dep)
            if dep.endswith((".html", ".htm", ".css", ".js")):
                queue.append(dep)

    print("[reftest-import] pin       %s" % PINNED_SHA)
    print("[reftest-import] reftests  %d" % len(tests))
    print("[reftest-import] documents %d (tests + refs + support)" % len(copy))
    print("[reftest-import] excluded  %d" % len(excluded))
    nmis = sum(1 for _, k, _, _ in tests if k == "mismatch")
    nchain = sum(1 for _, _, c, _ in tests if len(c) > 1)
    print("[reftest-import]   mismatch=%d  multi-candidate chains=%d"
          % (nmis, nchain))
    if args.dry_run:
        return 0

    for rel in sorted(copy):
        src = os.path.join(wpt, rel)
        dst = os.path.join(DEST, "tests", rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)

    man = os.path.join(DEST, "REFTEST_MANIFEST.txt")
    with open(man, "w") as f:
        f.write(
            "# WPT REFTESTS vendored at %s.\n"
            "# Generated by scripts/wpt_reftest_import.py; do not hand-edit.\n"
            "# TAB-separated:  <test>  <match|mismatch>  <ref>[,<ref>...]\n"
            "# Several refs = ALTERNATIVES (upstream reference-chain semantics):\n"
            "# for `match`, the test passes if it renders identically to ANY of\n"
            "# them; for `mismatch`, it must differ from ALL of them.\n" % PINNED_SHA)
        for rel, kind, cands, _ in sorted(tests):
            f.write("%s\t%s\t%s\n" % (rel, kind, ",".join(cands)))

    exc = os.path.join(DEST, "REFTEST_EXCLUSIONS.md")
    with open(exc, "w") as f:
        f.write("# WPT reftest import exclusions\n\n"
                "Generated by `scripts/wpt_reftest_import.py` at pin `%s`.\n\n"
                "An exclusion says what our RUNNER cannot observe. \"We fail\n"
                "it\" is never a valid reason -- a failing external test is the\n"
                "whole point of importing an external suite. Every entry below\n"
                "names a missing capability and the condition for re-import.\n\n"
                "See `EXCLUSIONS.md` for the testharness.js lane.\n\n"
                % PINNED_SHA)
        by = {}
        for rel, kind, reason in excluded:
            by.setdefault((kind, reason), []).append(rel)
        for (kind, reason), rels in sorted(by.items(), key=lambda kv: -len(kv[1])):
            f.write("## `%s` -- %d file(s)\n\n%s\n\n" % (kind, len(rels), reason))
            for r in sorted(rels)[:12]:
                f.write("- `%s`\n" % r)
            if len(rels) > 12:
                f.write("- ... and %d more\n" % (len(rels) - 12))
            f.write("\n")

    print("[reftest-import] wrote %s" % man)
    print("[reftest-import] wrote %s" % exc)
    return 0


if __name__ == "__main__":
    sys.exit(main())
