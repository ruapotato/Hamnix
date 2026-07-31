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

# 2026-07-31: THIS FILE WAS STILL LYING, in exactly the way its own header
# describes. The header claims "SELECTOR: prefix-glob the family, then exclude
# anything that boots QEMU. Capability, not naming convention." The second
# sentence was false: the default selector was three name prefixes
# (test_hambrowse*, test_jsengine*, test_wpt*), so it returned 283 scripts while
# **645 QEMU-free gates exist on disk**. 362 were invisible to every "full host
# gate sweep" run against it -- and those sweeps were reported, by me, as
# comprehensive.
#
# It was caught when a browser agent ran a wider set and found
# `scripts/test_react18_host.sh` RED on a base commit that a `283/283 green`
# sweep had just declared clean. That gate does not begin with any of the three
# prefixes, so it had never once been run by a sweep through this file.
#
# The default is now the capability the header always claimed: every
# scripts/test_*.sh that does not boot a VM. `browser` keeps the old
# browser-family set, because those gates share build/host/hambrowse_gfx and a
# browser change genuinely only needs that subset re-run.
#
# Usage:
#   bash scripts/list_host_gates.sh            # ALL QEMU-free gates (the truth)
#   bash scripts/list_host_gates.sh browser    # the hambrowse/jsengine/wpt set
#   bash scripts/list_host_gates.sh hamsh      # any other prefix family
fam="${1:-}"
case "$fam" in
    "")        pats=(scripts/test_*.sh) ;;
    browser)   pats=(scripts/test_hambrowse*.sh scripts/test_jsengine*.sh
                     scripts/test_wpt*.sh) ;;
    *)         pats=("scripts/test_${fam}"*.sh) ;;
esac

for f in "${pats[@]}"; do
    [ -f "$f" ] || continue
    # A gate that launches QEMU -- directly, via the shared runners, or by
    # demanding an installer image -- is not a host gate.
    #
    # 2026-07-31: this list named exactly ONE of the SEVEN helpers under
    # scripts/ that reach qemu-system-x86_64. Gates route to a VM through a
    # helper whose name contains neither "qemu" nor "img", so they were
    # classified QEMU-free and swept as host gates -- 63 of them, including the
    # whole 9P suite (test_9p_codec boots QEMU + hamsh) and test_auth, which is
    # how test_auth came back red from a "host gate sweep".
    #
    # Enumerated by grepping scripts/_*.sh for qemu-system-x86_64:
    #   _hamsh_drive.sh          hamsh_boot() -> qemu-system-x86_64
    #   _installed_boot.sh       installed_boot_start(), the OVMF/NVMe harness
    #   _kernel_iso.sh           installs the build/binshim qemu-system-x86_64
    #                            wrapper the other drivers invoke
    #   _kvm_coreutils_repro.sh  timeout 1100s qemu-system-x86_64
    #   _kvm_wc_repro.sh         timeout 900s qemu-system-x86_64
    #   _qemu_drive.sh           the original, the only one listed before
    # _build_lock.sh is NOT in the list: it only MENTIONS qemu in a comment
    # about _kernel_iso.sh's shim, and 4 genuinely QEMU-free gates source it.
    #
    # If you add a helper that can start a VM, add it here. This is a
    # CAPABILITY test, and it has to name every route to a VM or it lies.
    grep -qE 'qemu-system|run_qemu|_qemu_drive\.sh|_hamsh_drive\.sh|hamsh_boot|_installed_boot\.sh|installed_boot_start|_kernel_iso\.sh|_kvm_coreutils_repro\.sh|_kvm_wc_repro\.sh|ensure_installer_img|installer_img_or_verdict' "$f" && continue
    echo "$f"
done
