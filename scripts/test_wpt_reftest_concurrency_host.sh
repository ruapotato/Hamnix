#!/usr/bin/env bash
# scripts/test_wpt_reftest_concurrency_host.sh — QEMU-FREE gate on the property
# that TWO REFTEST RUNS AT ONCE DO NOT CORRUPT EACH OTHER.
#
# WHY THIS GATE EXISTS
# ====================
# scripts/wpt_reftest_run.py renders each document by writing a preprocessed
# copy NEXT TO the vendored original — it has to, because 565 vendored documents
# carry a relative resource reference (`../support/green.png`) and the engine
# resolves it against the file's own directory. Until 2026-07-30 that copy was
# named `.hamnix_reftest_<n>_<basename>` where `n` was a plain per-Renderer
# counter starting at 1 — IDENTICAL in every process — and sweep_stale() deleted
# every file with that prefix it could find, at startup and again in the
# `finally`. So two concurrent runs (a) wrote each other's work paths and (b)
# deleted each other's IN-FLIGHT documents.
#
# This is not a theoretical race. Measured on this corpus, two concurrent
# `--all` runs, BOTH exiting 0:
#
#   serial baseline   PASS 45  WEAK-PASS 206  FAIL 1079  ND 111  ERROR 1
#   concurrent run A  PASS 46  WEAK-PASS 205  FAIL 1079  ND 111  ERROR 1
#   concurrent run B  PASS 45  WEAK-PASS 203  FAIL 1078  ND 111  ERROR 5
#
# Run B is a PHANTOM RED — ERROR 5 against #!ERROR_CEILING 1 and WEAK-PASS 203
# against #!WEAK_PASS_FLOOR 206 — the exact "red that is not a bug" this project
# has repeatedly lost hours to (six of seven investigated reds in one sweep were
# gate rot). Run A is worse: a PHANTOM GREEN, a reftest promoted WEAK-PASS ->
# PASS by reading another process's pixels, on an EXTERNAL CONFORMANCE RATCHET
# whose numbers are reported as fact.
#
# It also silently capped throughput. The corpus is 1,442 pairs / 4,915 renders
# and the plan is to scale toward all ~6,265 CSS2 reftests. A harness that
# cannot be run twice at once cannot be parallelised.
#
# WHAT IT ASSERTS
# ===============
#   PART 1  Work-file names are scoped to the writing PROCESS: every name
#           carries our pid and no two renders share one. This is the half that
#           stops two runs writing the same path.
#   PART 2  sweep_stale() reaps only what it can PROVE is not in flight — a
#           dead owner, our own pid, a file older than any plausible render, or
#           the pre-pid name format — and SPARES a live foreign owner's file.
#           This is the half that stops one run deleting the other's inputs.
#   PART 3  END TO END, against the real vendored corpus and the real pixel
#           backend: a real single-test run, executed with a RIVAL process
#           hammering the same directory exactly as a second run does (writing
#           the colliding legacy names, sweeping in a tight loop), must produce
#           the SAME verdict as the same run alone — and that verdict must not
#           be ERROR, so the two cannot agree vacuously on a broken renderer.
#   PART 4  tests/wpt/ is clean afterwards. The work files live in a git-TRACKED
#           vendored tree; debris there is indistinguishable from a vendored
#           edit to the next reader.
#
# MUTATION-TESTED: with the pid-scoping fix reverted, PARTS 1, 2 and 3 all go
# red. A concurrency gate that cannot detect the bug it was written for is
# decoration.
#
# NOT SOFT-GREEN: three outcomes (scripts/_verdict.sh) — 0 PASS, 1 FAIL, 125
# INCONCLUSIVE. If python3 is absent, the reftests are not vendored, or the
# pixel backend does not compile, this reports 125 and never PASS.
#
# RUN SERIALLY with the other pixel gates: it rebuilds build/host/hambrowse_gfx,
# the SAME artifact every test_hambrowse_*_host.sh and scripts/framediff_gfx_*.sh
# uses. ~30 s.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TAG="[wpt-reftest-conc]"
OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"

command -v python3 >/dev/null 2>&1 || {
    echo "$TAG INCONCLUSIVE: python3 absent; the runner could not execute."
    exit 125; }
[ -f tests/wpt/REFTEST_MANIFEST.txt ] || {
    echo "$TAG INCONCLUSIVE: tests/wpt/REFTEST_MANIFEST.txt absent; the"
    echo "$TAG   reftests are not vendored, so there is no lane to race."
    exit 125; }

