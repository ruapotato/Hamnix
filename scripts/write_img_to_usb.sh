#!/usr/bin/env bash
# scripts/write_img_to_usb.sh — flash build/hamnix-installer.img to a USB stick.
#
# Hamnix ships a UEFI-only ESP-only GPT installer medium
# (build/hamnix-installer.img, built by scripts/build_installer_img.sh): a
# FAT ESP that the firmware boots into the in-RAM installer, which then lays
# a real GPT + ext4 root onto the target disk. Flashing this medium to a USB
# stick gives a bootable installer (a real system is installed onto a disk,
# never shipped as a pre-baked root image).
#
# Wrapper around `sudo dd` with the safety checks the bare `dd` invocation
# in docs/REAL_HARDWARE.md doesn't enforce:
#
#   - refuses to run unless the medium exists (suggests build_installer_img.sh)
#   - refuses /dev/sda by default (typical host system disk lives there)
#   - refuses devices >64 GiB by default (looks more like an internal disk
#     than a USB stick) unless --force is passed
#   - prints the device size + model + current partition table BEFORE
#     touching it and prompts for an explicit "yes" confirmation
#   - uses bs=4M conv=fsync status=progress (the canonical recipe)
#
# Usage:
#   bash scripts/write_img_to_usb.sh /dev/sdX
#   bash scripts/write_img_to_usb.sh --help
#
# Flags:
#   --force                   allow devices larger than 64 GiB
#   --really-i-mean-sda       allow /dev/sda explicitly
#   --img PATH                use a different image (default: build/hamnix-installer.img)
#   --yes                     skip the interactive confirmation prompt
#                             (still prints the partition table; for CI)
#
# The script ONLY ever calls `sudo dd` after the user types `yes`. It does
# not run with --no-sudo. Without sudo dd cannot open the raw block device.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG_DEFAULT="$PROJ_ROOT/build/hamnix-installer.img"

usage() {
    cat <<EOF
write_img_to_usb.sh — flash build/hamnix-installer.img to a USB stick.

Usage:
    bash scripts/write_img_to_usb.sh /dev/sdX [flags]
    bash scripts/write_img_to_usb.sh --help

Flags:
    --force                 allow target devices larger than 64 GiB
    --really-i-mean-sda     allow /dev/sda (usually the host's system disk)
    --img PATH              use a different image (default: $IMG_DEFAULT)
    --yes                   skip the interactive confirmation prompt
    -h, --help              this message

The script wraps:
    sudo dd if=<img> of=/dev/sdX bs=4M conv=fsync status=progress

It refuses to run if the image is missing (suggests
scripts/build_installer_img.sh), prints the device size / model / current
partitions, and prompts for an explicit 'yes' before writing. See
docs/REAL_HARDWARE.md for the full real-hardware boot procedure.
EOF
}

DEVICE=""
IMG_PATH="$IMG_DEFAULT"
ALLOW_LARGE=0
ALLOW_SDA=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --force)
            ALLOW_LARGE=1
            shift
            ;;
        --really-i-mean-sda)
            ALLOW_SDA=1
            shift
            ;;
        --img)
            if [ $# -lt 2 ]; then
                echo "[write_img_to_usb] ERROR: --img requires a path argument." >&2
                exit 2
            fi
            IMG_PATH="$2"
            shift 2
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "[write_img_to_usb] ERROR: unknown flag '$1'. Try --help." >&2
            exit 2
            ;;
        *)
            if [ -n "$DEVICE" ]; then
                echo "[write_img_to_usb] ERROR: only one target device allowed (got '$DEVICE' and '$1')." >&2
                exit 2
            fi
            DEVICE="$1"
            shift
            ;;
    esac
done

if [ -z "$DEVICE" ]; then
    echo "[write_img_to_usb] ERROR: no target device given. Try --help." >&2
    exit 2
fi

# ---- Image sanity --------------------------------------------------------
# Writing a STALE image to a USB stick is the most expensive form of this
# mistake: you then boot real hardware and debug code that is not on it.
# shellcheck source=_installer_img.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_installer_img.sh"
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
installer_img_warn_if_stale "$IMG_PATH" "[write_img_to_usb]"
if [ ! -f "$IMG_PATH" ]; then
    echo "[write_img_to_usb] ERROR: image not found at '$IMG_PATH'." >&2
    if [ "$IMG_PATH" = "$IMG_DEFAULT" ]; then
        echo "[write_img_to_usb]   Build it first:  bash scripts/build_installer_img.sh" >&2
    else
        echo "[write_img_to_usb]   Pass --img PATH to point at an existing image." >&2
    fi
    exit 1
fi

# A GPT disk carries the "EFI PART" signature in LBA 1 (byte offset 512).
GPT_SIG=$(dd if="$IMG_PATH" bs=1 skip=512 count=8 2>/dev/null || true)
if [ "$GPT_SIG" != "EFI PART" ]; then
    echo "[write_img_to_usb] ERROR: '$IMG_PATH' is not a GPT disk image" >&2
    echo "[write_img_to_usb]   (no 'EFI PART' signature at LBA 1)." >&2
    echo "[write_img_to_usb]   Build it with: bash scripts/build_installer_img.sh" >&2
    file "$IMG_PATH" >&2 || true
    exit 1
fi

IMG_BYTES=$(stat -c%s "$IMG_PATH")
IMG_MB=$(( (IMG_BYTES + 1024*1024 - 1) / (1024*1024) ))
echo "[write_img_to_usb] image:  $IMG_PATH  ($IMG_BYTES bytes ~ ${IMG_MB} MiB)"

