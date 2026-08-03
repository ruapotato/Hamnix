#!/usr/bin/env bash
# scripts/test_leak_kmtrack_diff.sh — MUTATION-TEST the kernel-heap differ
# (scripts/leak_kmtrack_diff.py), leak pass 20.
#
# WHY THIS EXISTS
# ===============
# Same reason as scripts/test_leak_hours_report_mutations.sh: the log the
# differ reads costs an EIGHT-HOUR KVM boot to produce, so nobody would ever
# re-run the producer to check that the verdict logic still catches anything,
# and that is precisely how a gate rots into a green that means nothing.
#
# The differ itself exists because pass 19's gate captured `kmtrack dump` in
# both sample batteries and its adjudicator never read them — the kernel heap
# was measured and never judged, while the PASS read as though it covered the
# machine. So this gate's population includes the BLINDNESS cases (mode=0, no
# header, no site lines, an exhausted site-block pool) as prominently as the
# growth case: a differ that cannot tell "flat heap" from "tracker was off"
# would reproduce the exact bug it was written to close.
#
# No QEMU, no KVM, no image.
#
# Verdicts (scripts/_verdict.sh): 0 PASS, 1 FAIL, 125 INCONCLUSIVE.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
TAG="[kmdiff-mut]"

DIFF="$PROJ_ROOT/scripts/leak_kmtrack_diff.py"
[ -f "$DIFF" ] || {
    echo "$TAG INCONCLUSIVE: $DIFF absent — nothing to mutate" >&2; exit 125; }

WORK=$(mktemp -d --tmpdir hamnix-kmmut.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]

# A plausible idle-machine heap, modelled on a REAL capture from the pass-19
# gate shape (loaded1/serial.log, 2026-08-03):
#     [kmtrack] mode=1 blocks=7 exhausted=0
#     [kmtrack] site 0: live=28 bytes=8960 / allocs=158 frees=160
# Note allocs < frees at site 0 with live > 0: that is not a bug, it is
# km_track_reset()'s pre-charge of the whole pre-arming live population
# draining out. The differ must not mistake it for anything.
BASE = {
    0:  dict(live=28, bytes=8960,  allocs=158, frees=160),
    1:  dict(live=0,  bytes=0,     allocs=129, frees=129),
    2:  dict(live=0,  bytes=0,     allocs=63,  frees=63),
    13: dict(live=0,  bytes=0,     allocs=21,  frees=21),
}


def sample(s, sites, mode=1, blocks=7, exhausted=0, header=True,
           site_lines=True):
    L = ["HC_SAMPLE %s" % s]
    if header:
        L.append("[%06d] [kmtrack] mode=%d blocks=%d exhausted=%d"
                 % (2400, mode, blocks, exhausted))
    if site_lines:
        for i, v in sorted(sites.items()):
            L.append("[%06d] [kmtrack] site %d: live=%d bytes=%d"
                     % (2401 + i, i, v['live'], v['bytes']))
            L.append("[%06d] [kmtrack] site %d: allocs=%d frees=%d"
                     % (2402 + i, i, v['allocs'], v['frees']))
    L.append("HC_KM_%s" % s)
    L.append("HC_SAMPLE_END %s" % s)
    return "\n".join(L)


def bump(base, site, dlive=0, dbytes=0, dallocs=0, dfrees=0):
    """Copy BASE with one site moved. Keeps the two estimators consistent
    unless the caller deliberately desynchronises them."""
    out = {k: dict(v) for k, v in base.items()}
    e = out.setdefault(site, dict(live=0, bytes=0, allocs=0, frees=0))
    e['live'] += dlive
    e['bytes'] += dbytes
    e['allocs'] += dallocs
    e['frees'] += dfrees
    return out


cases = []


def case(name, a, b, want, why):
    d = os.path.join(work, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "serial.log"), "w") as f:
        f.write("boot noise\n" + a + "\nidle gap\n" + b + "\n")
    cases.append((name, want, why))


# --- the clean control. Must be PASS, or every row below is vacuous. -------
# An idle gap in which one vfs object was allocated and freed again: motion
# with no net, which is what a healthy heap looks like.
A = sample('A', BASE)
B = sample('B', bump(BASE, 1, dallocs=4, dfrees=4))
case("clean", A, B, 0, "flat heap, both estimators agree")

# --- BLINDNESS: the class the differ was written to close ------------------
case("no_header_B", A, sample('B', BASE, header=False), 125,
     "sample B never dumped the heap")
case("mode_off_A", sample('A', BASE, mode=0), B, 125,
     "kmtrack was OFF in A; the counters are stale")
case("no_site_lines_B", A, sample('B', BASE, site_lines=False), 125,
     "header but no attribution at all")
case("pool_exhausted_B", A, sample('B', BASE, exhausted=3), 125,
     "site-block pool exhausted; untracked slab pages")
case("pool_full_A", sample('A', BASE, blocks=8192), B, 125,
     "block pool at the KM_BLK_SLOTS ceiling")
case("missing_sample_B", A, "boot continues\n", 125,
     "sample B absent entirely")