echo "$TAG compiling the PIXEL backend for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" \
        >"$OUT/wpt_reftest_conc_compile.log" 2>&1; then
    echo "$TAG INCONCLUSIVE: pixel backend did not compile, so the end-to-end"
    echo "$TAG   leg could not be observed."
    tail -30 "$OUT/wpt_reftest_conc_compile.log"; exit 125
fi

rc=0

# --------------------------------------------------------------------------
# PARTS 1 and 2 -- the two halves of the fix, asserted directly.
# --------------------------------------------------------------------------
python3 - <<'PY'
import os, re, subprocess, sys, tempfile, time
sys.path.insert(0, "scripts")
import wpt_reftest_run as R

TAG = "[wpt-reftest-conc]"
ok = True

# ---- PART 1: names are scoped to this process and unique within it ---------
tmp = tempfile.mkdtemp(prefix="wpt-conc-p1-")
root = os.path.join(tmp, "docs")
os.makedirs(root)
open(os.path.join(root, "d.html"), "w").write("<style>p{color:red}</style><p>x</p>")

seen = []
real_run = subprocess.run


def spy(argv, *a, **kw):
    seen.append(argv[1])
    return real_run(["/bin/false"], *a, **kw)


subprocess.run = spy
try:
    rend = R.Renderer(tmp, tests_root=root)
    for i in range(4):
        rend.render("d.html", variant="v%d" % i,
                    data=("<style>p{color:red}</style><p>%d</p>" % i).encode())
finally:
    subprocess.run = real_run

names = [os.path.basename(p) for p in seen]
mine = str(os.getpid())
bad = [n for n in names if not R.WORK_RE.match(n) or ("p" + mine + "_") not in n]
if len(names) != 4 or bad or len(set(names)) != len(names):
    ok = False
    print("%s PART 1 FAIL: work-file names are not process-scoped/unique: %s"
          % (TAG, names))
    print("%s   Two concurrent runs would write the same paths, and each would"
          % TAG)
    print("%s   render the other's bytes." % TAG)
else:
    print("%s PART 1 PASS  %d work files, all pid-scoped to %s and distinct"
          % (TAG, len(names), mine))

# ---- PART 2: sweep_stale() reaps only what it can prove is not in flight ---
tmp2 = tempfile.mkdtemp(prefix="wpt-conc-p2-")
sub = os.path.join(tmp2, "css", "CSS2")
os.makedirs(sub)

# a genuinely live foreign process, whose pid we RECORD so we can kill exactly
# it and nothing else.
child = subprocess.Popen(["sleep", "60"])
live = child.pid
# a genuinely dead pid: start a process and reap it.
gone = subprocess.Popen(["true"])
dead = gone.pid
gone.wait()

cases = {}  # filename -> should it survive?
cases[".hamnix_reftest_p%d_1_a.html" % live] = True    # ANOTHER RUN, IN FLIGHT
cases[".hamnix_reftest_p%d_1_b.html" % dead] = False   # owner is gone
cases[".hamnix_reftest_p%d_7_c.html" % os.getpid()] = False   # ours
cases[".hamnix_reftest_1_d.html"] = False              # pre-pid debris
cases[".hamnix_reftest_p%d_2_e.html" % live] = False   # live owner, but ancient
try:
    for fn in cases:
        open(os.path.join(sub, fn), "w").write("x")
    old = os.path.join(sub, ".hamnix_reftest_p%d_2_e.html" % live)
    ancient = time.time() - 2 * R.WORK_MAX_AGE
    os.utime(old, (ancient, ancient))

    R.sweep_stale(tmp2)

    for fn, want in sorted(cases.items()):
        got = os.path.exists(os.path.join(sub, fn))
        if got != want:
            ok = False
            print("%s PART 2 FAIL: %s -- want %s, got %s"
                  % (TAG, fn, "SPARED" if want else "reaped",
                     "spared" if got else "REAPED"))
            if want:
                print("%s   sweep_stale() deleted a live run's IN-FLIGHT work"
                      % TAG)
                print("%s   file. That run will score the document as ERROR."
                      % TAG)
finally:
    child.kill()          # by the pid we recorded, never by pattern
    child.wait()
if ok:
    print("%s PART 2 PASS  live foreign owner spared; dead/own/ancient/legacy "
          "reaped" % TAG)

