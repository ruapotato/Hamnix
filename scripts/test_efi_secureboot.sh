#!/usr/bin/env bash
# scripts/test_efi_secureboot.sh — task #171.
#
# Proves two new pieces of REAL functionality, both gated on /etc/efi-test
# (planted by build_initramfs.py under ENABLE_EFI_TEST=1) and run from
# init/main.ad at boot:37.efi:
#
#   A. EFI RUNTIME SERVICES. The UEFI boot stub (arch/x86/boot/efi_stub.S)
#      captures the EFI_SYSTEM_TABLE at entry and, via handoff slot +72,
#      stashes SystemTable + RuntimeServices + ConfigurationTable into the
#      kernel's .boot.data efi_rt_info struct. After ExitBootServices the
#      kernel calls the firmware's GetTime and GetVariable through that
#      RuntimeServices pointer (Microsoft x64 ABI thunks efi_ms_call4 /
#      efi_ms_call5 in boot_info_asm.S), using the firmware's identity-
#      mapped physical addresses (the kernel keeps a 512-GiB low identity
#      map live in CR3, so no SetVirtualAddressMap is needed). OVMF wires
#      its RTC to the host clock, so GetTime returns a real wall-clock.
#
#   B. SECURE BOOT IMAGE VERIFICATION. lib/secureboot/authenticode.ad
#      recomputes the Authenticode PE/COFF image hash (SHA-256 over the
#      image minus the CheckSum field + Certificate Table dir entry) of a
#      build-time-generated, test-signed PE blob and verifies a real
#      RSASSA-PKCS1-v1.5-SHA256 signature against an embedded self-signed
#      trust anchor (REUSING lib/x509 + lib/rsa). It ACCEPTS the correctly
#      signed blob and REJECTS a one-byte-tampered blob. The fixtures are
#      generated fresh per build by scripts/gen_secureboot_blob.py.
#
# BOOT PATH: EFI runtime calls require REAL firmware, so this test boots
# the ESP-only installer medium build/hamnix-installer.img — a real
# signed-bootable ESP — under OVMF (UEFI) via virtio-blk + KVM. The
# /etc/efi-test marker + Secure Boot fixtures are planted into the
# INSTALLER kernel's initramfs by building the medium with ENABLE_EFI_TEST=1
# (build_initramfs.py reads that env even through build_installer_img.sh).
# The kernel self-tests run during start_kernel (before the interactive
# shell), so their [efi]/[secureboot] markers land early in the serial log.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm or OVMF firmware is unavailable.
#
# PASS markers required:  [efi] PASS   AND   [secureboot] PASS
# Single success banner:  prints both, exits 0; any failure exits non-zero.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

BOOT_WAIT="${BOOT_WAIT:-120}"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_efi] SKIP: /dev/kvm absent (KVM required for the OVMF boot)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_efi] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- build the installer medium WITH the /etc/efi-test marker + fixtures -
# build_installer_img.sh internally runs build_initramfs.py for the
# installer kernel; ENABLE_EFI_TEST=1 (exported here) reaches that python
# process even through the `env` prefix, planting the marker + Secure Boot
# fixtures into the installer kernel's initramfs. The marker is read from
# the initramfs at boot (init/main.ad boot:37.efi), so the medium's own
# kernel runs the self-tests.
echo "[test_efi] (1/3) generating Secure Boot fixtures (self-check)"
python3 scripts/gen_secureboot_blob.py

echo "[test_efi] (2/3) building installer medium with ENABLE_EFI_TEST=1"
HAMNIX_INSTALLER_IMG="${HAMNIX_INSTALLER_IMG:-build/hamnix-installer.img}"
rm -f "$HAMNIX_INSTALLER_IMG"
ENABLE_EFI_TEST=1 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
if [ ! -f "$HAMNIX_INSTALLER_IMG" ]; then
    echo "[test_efi] FAIL: $HAMNIX_INSTALLER_IMG missing after build_installer_img.sh." >&2
    exit 1
