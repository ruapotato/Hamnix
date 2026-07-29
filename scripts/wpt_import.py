#!/usr/bin/env python3
"""wpt_import.py -- import a PINNED SUBSET of Web Platform Tests into tests/wpt/.

WHY AN EXTERNAL SUITE
---------------------
We have 275 hand-written host gates for the browser. Every one of them encodes
*our* idea of correct. On 2026-07-28 a sweep found 16 of 19 gates in one family
were asserting behaviour Chromium does not have. A suite we did not write --
the same suite Chromium, WebKit and Gecko are scored against -- is the only way
to know where we actually stand, and to give "months of browser work" a number
that goes up.

VENDORED, NOT FETCHED
---------------------
The subset is committed to the tree (tests/wpt/) rather than fetched at gate
time:

  * CI runs with no network guarantee; a fetch-at-gate-time runner would have to
    soft-green or go INCONCLUSIVE on every network hiccup. A vendored subset
    makes the ratchet gate deterministic.
  * The score is only comparable over time if the tests do not move underneath
    it. Pinning to a SHA means a score change is OUR change, never upstream's.
  * A reviewer can see, in the diff, exactly which external tests we claim to
    pass.

The cost is repo bytes. This importer keeps that honest: it copies ONLY the
test files it selects plus the support files those tests actually reference
(transitively, via <script src>), so the vendored tree is a few MB rather than
the ~5 GB of full WPT.

To refresh:  python3 scripts/wpt_import.py --wpt /path/to/wpt-checkout
             (clone: git clone --filter=blob:none https://github.com/web-platform-tests/wpt)

WPT is 3-Clause BSD (see tests/wpt/LICENSE). It is a TEST SUITE, not engine
source -- importing it carries no copyleft obligation, unlike translating
WebCore/JavaScriptCore (LGPL) would.

NEVER EDIT A VENDORED TEST. A test we cannot pass is the entire point of the
exercise. If a test is genuinely inapplicable, add it to EXCLUDE_* below with a
reason -- the reason is written into tests/wpt/EXCLUSIONS.md.
"""

import argparse
import html
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEST = os.path.join(ROOT, "tests", "wpt")

# Pinned upstream revision. Bumping this is a deliberate, reviewable act: it can
# move the baseline score in either direction, so it must never ride along with
# an unrelated change.
PINNED_SHA = "8ab228c702a6cfeacb3c986b06a16a744b493a8d"

# ---------------------------------------------------------------------------
# AREAS -- what we import, and why.
#
# Chosen for (a) things a browser must get right before anything else works,
# and (b) things that can run headlessly with no network stack and no
# compositor. Each entry is a directory under the WPT root.
# ---------------------------------------------------------------------------
AREAS = [
    # Core DOM: nodes, ranges, traversal, events, collections. The foundation
    # every page sits on; also where our engine's structural model is weakest.
    "dom",
    # URL parsing/serialisation. Pure computation, no network -- an honest
    # measure of the URL machinery the fetch layer will eventually need.
    "url",
    # The cascade: specificity, !important, inheritance, @import ordering,
    # all-shorthand, revert. Where "why is this the wrong colour" lives.
    "css/css-cascade",
    # TextDecoder/TextEncoder + document encoding sniffing.
    "encoding",
    # HTML element semantics, restricted to the subdirectories that are
    # testable without plugins, media, or a compositor.
    "html/semantics/text-level-semantics",
    "html/semantics/grouping-content",
    "html/semantics/tabular-data",
    "html/semantics/document-metadata",
    "html/semantics/sections",
    "html/semantics/edits",
    "html/semantics/links",
    "html/semantics/selectors",
    "html/semantics/the-button-element",
    "html/semantics/disabled-elements",
    "html/semantics/obsolete",
]

# ---------------------------------------------------------------------------
# EXCLUSIONS -- every one needs a reason, and the reason is published.
#
# An exclusion is a statement about what our runner CANNOT OBSERVE, never a
# statement about what our engine cannot do. "We fail this" is never a reason.
# ---------------------------------------------------------------------------
EXCLUDE_GLOBS = [
    ("*.sub.html",
     "Server-side substitution (.sub) -- the {{host}}/{{ports}} placeholders are "
     "expanded by the wptserve HTTP server, which we do not run. The file on "
     "disk is not a valid test."),
    ("*.tentative.html",
     "Tentative: tests a spec proposal that has not stabilised. Scoring against "
     "it would make the number move for reasons unrelated to our engine."),
    ("*.worker.html",
     "Requires Web Workers (a second JS realm on its own thread). We have one "
     "realm and no threads in the engine."),
    ("*-ref.html", "Reference file for a reftest, not a test itself."),
    ("*-manual.html", "Requires a human to perform the interaction."),
    ("*.optional-manual.html", "Requires a human to perform the interaction."),
]