sys.exit(0 if ok else 1)
PY
[ $? = 0 ] || rc=1

# --------------------------------------------------------------------------
# PART 3 -- end to end on the real corpus with a real rival process.
# --------------------------------------------------------------------------
TEST="css/CSS2/normal-flow/max-height-applies-to-018.html"
echo "$TAG running $TEST alone, then against a rival run ..."

solo="$(python3 scripts/wpt_reftest_run.py "$TEST" 2>/dev/null \
        | awk -v t="$TEST" '$3 == t {print $1}')"
if [ -z "$solo" ]; then
    echo "$TAG INCONCLUSIVE: the solo run produced no verdict for $TEST, so"
    echo "$TAG   there is nothing to compare the concurrent run against."
    exit 125
fi
if [ "$solo" = "ERROR" ]; then
    echo "$TAG INCONCLUSIVE: $TEST is ERROR even alone; two runs agreeing on"
    echo "$TAG   ERROR would be a vacuous green."
    exit 125
fi
echo "$TAG   alone: $solo"

for i in 1 2 3; do
    # THE RIVAL. A faithful model of a SECOND RUN of this harness over the same
    # pair, concentrated onto one directory. It does only the two things
    # scripts/wpt_reftest_run.py itself does to a vendored directory:
    #
    #   * writes work files at the paths ITS OWN work_name() hands it -- the
    #     module's real name generator, so whether those paths collide with the
    #     first run's is decided by the code under test and not by this script;
    #   * calls the module's real sweep_stale().
    #
    # Nothing here reaches for a name the harness would not produce. If the two
    # runs' names are process-scoped and the sweep respects ownership, the rival
    # is invisible to the victim; if they are not, it is exactly the other run.
    python3 - "$TEST" <<'PY' &
import os, sys, time
sys.path.insert(0, "scripts")
import wpt_reftest_run as R

test = sys.argv[1]
d = os.path.join(R.TESTS, os.path.dirname(test))
docs = {os.path.basename(test)}
for t, _kind, refs in R.load_manifest():
    if t == test:
        docs.update(os.path.basename(r) for r in refs)
docs = sorted(docs)
end = time.time() + 120                      # cap; the parent kills us by pid
while time.time() < end:
    for _ in range(25):
        R._work_seq = 0                      # cover the victim's counter range
        for _n in range(20):
            for b in docs:
                try:
                    with open(os.path.join(d, R.work_name(b)), "wb") as f:
                        f.write(b"<html>rival run's document</html>")
                except OSError:
                    pass
    R.sweep_stale(d)
PY
    rival=$!
    conc="$(python3 scripts/wpt_reftest_run.py "$TEST" 2>/dev/null \
            | awk -v t="$TEST" '$3 == t {print $1}')"
    kill "$rival" 2>/dev/null      # by the pid we recorded. NEVER by pattern:
    wait "$rival" 2>/dev/null      # sibling gates run their own QEMU/python.
    if [ "$conc" != "$solo" ]; then
        echo "$TAG PART 3 FAIL: run $i under a concurrent rival said"
        echo "$TAG   '${conc:-<no verdict>}' where the same run alone said '$solo'."
        echo "$TAG   Two runs of this harness at once corrupt each other's work"
        echo "$TAG   files, so any number either produces is noise."
        rc=1
        break
    fi
    echo "$TAG   run $i alongside a rival: $conc"
done
[ "$rc" = 0 ] && echo "$TAG PART 3 PASS  3 concurrent runs, verdict unchanged"

# --------------------------------------------------------------------------
# PART 4 -- the vendored tree is clean.
# --------------------------------------------------------------------------
python3 -c '
import sys; sys.path.insert(0, "scripts")
import wpt_reftest_run as R; R.sweep_stale()' >/dev/null 2>&1
dirty="$(git status --porcelain tests/wpt 2>/dev/null)"
if [ -n "$dirty" ]; then
    echo "$TAG PART 4 FAIL: tests/wpt/ is dirty after the run:"
    echo "$dirty" | head -20
    echo "$TAG   Harness debris in a vendored tree is indistinguishable from a"
    echo "$TAG   vendored edit to the next reader."
    rc=1
else
    echo "$TAG PART 4 PASS  tests/wpt/ clean"
fi

if [ "$rc" = 0 ]; then
    echo "$TAG RESULT: PASS — concurrent reftest runs do not corrupt each other."
else
    echo "$TAG RESULT: FAIL"
fi
exit $rc
