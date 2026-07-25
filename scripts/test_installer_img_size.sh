#!/bin/bash
# Regression guard: the DEFAULT installer image must stay small enough that its
# in-RAM rootfs fits under the user's `-m 1G` boot. TWICE now an agent's staging
# (the real-Debian apt closure; then the broad-Debian-binary coverage embed)
# silently bloated build/hamnix-installer.img past the budget, so the in-RAM
# rootfs alloc failed and the DE OOM'd on app spawn (blank desktop). This test
# fails the moment the default image crosses the ceiling.
#
# It does NOT build — it checks the most-recent default build artifact. Run it
# right after `bash scripts/build_installer_img.sh` (with NO HAMNIX_DEBIAN_BREADTH
# / HAMNIX_LIVE_MINIMAL=0 overrides). CI builds the default image then runs this.
set -u
IMG="${HAMNIX_INSTALLER_IMG:-build/hamnix-installer.img}"
# Ceiling: the known-good default image is ~216 MiB; the OOM regression was
# ~297 MiB. 260 MiB leaves headroom for legit growth while catching a bloat.
CEIL_MIB="${HAMNIX_IMG_CEIL_MIB:-260}"

if [ ! -f "$IMG" ]; then
    echo "[img-size] SKIP: $IMG not built (run build_installer_img.sh first)"
    exit 0
fi
# This gate measures a PRE-EXISTING artifact by design. Measuring a stale one
# reports yesterday's size as today's verdict — be loud about it.
# shellcheck source=_installer_img.sh
source "$(dirname "${BASH_SOURCE[0]}")/_installer_img.sh"
installer_img_warn_if_stale "$IMG" "[img-size]"
# If the broad-coverage embed was explicitly requested, the image is expected
# to be large — don't enforce the default ceiling.
if [ "${HAMNIX_DEBIAN_BREADTH:-0}" = "1" ] || [ "${HAMNIX_LIVE_MINIMAL:-1}" = "0" ]; then
    echo "[img-size] SKIP: breadth/full-debian build (not the default -m 1G image)"
    exit 0
fi

bytes=$(stat -c%s "$IMG")
mib=$(( bytes / 1024 / 1024 ))
echo "[img-size] $IMG = ${mib} MiB (ceiling ${CEIL_MIB} MiB)"
if [ "$mib" -gt "$CEIL_MIB" ]; then
    echo "[img-size] FAIL: default installer image ${mib} MiB exceeds ${CEIL_MIB} MiB"
    echo "[img-size]   -> something un-gated bloated the default image; the in-RAM"
    echo "[img-size]      rootfs will not fit -m 1G and the DE will OOM on app spawn."
    echo "[img-size]      Gate the new staging behind HAMNIX_DEBIAN_BREADTH / a flag."
    exit 1
fi
echo "[img-size] PASS"
exit 0