# Directory path fragments that are support material, not tests.
EXCLUDE_DIR_PARTS = [
    ("/support/", "Support fixtures loaded BY tests; not tests themselves."),
    ("/resources/", "Support fixtures loaded BY tests; not tests themselves."),
]

# Directory prefixes dropped wholesale.
EXCLUDE_PREFIXES = [
    ("encoding/legacy-mb-japanese",
     "~2,900 machine-generated single-codepoint tests for legacy Japanese "
     "multibyte encodings. Keeping them would let one unimplemented feature "
     "(legacy CJK decoders) swamp the total and hide movement everywhere else. "
     "Excluded for SCORE HYGIENE, not difficulty -- re-import when we have "
     "legacy decoders and want to measure them."),
    ("encoding/legacy-mb-korean",
     "As legacy-mb-japanese: machine-generated bulk table tests."),
    ("encoding/legacy-mb-tchinese",
     "As legacy-mb-japanese: machine-generated bulk table tests."),
    ("encoding/legacy-mb-schinese",
     "As legacy-mb-japanese. Kept in the first import by oversight and measured: "
     "gb18030-encoder.html alone contributed 254 subtests -- 6% of the entire "
     "suite from ONE machine-generated codepoint table. Excluded for the same "
     "score-hygiene reason as its three sibling directories, so encoding/ "
     "measures the TextDecoder/TextEncoder API rather than CJK table coverage."),
    ("encoding/streams",
     "Requires the Streams API (ReadableStream/TransformStream), which the "
     "engine does not implement and which is a separate spec from encoding."),
]

# Tests that pull in harness infrastructure we cannot drive.
EXCLUDE_IF_REFERENCES = [
    ("testdriver.js",
     "testdriver.js injects trusted input events (real key/mouse) through the "
     "browser's automation protocol. Our headless host harness has no driver "
     "back-end, so these tests hang rather than fail -- an unobservable result, "
     "not a failing one."),
    ("idlharness.js",
     "idlharness.js validates interfaces against the spec's .idl files, which "
     "are fetched over HTTP at runtime from /interfaces/. No network."),
    ("/common/",
     "Pulls shared fixtures from WPT's /common/ tree, which frequently assume "
     "the wptserve HTTP origin (cross-origin frames, redirects, headers)."),
]

SCRIPT_SRC_RE = re.compile(
    rb"""<script\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))""",
    re.IGNORECASE)


def is_excluded(rel, text):
    """Return (reason, kind) if `rel` must not be imported, else (None, None)."""
    import fnmatch
    base = os.path.basename(rel)
    for pref, reason in EXCLUDE_PREFIXES:
        if rel == pref or rel.startswith(pref + "/"):
            return reason, "prefix:" + pref
    for part, reason in EXCLUDE_DIR_PARTS:
        if part in "/" + rel:
            return reason, "dir:" + part
    for glob, reason in EXCLUDE_GLOBS:
        if fnmatch.fnmatch(base, glob):
            return reason, "glob:" + glob
    for needle, reason in EXCLUDE_IF_REFERENCES:
        if needle.encode() in text:
            return reason, "ref:" + needle
    return None, None


def collect(wpt):
    """Select tests; return (selected, excluded) as lists of (rel, reason/kind)."""
    selected, excluded = [], []
    for area in AREAS:
        adir = os.path.join(wpt, area)
        if not os.path.isdir(adir):
            print("[wpt-import] WARNING: area missing in checkout: %s" % area,
                  file=sys.stderr)
            continue
        for dirpath, dirnames, filenames in os.walk(adir):
            dirnames.sort()
            for fn in sorted(filenames):
                if not fn.endswith(".html") and not fn.endswith(".htm"):
                    continue
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, wpt).replace(os.sep, "/")
                try:
                    text = open(full, "rb").read()
                except OSError:
                    continue
                # Only testharness.js-based tests: they self-report per-assertion
                # results. Reftests need pixel comparison against a reference
                # rendering, which is framediff_gfx_all.sh's job, not this one.
                if b"resources/testharness.js" not in text:
                    continue
                reason, kind = is_excluded(rel, text)
                if reason:
                    excluded.append((rel, kind, reason))
                else:
                    selected.append(rel)
    return selected, excluded


