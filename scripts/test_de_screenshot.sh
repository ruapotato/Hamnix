#!/usr/bin/env bash
# scripts/test_de_screenshot.sh — boot the installer image, wait for the
# DE to come up, screendump the GOP framebuffer to a PNG the orchestrator
# can READ.
#
# The user's #1 DE complaint: it LOOKS broken. The orchestrator has visual
# input — this script gives it the artifact to look at:
#
#   build/de_screenshot.png   PNG of the live framebuffer just after the
#                             DE autostart marker fires.
#
# Boots build/hamnix-installer.img under OVMF/KVM matching the user's ship
# command (mirrors scripts/run_installer.sh's DETERMINISTIC boot), waits for
# the rc.5 handoff marker (or a fallback timer), sleeps to let the desktop
# paint, then issues `screendump` to the QEMU monitor and converts the
# resulting PPM to PNG.
#
# RELIABILITY (two defects this harness previously had, now fixed):
#   * REBUILD BY DEFAULT. A plain invocation REBUILDS the installer image
#     first so the screendump reflects the CURRENT source — never a stale
#     pre-change desktop (the "stale-installer-img QA trap"). Export
#     HAMNIX_SKIP_BUILD=1 to deliberately reuse an image you already built.
#   * DETERMINISTIC BOOT TO THE OS. Boots with SPLIT OVMF_CODE + a FRESH
#     copy of OVMF_VARS every run (so no stale boot-order — e.g. a prior
#     interrupted run leaving "EFI Internal Shell" selected — can survive
#     across runs) AND pins bootindex=0 on the boot drive, so OVMF always
#     launches \EFI\BOOT\BOOTX64.EFI and reaches the DE, never the Shell>
#     prompt. Falls back to a fresh copy of the combined OVMF.fd when the
#     split firmware is unavailable.
#
# Skips cleanly (exit 0) when /dev/kvm, OVMF, the installer image, or a
# PPM->PNG converter is unavailable. The screenshot itself is the
# deliverable; this script INTENTIONALLY does NOT assert "the DE looks
# right" — the orchestrator reads the PNG and judges that visually.
#
# Env overrides:
#   INSTALLER_IMG      image path        (default: build/hamnix-installer.img)
#   OVMF_FD            OVMF firmware     (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for the handoff marker (default: 240)
#   PAINT_WAIT         extra seconds to let the DE paint (default: 8)
#   SHOT_OUT           output PNG path   (default: build/de_screenshot.png)
#   HAMNIX_SKIP_BUILD  1 = do NOT rebuild; reuse the existing image as-is
#                          (SKIPs cleanly if that image is absent).
#                          UNSET (default) = rebuild the image before booting.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# By DEFAULT this screendumps the CLEAN first-boot desktop (wallpaper +
# panel + taskbar + one welcome terminal) — the shipped image no longer
# auto-opens the demo apps. To screendump the DE render self-test instead
# (the demo apps launched through /dev/wsys/run/launch), the caller exports
# HAMNIX_DE_SELFTEST=1: that bakes rc.5's /etc/rc.d/rc.5.selftest fragment
# into a DEDICATED image at a distinct path (never clobbering the clean one).
if [ "${HAMNIX_DE_SELFTEST:-0}" = "1" ]; then
    export HAMNIX_DE_SELFTEST=1
    INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer-selftest.img}"
    export HAMNIX_INSTALLER_IMG_OUT="$INSTALLER_IMG"
fi
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
PAINT_WAIT="${PAINT_WAIT:-8}"
SHOT_OUT="${SHOT_OUT:-build/de_screenshot.png}"
HANDOFF_MARKER="handing off to interactive shell"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_de_screenshot] SKIP: /dev/kvm absent (KVM required for -vga std OVMF boot)" >&2
    exit 0
fi

