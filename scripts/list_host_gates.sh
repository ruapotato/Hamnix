#!/usr/bin/env bash
# list_host_gates.sh — the AUTHORITATIVE list of QEMU-free host gates.
#
# WHY THIS FILE EXISTS
# --------------------
# Every "full sweep" run during the 2026-07-28 session used an ad-hoc glob typed
# into a shell:
#
#     scripts/test_hambrowse_*_host.sh   scripts/test_jsengine_*_host.sh
#
# That pattern requires a non-empty infix AND the `_host` suffix, so it silently
# missed 30 QEMU-free host gates — including `test_jsengine_host.sh` and its twin
# `test_hambrowse_host.sh` (no infix), plus 28 older hambrowse gates that predate
# the `_host` naming convention entirely (border, canvas, cascade, classlist,
# extcss, float, gif, img, infobox, jpeg, svg, uaelems, …).
#
# A real regression sat on main because of it: ToPrimitive left every builtin
# prototype with a null [[Prototype]], so `String(new TypeError("x"))` threw and
# killed the script. `test_jsengine_host.sh` caught it. No sweep ran that gate.
#
# The root problem was not the glob — it was that **the glob lived only in
# agents' shell history and was never in a file anyone could review.** This
# script is that file. Change the selector here, once, and every caller inherits
# it.
#
# SELECTOR: prefix-glob the family, then exclude anything that boots QEMU.
# Capability, not naming convention — a gate renamed tomorrow stays covered.
#
# Usage:
#   bash scripts/list_host_gates.sh              # all host gates, one per line
#   bash scripts/list_host_gates.sh hambrowse    # one family
#   for g in $(bash scripts/list_host_gates.sh); do bash "$g" || echo "FAIL $g"; done
#
# NOTE: run host gates SERIALLY when the result matters. They all compile to the
# same build/host/hambrowse_gfx path, so a parallel sweep clobbers itself — a
# `-P 6` run once produced 3 reds that were all green when re-run alone.
set -u

cd "$(dirname "$0")/.." || exit 1

fam="${1:-}"
if [ -n "$fam" ]; then
    pats=("scripts/test_${fam}"*.sh)
else
    # test_wpt* joined the family 2026-07-29. Both WPT lanes are QEMU-free
    # browser gates and BOTH build into build/host/ alongside the hambrowse
    # gates -- the reftest lane rebuilds build/host/hambrowse_gfx, the exact
    # artifact this file's serial-execution note is about. Leaving them out of
    # "the authoritative list of QEMU-free host gates" reproduced, for the
    # external-conformance lanes, the same dark-gate hole the header describes.
    pats=(scripts/test_hambrowse*.sh scripts/test_jsengine*.sh
          scripts/test_wpt*.sh)
fi

for f in "${pats[@]}"; do
    [ -f "$f" ] || continue
    # A gate that launches QEMU is not a host gate.
    grep -qE 'qemu-system|run_qemu|_qemu_drive\.sh' "$f" && continue
    echo "$f"
done
