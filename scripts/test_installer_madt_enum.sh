#!/usr/bin/env bash
# scripts/test_installer_madt_enum.sh — ACPI MADT enumeration regression (#105).
#
# WHY THIS GATE EXISTS
# --------------------
# The installer image boots under UEFI/OVMF. Under UEFI the ACPI RSDP is
# NOT in the legacy EBDA / 0xE0000..0xFFFFF BIOS window (that window is the
# firmware volume) — the firmware advertises the RSDP ONLY through an
# EFI_CONFIGURATION_TABLE entry keyed by the ACPI GUID. drivers/acpi/acpi.ad
# used to scan ONLY the legacy window, so on every UEFI boot it found no
# RSDP -> no MADT -> acpi_cpu_count()==0. SMP bring-up then fell back to
# blindly probing a single hardcoded AP (APIC id 1), capping EVERY multicore
# machine at 2 cores no matter how many it has (`-smp 4` -> only 2 online),
# and the IOAPIC layer fell back to a single-IOAPIC assumption.
#
# The pre-existing SMP gate (scripts/test_smp.sh) boots via the `-kernel`
# GRUB/SeaBIOS shim, where the LEGACY scan DOES find the RSDP — so it stayed
# green and never exercised the UEFI path. This gate closes that hole: it
# boots the SHIPPED installer image under OVMF and asserts the MADT was
# really enumerated from the firmware, not faked by the fallback.
#
# PASS  requires ALL of:
#   * a real RSDP was located          (NOT "acpi: no RSDP")
#   * MADT enumerated N>=EXPECT_CPUS    "acpi: N CPU(s) cached from MADT"
#   * SMP consumed a non-zero count     "SMP: MADT reports N CPU(s)", N>=EXPECT
#   * >=1 IOAPIC enumerated from MADT   "acpi: N IOAPIC(s) in MADT", N>=1
#   * the BSP reached the shell         "[hamsh-alive]"
# FAIL on ANY of the pre-fix signatures:
#   "acpi: no RSDP" / "SMP: MADT reports 0 CPU(s)" /
#   "no MADT CPU list" / "APIC ID 1 fallback" / "no MADT IOAPIC list"
#
# ENV
#   IMG           installer image        (default: build/hamnix-installer.img)
#   SKIP_BUILD=1  do NOT rebuild if IMG absent -> graceful SKIP (rc 0). Used
#                 by battery shards that carry no prebuilt installer image;
#                 the full build + OVMF boot runs in the installer CI job.
#   SMP           vCPU count             (default: 2 — the must-pass count;
#                 3+ exposes the SEPARATE #12/#13 AP-scheduler bug, so the
#                 gate stays at 2 by default)
#   EXPECT_CPUS   min CPUs to demand     (default: = SMP)
#   BOOT_TIMEOUT  seconds                (default: 200)
#   OVMF_FD       firmware path          (default: /usr/share/ovmf/OVMF.fd)
#   QEMU_CPU      cpu model              (default: max — carries SMAP for TCG)
#   QEMU_ACCEL=kvm  opt-in KVM (needs /dev/kvm); default TCG so CI is stable
#   SERIAL_LOG    evaluate a pre-captured log INSTEAD of booting (logic-only:
#                 lets CI/dev assert the verdict on a known log with no QEMU)
#   KEEP_LOG=1    keep the temp serial log on exit
#
# Pass marker:  [test_installer_madt_enum] PASS
# Fail marker:  [test_installer_madt_enum] FAIL

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

IMG="${IMG:-build/hamnix-installer.img}"
SMP="${SMP:-2}"
EXPECT_CPUS="${EXPECT_CPUS:-$SMP}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-200}"
OVMF_FD="${OVMF_FD:-/usr/share/ovmf/OVMF.fd}"
QEMU_CPU="${QEMU_CPU:-max}"
QEMU_ACCEL="${QEMU_ACCEL:-}"

HEARTBEAT_RE='\[hamsh-alive\]'
# The pre-fix (no-RSDP / fallback) signatures — ANY of these means the MADT
# was NOT properly enumerated and the OS is running on the blind fallback.
FALLBACK_RE='acpi: no RSDP|SMP: MADT reports 0 CPU\(s\)|no MADT CPU list|APIC ID 1 fallback|no MADT IOAPIC list'

say() { echo "[test_installer_madt_enum] $*"; }