# Resolve OVMF firmware. PREFER the SPLIT build (OVMF_CODE + OVMF_VARS): it
# lets us boot a FRESH copy of the VARS store every run so no stale boot-order
# (e.g. "EFI Internal Shell" left selected by a prior interrupted boot) can
# persist across runs and drop us to the Shell> prompt. Fall back to the
# combined OVMF.fd when the split firmware is absent (still booted from a
# fresh copy + bootindex=0 so OVMF auto-launches the media).
#   OVMF_CODE : firmware code volume (or the combined image)
#   OVMF_VARS : template var store, or "" when only a combined image exists
OVMF_CODE="${OVMF_FD:-}"
OVMF_VARS=""
if [ -z "$OVMF_CODE" ]; then
    for pair in \
        "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd" \
        "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd" \
        "/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd"; do
        c="${pair%%:*}"; v="${pair##*:}"
        if [ -f "$c" ] && [ -f "$v" ]; then
            OVMF_CODE="$c"; OVMF_VARS="$v"; break
        fi
    done
fi
if [ -z "$OVMF_CODE" ]; then
    # No split firmware — fall back to a combined image (vars live inside it).
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd; do
        [ -f "$c" ] && { OVMF_CODE="$c"; break; }
    done
fi
if [ -z "$OVMF_CODE" ] || [ ! -f "$OVMF_CODE" ]; then
    echo "[test_de_screenshot] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# screendump produces PPM; we need a PPM->PNG converter for the
# deliverable. Try convert (ImageMagick), then ffmpeg, then pnmtopng.
CONVERTER=""
if command -v convert >/dev/null 2>&1; then
    CONVERTER="convert"
elif command -v ffmpeg >/dev/null 2>&1; then
    CONVERTER="ffmpeg"
elif command -v pnmtopng >/dev/null 2>&1; then
    CONVERTER="pnmtopng"
else
    echo "[test_de_screenshot] SKIP: no PPM->PNG converter (need convert/ffmpeg/pnmtopng)" >&2
    exit 0
fi

# Need a monitor driver to issue screendump headlessly.
MON_DRIVER=""
if command -v socat >/dev/null 2>&1; then
    MON_DRIVER="socat"
elif command -v nc >/dev/null 2>&1; then
    MON_DRIVER="nc"
else
    echo "[test_de_screenshot] SKIP: no socat/nc to drive QEMU monitor" >&2
    exit 0
fi

# --- installer image: REBUILD BY DEFAULT ------------------------------
# A plain invocation rebuilds so the screendump reflects CURRENT source (the
# stale-installer-img trap). HAMNIX_SKIP_BUILD=1 reuses the existing image.
if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
    if [ ! -f "$INSTALLER_IMG" ]; then
        echo "[test_de_screenshot] SKIP: HAMNIX_SKIP_BUILD=1 but $INSTALLER_IMG absent." >&2
        exit 0
    fi
    echo "[test_de_screenshot] HAMNIX_SKIP_BUILD=1: reusing existing $INSTALLER_IMG (no rebuild)."
    # ...but SAY SO when that image predates the tree, so nobody reads the
    # screendump as a picture of current source (scripts/_installer_img.sh).
    # shellcheck source=_installer_img.sh
    source "$PROJ_ROOT/scripts/_installer_img.sh"
    installer_img_warn_if_stale "$INSTALLER_IMG" "[de_screenshot]"
else
    echo "[test_de_screenshot] rebuilding $INSTALLER_IMG via build_installer_img.sh (~10-15 min)..."
    # HAMNIX_INSTALLER_IMG_OUT is already exported for the selftest image;
    # for the default clean image it defaults to build/hamnix-installer.img.
    if ! bash "$PROJ_ROOT/scripts/build_installer_img.sh"; then
        echo "[test_de_screenshot] SKIP: installer image build failed/gated." >&2
        exit 0
    fi
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "[test_de_screenshot] SKIP: $INSTALLER_IMG unavailable after build." >&2
    exit 0
fi