def referenced_scripts(wpt, rel):
    """Local <script src> targets of a test, resolved to WPT-root-relative paths."""
    out = []
    try:
        data = open(os.path.join(wpt, rel), "rb").read()
    except OSError:
        return out
    for m in SCRIPT_SRC_RE.finditer(data):
        raw = (m.group(1) or m.group(2) or m.group(3) or b"").decode(
            "utf-8", "replace")
        src = html.unescape(raw).split("?")[0].split("#")[0]
        if not src or "://" in src or src.startswith("//"):
            continue
        if src.startswith("/"):
            target = src.lstrip("/")
        else:
            target = os.path.normpath(
                os.path.join(os.path.dirname(rel), src)).replace(os.sep, "/")
        if target.startswith(".."):
            continue
        out.append(target)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wpt", required=True, help="path to a WPT checkout")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    wpt = os.path.abspath(args.wpt)

    sha = subprocess.run(["git", "-C", wpt, "rev-parse", "HEAD"],
                         capture_output=True, text=True).stdout.strip()
    if sha and sha != PINNED_SHA:
        print("[wpt-import] ERROR: checkout is at %s but PINNED_SHA is %s.\n"
              "             Check out the pin, or bump PINNED_SHA deliberately "
              "(it moves the score)." % (sha, PINNED_SHA), file=sys.stderr)
        return 2

    selected, excluded = collect(wpt)

    # Transitively pull in the support scripts the selected tests reference, so
    # the vendored tree is self-contained without copying whole resource dirs.
    support, queue, seen = set(), list(selected), set(selected)
    while queue:
        rel = queue.pop()
        for dep in referenced_scripts(wpt, rel):
            if dep in seen or not os.path.isfile(os.path.join(wpt, dep)):
                continue
            seen.add(dep)
            support.add(dep)
            if dep.endswith((".html", ".js")):
                queue.append(dep)

    print("[wpt-import] pin      %s" % PINNED_SHA)
    print("[wpt-import] selected %d tests" % len(selected))
    print("[wpt-import] support  %d files" % len(support))
    print("[wpt-import] excluded %d files" % len(excluded))
    if args.dry_run:
        return 0

    if os.path.isdir(os.path.join(DEST, "tests")):
        shutil.rmtree(os.path.join(DEST, "tests"))
    for rel in sorted(set(selected) | support):
        src = os.path.join(wpt, rel)
        dst = os.path.join(DEST, "tests", rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)

    for lic in ("LICENSE.md",):
        if os.path.isfile(os.path.join(wpt, lic)):
            shutil.copyfile(os.path.join(wpt, lic), os.path.join(DEST, "LICENSE"))

    with open(os.path.join(DEST, "MANIFEST.txt"), "w") as f:
        f.write("# WPT tests vendored at %s -- one path per line, sorted.\n"
                "# Generated by scripts/wpt_import.py; do not hand-edit.\n" % PINNED_SHA)
        for rel in sorted(selected):
            f.write(rel + "\n")

    with open(os.path.join(DEST, "EXCLUSIONS.md"), "w") as f:
        f.write("# WPT import exclusions\n\n"
                "Generated by `scripts/wpt_import.py` at pin `%s`.\n\n"
                "An exclusion says what our RUNNER cannot observe. \"We fail it\"\n"
                "is never a valid reason -- a failing external test is the whole\n"
                "point of importing an external suite.\n\n" % PINNED_SHA)
        by_kind = {}
        for rel, kind, reason in excluded:
            by_kind.setdefault((kind, reason), []).append(rel)
        for (kind, reason), rels in sorted(by_kind.items()):
            f.write("## `%s` -- %d file(s)\n\n%s\n\n" % (kind, len(rels), reason))
            for r in sorted(rels)[:12]:
                f.write("- `%s`\n" % r)
            if len(rels) > 12:
                f.write("- ... and %d more\n" % (len(rels) - 12))
            f.write("\n")

    print("[wpt-import] wrote %s" % os.path.join(DEST, "tests"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