# --- evaluate(): PASS/FAIL verdict over a serial log ------------------
# Shared by the live-boot and SERIAL_LOG paths so the verdict logic is
# asserted identically either way. Returns 0=PASS, 1=FAIL.
evaluate() {
    local log="$1"
    local fail=0

    # (1) No pre-fix fallback signature may appear.
    if grep -aE -q "$FALLBACK_RE" "$log"; then
        say "FAIL: pre-fix fallback signature present (MADT not enumerated):"
        grep -aEn "$FALLBACK_RE" "$log" | head -6 | sed 's/^/    /' >&2
        fail=1
    fi

    # (2) A real RSDP + MADT CPU list of at least EXPECT_CPUS entries.
    local cached
    cached=$(grep -aoE 'acpi: [0-9]+ CPU\(s\) cached from MADT' "$log" \
             | grep -aoE '[0-9]+' | head -1 || true)
    if [ -z "$cached" ]; then
        say "FAIL: no 'acpi: N CPU(s) cached from MADT' line — MADT never parsed."
        fail=1
    elif [ "$cached" -lt "$EXPECT_CPUS" ]; then
        say "FAIL: MADT cached $cached CPU(s), expected >= $EXPECT_CPUS."
        fail=1
    else
        say "OK: MADT enumerated $cached CPU(s) (>= $EXPECT_CPUS)."
    fi

    # (3) SMP consumed a non-zero MADT count.
    local reports
    reports=$(grep -aoE 'SMP: MADT reports [0-9]+ CPU\(s\)' "$log" \
              | grep -aoE '[0-9]+' | head -1 || true)
    if [ -z "$reports" ]; then
        say "FAIL: no 'SMP: MADT reports N CPU(s)' line."
        fail=1
    elif [ "$reports" -lt "$EXPECT_CPUS" ]; then
        say "FAIL: SMP read $reports CPU(s) from MADT, expected >= $EXPECT_CPUS."
        fail=1
    else
        say "OK: SMP bring-up read $reports CPU(s) from the MADT."
    fi

    # (4) At least one IOAPIC enumerated from the MADT type-1 entries.
    local ioapics
    ioapics=$(grep -aoE 'acpi: [0-9]+ IOAPIC\(s\) in MADT' "$log" \
              | grep -aoE '[0-9]+' | head -1 || true)
    if [ -z "$ioapics" ] || [ "$ioapics" -lt 1 ]; then
        say "FAIL: no IOAPIC enumerated from the MADT (ioapics='${ioapics:-none}')."
        fail=1
    else
        say "OK: $ioapics IOAPIC(s) enumerated from the MADT."
    fi

    # (5) The BSP actually reached the shell (boot stayed alive).
    if ! grep -aE -q "$HEARTBEAT_RE" "$log"; then
        say "FAIL: no '[hamsh-alive]' heartbeat — boot did not reach the shell."
        say "--- last 30 serial lines ---"
        tail -30 "$log" | strings | sed 's/^/    /' >&2
        fail=1
    else
        say "OK: '[hamsh-alive]' heartbeat present."
    fi

    return "$fail"
}

# --- logic-only mode: evaluate a pre-captured log, no QEMU ------------
if [ -n "${SERIAL_LOG:-}" ]; then
    if [ ! -f "$SERIAL_LOG" ]; then
        say "FAIL: SERIAL_LOG=$SERIAL_LOG does not exist"
        say "FAIL"; exit 1
    fi
    say "logic-only mode: evaluating $SERIAL_LOG (no QEMU boot)"
    if evaluate "$SERIAL_LOG"; then say "PASS"; exit 0; else say "FAIL"; exit 1; fi
fi

# --- ensure the installer image exists --------------------------------
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$IMG" "[installer_madt_enum]"; then
    if [ "${SKIP_BUILD:-0}" = "1" ]; then
        say "SKIP: $IMG absent and SKIP_BUILD=1 (no prebuilt image on this shard)."
        say "SKIP"; exit 0
    fi
    say "image $IMG absent -- building via scripts/build_installer_img.sh (~14 min)"
    HAMNIX_INSTALLER_IMG_OUT="$IMG" bash scripts/build_installer_img.sh
fi
if [ ! -f "$IMG" ]; then
    say "FAIL: $IMG still missing after build_installer_img.sh."
    say "FAIL"; exit 1
fi

# --- OVMF firmware ----------------------------------------------------
if [ ! -f "$OVMF_FD" ]; then
    if [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ ! -f "$OVMF_FD" ]; then
    say "SKIP: OVMF firmware not found (tried $OVMF_FD; apt install ovmf)."
    say "SKIP"; exit 0
fi

ACCEL_ARGS=()
if [ "$QEMU_ACCEL" = "kvm" ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ACCEL_ARGS=(-enable-kvm)
        # KVM host CPU exposes the real feature set.
        [ "$QEMU_CPU" = "max" ] && QEMU_CPU=host
    else
        say "QEMU_ACCEL=kvm requested but /dev/kvm not accessible; using TCG."
    fi
fi

LOG=$(mktemp --tmpdir hamnix-madt-enum.XXXXXX.log)
OVMF_RW=$(mktemp --tmpdir hamnix-madt-enum.ovmf.XXXXXX.fd)
QEMU_PID=""
cleanup() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_LOG:-0}" = "1" ]; then
        echo "[test_installer_madt_enum] KEEP_LOG: serial log at $LOG" >&2
    else
        rm -f "$LOG"
    fi
    rm -f "$OVMF_RW"
}
trap cleanup EXIT INT TERM
cp "$OVMF_FD" "$OVMF_RW"

say "booting installer image under OVMF: -smp $SMP -cpu $QEMU_CPU ${ACCEL_ARGS[*]:-(TCG)}"
: > "$LOG"
qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" \
    -cpu "$QEMU_CPU" \
    -bios "$OVMF_RW" \
    -drive "file=$IMG,format=raw,if=virtio" \
    -m 1G \
    -smp "$SMP" \
    -vga std \
    -display none \
    -serial "file:$LOG" \
    -no-reboot \
    -monitor none \
    >/dev/null 2>&1 &
QEMU_PID=$!

# Poll until heartbeat, a fallback signature, QEMU exit, or the deadline.
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
while :; do
    if [ -f "$LOG" ]; then
        grep -aE -q "$HEARTBEAT_RE" "$LOG" && break
        grep -aE -q "$FALLBACK_RE" "$LOG" && break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then QEMU_PID=""; break; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        say "deadline reached (${BOOT_TIMEOUT}s)."
        break
    fi
    sleep 2
done

if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
fi

say "--- MADT / SMP serial lines ---"
grep -aE 'acpi:|ACPI:|MADT|SMP:|cpus_online|IOAPIC|hamsh-alive' "$LOG" \
    | head -40 | sed 's/^/    /' || true
say "--- end ---"

if evaluate "$LOG"; then
    say "PASS — MADT enumerated from firmware (>= $EXPECT_CPUS CPUs, >=1 IOAPIC); BSP reached shell."
    say "PASS"
    exit 0
else
    say "FAIL"
    exit 1
fi