# --- CONTAMINATION: the two estimators disagree ---------------------------
# live says +6, allocs-minus-frees says +1. _km_drain clamped somewhere.
case("estimators_disagree", A,
     sample('B', bump(BASE, 2, dlive=6, dbytes=384, dallocs=5, dfrees=4)), 125,
     "live histogram and allocs-frees disagree at site 2")

# A cumulative counter going backwards means a reset landed mid-gap.
case("reset_mid_gap", A,
     sample('B', bump(BASE, 1, dallocs=-100, dfrees=-100)), 1,
     "cumulative allocs fell; a kmtrack reset landed between samples")

# --- GROWTH: the thing months of uptime actually cares about ---------------
# 96 KiB over the gap at the VFS site, estimators consistent.
case("heap_grew", A,
     sample('B', bump(BASE, 1, dlive=1536, dbytes=98304, dallocs=1536)), 1,
     "kernel heap grew 96 KiB with nothing launched")

# The SAME growth split across two sites, so no single site is dramatic but
# the total is over the bar. A per-site-only check would miss this.
case("heap_grew_split", A,
     sample('B', bump(bump(BASE, 1, dlive=800, dbytes=51200, dallocs=800),
                      3, dlive=800, dbytes=51200, dallocs=800)), 1,
     "growth spread over two sites still breaks the total")

# Under the bar: PASS, but the differ must NAME it rather than round it to 0.
case("heap_grew_small", A,
     sample('B', bump(BASE, 12, dlive=16, dbytes=1024, dallocs=16)), 0,
     "1 KiB of growth, under the bar, reported as a NOTE")

# A site that DROPPED is not growth. A differ that took |delta| would red here.
case("heap_shrank", A,
     sample('B', bump(BASE, 0, dlive=-20, dbytes=-6400, dfrees=20)), 0,
     "heap shrank; not a leak")

# A brand-new site appearing in B only (id absent from A) must be counted as
# growth from zero, not silently skipped for want of a baseline.
case("new_site_in_B", A,
     sample('B', bump(BASE, 7, dlive=2048, dbytes=131072, dallocs=2048)), 1,
     "a site absent in A appears in B holding 128 KiB")

# An id beyond the KMNAME table must still be judged, not dropped.
case("unknown_site_id", A,
     sample('B', bump(BASE, 29, dlive=1600, dbytes=102400, dallocs=1600)), 1,
     "an unnamed site id is still counted")

# --- NEGATIVE CONTROLS -----------------------------------------------------
# A differ that always says INCONCLUSIVE would pass every row above and be
# worse than nothing. These must come out green.
case("clean_again_noop", A, sample('B', BASE), 0,
     "byte-identical samples are PASS, not INCONCLUSIVE")
case("clean_motion", A,
     sample('B', bump(bump(BASE, 2, dallocs=40, dfrees=40),
                      13, dallocs=9, dfrees=9)), 0,
     "lots of alloc/free churn with zero net is PASS")

with open(os.path.join(work, "cases.txt"), "w") as f:
    for name, want, why in cases:
        f.write("%s %d %s\n" % (name, want, why))
PY

[ -f "$WORK/cases.txt" ] || {
    echo "$TAG INCONCLUSIVE: synthetic log generation produced nothing" >&2
    exit 125; }

ncase=0
nfail=0
lbl() { case "$1" in 0) echo PASS;; 1) echo FAIL;; 125) echo INCONCLUSIVE;;
                     *) echo "rc=$1";; esac; }
while read -r name want why; do
    ncase=$((ncase + 1))
    out="$WORK/$name/report.txt"
    python3 "$DIFF" "$WORK/$name/serial.log" 65536 > "$out" 2>&1
    got=$?
    if [ "$got" -eq "$want" ]; then
        printf '%s   ok   %-22s -> %-12s (%s)\n' \
            "$TAG" "$name" "$(lbl "$got")" "$why"
    else
        printf '%s   BAD  %-22s -> %-12s, expected %-12s (%s)\n' \
            "$TAG" "$name" "$(lbl "$got")" "$(lbl "$want")" "$why" >&2
        grep -E 'FAIL:|INCONCLUSIVE:|VERDICT' "$out" | head -10 >&2
        nfail=$((nfail + 1))
    fi
done < "$WORK/cases.txt"

# A mutation table that shrank to nothing would pass vacuously — the failure
# mode this whole gate is about. Assert its own population.
if [ "$ncase" -lt 14 ]; then
    echo "$TAG INCONCLUSIVE: only $ncase mutation(s) ran; the table has been" >&2
    echo "$TAG   gutted and a green from it means nothing" >&2
    exit 125
fi
if [ "$nfail" -ne 0 ]; then
    echo "$TAG FAIL: $nfail of $ncase cases came out wrong — the kernel-heap" >&2
    echo "$TAG   differ is blind to them" >&2
    exit 1
fi
echo "$TAG PASS — all $ncase cases (blindness, contamination, growth and"
echo "$TAG   4 negative controls) adjudicated correctly by"
echo "$TAG   scripts/leak_kmtrack_diff.py"
exit 0