CODE_RW=$(mktemp --tmpdir hamnix-de-shot.code.XXXXXX.fd)
VARS_RW=$(mktemp --tmpdir hamnix-de-shot.vars.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-de-shot.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-de-shot.XXXXXX.log)
MON=$(mktemp --tmpdir -u hamnix-de-shot-mon.XXXXXX)
SHOT_PPM=$(mktemp --tmpdir hamnix-de-shot.XXXXXX.ppm)
# A FRESH copy of the image each run: OVMF's fallback NvVars file (written to
# the ESP when there is no pflash var store) lands on this throwaway copy, so
# no boot-order pollution survives to the next run.
cp "$INSTALLER_IMG" "$IMG_RW"

# Assemble the firmware args. SPLIT firmware => pflash pair with a FRESH VARS
# copy every run (deterministic boot order, no stale "EFI Internal Shell").
# Combined firmware => a fresh -bios copy (vars reset each run since we copy).
if [ -n "$OVMF_VARS" ]; then
    cp "$OVMF_CODE" "$CODE_RW"
    cp "$OVMF_VARS" "$VARS_RW"
    FW_ARGS=(
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$CODE_RW"
        -drive "if=pflash,format=raw,unit=1,file=$VARS_RW"
    )
    echo "[test_de_screenshot] firmware: split OVMF (fresh VARS each run) $OVMF_CODE"
else
    cp "$OVMF_CODE" "$CODE_RW"
    FW_ARGS=(-bios "$CODE_RW")
    echo "[test_de_screenshot] firmware: combined OVMF (fresh copy) $OVMF_CODE"
fi

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$CODE_RW" "$VARS_RW" "$IMG_RW" "$MON" "$SHOT_PPM"
}
trap cleanup EXIT

mkdir -p "$(dirname "$SHOT_OUT")"

# Mirror scripts/run_installer.sh's DETERMINISTIC boot: bootindex=0 on the
# installer media forces OVMF to launch \EFI\BOOT\BOOTX64.EFI first (otherwise
# it falls through to the EFI Internal Shell) so we reach the DE, not Shell>.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    "${FW_ARGS[@]}" \
    -drive "file=$IMG_RW,format=raw,if=none,id=instmedia" \
    -device virtio-blk-pci,drive=instmedia,bootindex=0 \
    -m "${HAMNIX_VM_MEM:-2G}" \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    > "$LOG" 2>&1 < /dev/null &
QEMU_PID=$!

echo "[test_de_screenshot] waiting up to ${BOOT_WAIT}s for handoff marker..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "$HANDOFF_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_de_screenshot] FAIL: qemu exited before reaching the handoff marker." >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done
if [ "$booted" -ne 1 ]; then
    echo "[test_de_screenshot] FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -80 "$LOG" >&2
    exit 1
fi
echo "[test_de_screenshot] handoff reached; letting the DE paint for ${PAINT_WAIT}s."
sleep "$PAINT_WAIT"

mon_cmd() {
    if [ "$MON_DRIVER" = "socat" ]; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    else
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    fi
}

if ! mon_cmd "screendump $SHOT_PPM"; then
    echo "[test_de_screenshot] FAIL: monitor screendump command failed." >&2
    exit 1
fi
sleep 2

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

if [ ! -s "$SHOT_PPM" ]; then
    echo "[test_de_screenshot] FAIL: screendump produced empty PPM." >&2
    exit 1
fi

case "$CONVERTER" in
    convert)
        convert "$SHOT_PPM" "$SHOT_OUT" 2>/dev/null
        ;;
    ffmpeg)
        ffmpeg -y -loglevel error -i "$SHOT_PPM" "$SHOT_OUT" </dev/null
        ;;
    pnmtopng)
        pnmtopng "$SHOT_PPM" > "$SHOT_OUT" 2>/dev/null
        ;;
esac

if [ ! -s "$SHOT_OUT" ]; then
    echo "[test_de_screenshot] FAIL: PPM->PNG conversion ($CONVERTER) produced empty $SHOT_OUT." >&2
    exit 1
fi

size=$(wc -c < "$SHOT_OUT")
echo "[test_de_screenshot] PASS: wrote $SHOT_OUT ($size bytes) via $CONVERTER."
rm -f "$LOG"
exit 0