fi
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
# A pre-existing image must never be validated silently — see
# scripts/_installer_img.sh (2026-07-24 stale-image false negative).
installer_img_warn_if_stale "$HAMNIX_INSTALLER_IMG" "[efi_secureboot]"

# OVMF persists UEFI variables back into its file, and the disk is opened
# r/w — copy both so a re-run starts pristine.
OVMF_RW=$(mktemp --tmpdir hamnix-efi.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-efi.disk.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-efi.XXXXXX.log)
cp "$OVMF_FD" "$OVMF_RW"
cp "$HAMNIX_INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW"
}
trap cleanup EXIT

echo "[test_efi] (3/3) booting the installer medium under OVMF (UEFI) + KVM"
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 512M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1 &
QEMU_PID=$!

# Wait until BOTH self-tests have printed their terminal banner (PASS or
# FAIL), or qemu exits, or the timeout elapses.
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q -E '\[secureboot\] (PASS|FAIL)' "$LOG" \
       && grep -a -q -E '\[efi\] (PASS|FAIL)' "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        # qemu exited — give the log a beat to flush, then assess below.
        booted=1
        break
    fi
    sleep 1
done

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

echo "[test_efi] --- efi / secureboot self-test output ---"
grep -a -E '\[efi\]|\[secureboot\]' "$LOG" || true
echo "[test_efi] --- end ---"

fail=0

if [ "$booted" -ne 1 ]; then
    echo "[test_efi] FAIL: self-test banners not seen within ${BOOT_WAIT}s." >&2
    echo "----- serial log tail -----" >&2
    tail -100 "$LOG" >&2
    fail=1
fi

# Any explicit internal failure is fatal.
if grep -a -q -F "[efi] FAIL" "$LOG"; then
    echo "[test_efi] FAIL: EFI runtime self-test reported a failure" >&2
    fail=1
fi
if grep -a -q -F "[secureboot] FAIL" "$LOG"; then
    echo "[test_efi] FAIL: Secure Boot self-test reported a failure" >&2
    fail=1
fi

# Part A required evidence.
if grep -a -q -F "[efi] GetTime OK" "$LOG"; then
    echo "[test_efi] PASS: firmware GetTime returned a real wall-clock."
else
    echo "[test_efi] FAIL: no '[efi] GetTime OK' — RuntimeServices->GetTime did not run." >&2
    fail=1
fi
if grep -a -q -F "[efi] GetVariable SecureBoot" "$LOG"; then
    echo "[test_efi] PASS: firmware GetVariable(SecureBoot) call reached firmware."
else
    echo "[test_efi] FAIL: no GetVariable(SecureBoot) evidence." >&2
    fail=1
fi
if grep -a -q -F "[efi] PASS" "$LOG"; then
    echo "[test_efi] PASS: [efi] PASS banner present."
else
    echo "[test_efi] FAIL: [efi] PASS banner missing." >&2
    fail=1
fi

# Part B required evidence: accept-good AND reject-bad.
if grep -a -q -F "[secureboot] ACCEPT good blob OK" "$LOG"; then
    echo "[test_efi] PASS: verifier ACCEPTED the correctly-signed blob."
else
    echo "[test_efi] FAIL: verifier did not accept the good blob." >&2
    fail=1
fi
if grep -a -q -F "[secureboot] REJECT tampered blob OK" "$LOG"; then
    echo "[test_efi] PASS: verifier REJECTED the tampered blob."
else
    echo "[test_efi] FAIL: verifier did not reject the tampered blob." >&2
    fail=1
fi
if grep -a -q -F "[secureboot] PASS" "$LOG"; then
    echo "[test_efi] PASS: [secureboot] PASS banner present."
else
    echo "[test_efi] FAIL: [secureboot] PASS banner missing." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_efi] FAIL (serial log: $LOG)" >&2
    exit 1
fi

# Surface the single canonical PASS lines the brief asks for.
echo "[efi] PASS"
echo "[secureboot] PASS"
echo "[test_efi] PASS — EFI runtime services (GetTime/GetVariable) + Secure Boot image verification both proven under OVMF"
rm -f "$LOG"
exit 0