# ---- Device sanity -------------------------------------------------------
if [ ! -b "$DEVICE" ]; then
    echo "[write_img_to_usb] ERROR: '$DEVICE' is not a block device (or does not exist)." >&2
    echo "[write_img_to_usb]   List candidates with:  lsblk -d -o NAME,SIZE,MODEL,TRAN" >&2
    exit 1
fi

# Refuse partitions ("/dev/sdb1") — caller must give the whole device.
if [[ "$DEVICE" =~ [0-9]$ ]] && [[ ! "$DEVICE" =~ ^/dev/(nvme|mmcblk|loop)[0-9]+$ ]]; then
    echo "[write_img_to_usb] ERROR: '$DEVICE' looks like a partition (trailing digit)." >&2
    echo "[write_img_to_usb]   Pass the whole device (e.g. /dev/sdb), not /dev/sdb1." >&2
    exit 1
fi

# /dev/sda guard. Most desktop installs put the system disk here.
if [ "$DEVICE" = "/dev/sda" ] && [ "$ALLOW_SDA" -ne 1 ]; then
    echo "[write_img_to_usb] ERROR: refusing /dev/sda by default." >&2
    echo "[write_img_to_usb]   /dev/sda is usually the host's system disk on" >&2
    echo "[write_img_to_usb]   desktop Linux. If you are SURE this is your USB" >&2
    echo "[write_img_to_usb]   stick, pass --really-i-mean-sda." >&2
    exit 1
fi

# Resolve device size in bytes (via blockdev, which queries the kernel).
if ! DEV_BYTES=$(sudo blockdev --getsize64 "$DEVICE" 2>/dev/null); then
    echo "[write_img_to_usb] ERROR: blockdev --getsize64 '$DEVICE' failed." >&2
    echo "[write_img_to_usb]   Is the device present? sudo lsblk to confirm." >&2
    exit 1
fi
DEV_GIB=$(( DEV_BYTES / (1024*1024*1024) ))
DEV_MIB=$(( DEV_BYTES / (1024*1024) ))

# Refuse HD-sized targets unless --force.
LARGE_THRESHOLD_GIB=64
if [ "$DEV_GIB" -gt "$LARGE_THRESHOLD_GIB" ] && [ "$ALLOW_LARGE" -ne 1 ]; then
    echo "[write_img_to_usb] ERROR: '$DEVICE' is ${DEV_GIB} GiB — larger than the" >&2
    echo "[write_img_to_usb]   ${LARGE_THRESHOLD_GIB} GiB safety threshold. This looks more like an" >&2
    echo "[write_img_to_usb]   internal disk than a USB stick. If you really mean" >&2
    echo "[write_img_to_usb]   it, re-run with --force." >&2
    exit 1
fi

# Reject image-larger-than-target (would corrupt or truncate).
if [ "$IMG_BYTES" -gt "$DEV_BYTES" ]; then
    echo "[write_img_to_usb] ERROR: image (${IMG_MB} MiB) does not fit on '$DEVICE'" >&2
    echo "[write_img_to_usb]   (device is ${DEV_MIB} MiB)." >&2
    exit 1
fi

# ---- Show device summary + partitions + confirm -------------------------
echo
echo "[write_img_to_usb] Target: $DEVICE"
echo "[write_img_to_usb]   size:    ${DEV_GIB} GiB  (${DEV_BYTES} bytes)"

# Best-effort vendor + model + bus type, no crash if lsblk is older.
DEV_INFO=$(lsblk -dn -o NAME,SIZE,MODEL,VENDOR,TRAN "$DEVICE" 2>/dev/null || true)
if [ -n "$DEV_INFO" ]; then
    echo "[write_img_to_usb]   info:    $DEV_INFO"
fi

echo
echo "[write_img_to_usb] Current partition table on $DEVICE:"
sudo lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DEVICE" 2>/dev/null \
    | sed 's/^/    /' || true
echo

if [ "$ASSUME_YES" -ne 1 ]; then
    echo "[write_img_to_usb] About to OVERWRITE '$DEVICE' with '$IMG_PATH'."
    echo "[write_img_to_usb] EVERYTHING on $DEVICE will be destroyed."
    printf "[write_img_to_usb] Type 'yes' to continue: "
    read -r REPLY
    if [ "$REPLY" != "yes" ]; then
        echo "[write_img_to_usb] aborted (no changes written)." >&2
        exit 1
    fi
fi

# ---- Unmount auto-mounted partitions ------------------------------------
for part in $(lsblk -ln -o NAME "$DEVICE" 2>/dev/null | tail -n +2); do
    full="/dev/$part"
    if mount | grep -q "^$full "; then
        echo "[write_img_to_usb] unmounting $full"
        sudo umount "$full" || true
    fi
done

# ---- Write --------------------------------------------------------------
echo "[write_img_to_usb] writing... (this may take a minute or two)"
sudo dd if="$IMG_PATH" of="$DEVICE" bs=4M conv=fsync status=progress
sudo sync

echo
echo "[write_img_to_usb] Done. '$DEVICE' now carries Hamnix."
echo "[write_img_to_usb] Eject it cleanly (sudo eject $DEVICE) before unplugging."
echo "[write_img_to_usb] See docs/REAL_HARDWARE.md for boot + firmware setup."
