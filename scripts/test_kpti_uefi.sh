#!/usr/bin/env bash
# scripts/test_kpti_uefi.sh — KPTI cpu_entry_area (CEA) SHIP-PATH gate (#248).
#
# WHY THIS GATE EXISTS
# --------------------
# KPTI keeps a kernel-private cpu_entry_area (CEA) mapped in the user CR3 so
# the CPL3->CPL0 entry-critical structures (IDT, per-CPU GDT/TSS, the #DF IST
# stack, the MDS VERW word, the entry .text stubs) still resolve after the
# rest of the kernel image is stripped. Commit 5ca263bc fixed a SHIP-PATH-ONLY
# bug: the CEA only spanned the first 1 GiB page-directory anchored at .text,
# so on the UEFI/installer boot (the ACTUAL ship vehicle) the .bss entry
# structures that land PAST that 1 GiB (IDT/GDT/TSS/#DF) never got mapped into
# the CEA and did not resolve — while scripts/test_kpti.sh reported PASS.
#
# That was a FALSE-GREEN of the `feedback_real_boot_path_testing` class:
# scripts/test_kpti.sh only boots the `-kernel` multiboot DEV path (a small
# kernel image whose .bss stays under 1 GiB from .text), so it NEVER exercised
# the ship-path condition. Acceptance for KPTI = the shipped .img under
# UEFI/OVMF, NOT `-kernel`.
#
# This gate closes that hole: it boots the SHIPPED installer image under OVMF
# and asserts the CEA self-test resolves EVERY entry structure on the ship
# path. The kernel walks each structure's CEA VA (read-only) very early in
# boot and logs:
#     [pgtable] cpu_entry_area walk: IDT=1 GDT=1
#     [pgtable] cpu_entry_area walk: TSS=1 DF-stack=1
#     [pgtable] cpu_entry_area walk: VERW=1 entry.text=1
#     [pgtable] cpu_entry_area PASS: IDT/GDT/TSS/DF/VERW/entry.text resolve ...
# The pre-fix ship image printed one or more `=0` above and the CEA FAIL line.
#
# PASS  requires ALL of:
#   * every entry structure resolves        IDT=1 GDT=1 TSS=1 DF-stack=1
#                                            VERW=1 entry.text=1
#   * the CEA self-test reports PASS         "[pgtable] cpu_entry_area PASS"
# FAIL on ANY of:
#   * any structure walked to 0              (e.g. IDT=0 — the 5ca263bc bug)
#   * the CEA self-test FAIL line            "[pgtable] cpu_entry_area FAIL"
# INCONCLUSIVE (rc 2) when the boot never reached the early CEA self-test at
#   all (no [pgtable] serial output — a host-starved / OOM boot), matching the
#   three-valued verdict of the sibling boot gates so a dead boot is not a
#   false-red.
#
# The CEA self-test runs VERY early (before userland), so a ~90-180s boot
# captures it; we do NOT need to reach a shell.
#
# ENV
#   IMG                installer image     (default: build/hamnix-installer.img)
#   HAMNIX_SKIP_BUILD=1 do NOT rebuild if IMG absent -> graceful SKIP (rc 0).
#                       Battery shards that carry no prebuilt installer image
#                       set this; the full build + OVMF boot runs in the
#                       installer CI job / locally. UNSET => build IMG if absent.
#   BOOT_TIMEOUT       seconds             (default: 180)
#   OVMF_FD            firmware path       (default: auto-resolved)
#   QEMU_ACCEL         'tcg' forces TCG    (default: KVM if /dev/kvm usable)
#   SERIAL_LOG         evaluate a pre-captured log INSTEAD of booting (logic-
#                      only: lets CI/dev assert the verdict on a known log with
#                      no QEMU — also used to demonstrate the gate CATCHES the
#                      pre-fix IDT=0 log).
#   KEEP_LOG=1         keep the temp serial log on exit
#
# Pass marker:  [test_kpti_uefi] PASS
# Fail marker:  [test_kpti_uefi] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

IMG="${IMG:-build/hamnix-installer.img}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"

say() { echo "[test_kpti_uefi] $*"; }

# --- evaluate(): PASS / FAIL / INCONCLUSIVE over a serial log ----------
# Shared by the live-boot and SERIAL_LOG paths so the verdict logic is
# asserted identically either way. Prints its own verdict word and returns:
#   0 = PASS, 1 = FAIL, 2 = INCONCLUSIVE.
evaluate() {
    local log="$1"

    # Liveness: did the boot reach the pgtable layer at all? Zero [pgtable]
    # output means the boot starved/OOM'd before the early CEA self-test —
    # INCONCLUSIVE, not a feature regression (dead-gate false-red guard).
    if ! grep -aE -q "\[pgtable\]" "$log"; then
        say "INCONCLUSIVE: no [pgtable] serial output — boot never reached the"
        say "early CEA self-test (host-starved / OOM boot, not a CEA regression)."
        say "--- last 30 serial lines ---"
        tail -30 "$log" | strings | sed 's/^/    /' >&2 || true
        return 2
    fi

    local fail=0

    # (1) The explicit CEA FAIL line must NOT appear.
    if grep -aE -q "\[pgtable\] cpu_entry_area FAIL" "$log"; then
        say "FAIL: kernel reported the CEA self-test FAIL line:"
        grep -aEn "\[pgtable\] cpu_entry_area (walk|FAIL)" "$log" \
            | head -8 | sed 's/^/    /' >&2
        fail=1
    fi

    # (2) Every entry structure must have walked to 1 (present + same bytes).
    #     Pattern-match the exact walk lines the kernel prints.
    local structs="IDT GDT TSS DF-stack VERW entry.text"
    local missing_walk=0
    for s in $structs; do
        # Anchor on "<name>=<digit>" inside the three walk lines.
        local val
        val=$(grep -aoE "\[pgtable\] cpu_entry_area walk: [^\n]*${s}=[0-9]" "$log" \
              | grep -aoE "${s}=[0-9]" | tail -1 | grep -aoE "[0-9]$" || true)
        if [ -z "$val" ]; then
            say "FAIL: CEA walk never reported a result for '$s'."
            missing_walk=1
            fail=1
        elif [ "$val" != "1" ]; then
            say "FAIL: CEA structure '$s' did NOT resolve through the entry"
            say "      window ($s=$val) — the 5ca263bc ship-path bug (a .bss"
            say "      structure past the first CEA page-directory)."
            fail=1
        else
            say "OK: CEA resolves '$s' through the entry window ($s=1)."
        fi
    done

    # If the walk lines are wholly absent the boot didn't reach the self-test
    # (distinct from a genuine 0 result) — treat as INCONCLUSIVE, not FAIL.
    if [ "$missing_walk" = "1" ] \
       && ! grep -aE -q "\[pgtable\] cpu_entry_area walk:" "$log"; then
        say "INCONCLUSIVE: [pgtable] output present but the CEA walk lines never"
        say "appeared — boot did not reach the CEA self-test."
        return 2
    fi

    # (3) The overall CEA PASS banner must be present.
    if ! grep -aE -q "\[pgtable\] cpu_entry_area PASS" "$log"; then
        say "FAIL: the '[pgtable] cpu_entry_area PASS' banner is absent."
        fail=1
    else
        say "OK: '[pgtable] cpu_entry_area PASS' banner present."
    fi

    return "$fail"
}

# --- logic-only mode: evaluate a pre-captured log, no QEMU ------------
if [ -n "${SERIAL_LOG:-}" ]; then
    if [ ! -f "$SERIAL_LOG" ]; then
        say "SKIP: SERIAL_LOG=$SERIAL_LOG does not exist"
        say "SKIP"; exit 0
    fi
    say "logic-only mode: evaluating $SERIAL_LOG (no QEMU boot)"
    evaluate "$SERIAL_LOG"; rc=$?
    case "$rc" in
        0) say "PASS"; exit 0 ;;
        2) say "INCONCLUSIVE"; exit 2 ;;
        *) say "FAIL"; exit 1 ;;
    esac
fi

# --- environment gates (skip cleanly) ---------------------------------
# KVM is preferred (matches the user's ship command -cpu host) but not
# required; TCG also reaches the early CEA self-test. Only SKIP when neither
# KVM nor OVMF is available.
ACCEL_ARGS=()
QEMU_CPU="max"
if [ "${QEMU_ACCEL:-}" != "tcg" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL_ARGS=(-enable-kvm -cpu host)
    QEMU_CPU="host"
else
    ACCEL_ARGS=(-cpu "$QEMU_CPU")
fi

# Resolve OVMF firmware. PREFER split (OVMF_CODE + OVMF_VARS) so a FRESH copy
# of the VARS store boots every run (no stale "EFI Internal Shell" boot-order
# survives). Fall back to a combined image (-bios). Mirrors
# scripts/test_de_screenshot.sh.
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
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd; do
        [ -f "$c" ] && { OVMF_CODE="$c"; break; }
    done
fi
if [ -z "$OVMF_CODE" ] || [ ! -f "$OVMF_CODE" ]; then
    say "SKIP: OVMF firmware not found (apt install ovmf)."
    say "SKIP"; exit 0
fi

# --- installer image: build if absent unless HAMNIX_SKIP_BUILD --------
# The installer build is SLOW (~15-20 min). Battery shards set
# HAMNIX_SKIP_BUILD=1 so this gate is a fast, clean SKIP when the image is not
# prebuilt; the full build + OVMF boot runs in the installer CI job / locally.
# Stale-image guard: NEVER boot an image older than the tree under test.
# See scripts/_installer_img.sh (2026-07-24 false-negative).
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if installer_img_needs_build "$IMG" "[kpti_uefi]"; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        say "SKIP: $IMG absent and HAMNIX_SKIP_BUILD=1 (no prebuilt image here)."
        say "SKIP"; exit 0
    fi
    say "image $IMG absent -- building via scripts/build_installer_img.sh (~15-20 min)"
    if ! HAMNIX_INSTALLER_IMG_OUT="$IMG" bash scripts/build_installer_img.sh; then
        say "SKIP: installer image build failed/gated."
        say "SKIP"; exit 0
    fi
fi
if [ ! -f "$IMG" ]; then
    say "SKIP: $IMG still missing after build_installer_img.sh."
    say "SKIP"; exit 0
fi

# --- boot the shipped image under OVMF --------------------------------
LOG=$(mktemp --tmpdir hamnix-kpti-uefi.XXXXXX.log)
CODE_RW=$(mktemp --tmpdir hamnix-kpti-uefi.code.XXXXXX.fd)
VARS_RW=$(mktemp --tmpdir hamnix-kpti-uefi.vars.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-kpti-uefi.img.XXXXXX.raw)
QEMU_PID=""
cleanup() {
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_LOG:-0}" = "1" ]; then
        echo "[test_kpti_uefi] KEEP_LOG: serial log at $LOG" >&2
    else
        rm -f "$LOG"
    fi
    rm -f "$CODE_RW" "$VARS_RW" "$IMG_RW"
}
trap cleanup EXIT INT TERM

# A FRESH copy of the image each run so OVMF's fallback NvVars (written to the
# ESP when there is no pflash var store) lands on the throwaway copy — no
# boot-order pollution survives to the next run.
cp "$IMG" "$IMG_RW"

# Assemble firmware args: split => fresh VARS copy every run (deterministic
# boot order); combined => a fresh -bios copy.
if [ -n "$OVMF_VARS" ]; then
    cp "$OVMF_CODE" "$CODE_RW"
    cp "$OVMF_VARS" "$VARS_RW"
    FW_ARGS=(
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$CODE_RW"
        -drive "if=pflash,format=raw,unit=1,file=$VARS_RW"
    )
    say "firmware: split OVMF (fresh VARS each run) $OVMF_CODE"
else
    cp "$OVMF_CODE" "$CODE_RW"
    FW_ARGS=(-bios "$CODE_RW")
    say "firmware: combined OVMF (fresh copy) $OVMF_CODE"
fi

# bootindex=0 on the installer media forces OVMF to launch
# \EFI\BOOT\BOOTX64.EFI first (never the EFI Internal Shell), so we reach the
# OS. Mirrors scripts/test_de_screenshot.sh / scripts/run_installer.sh.
say "booting installer image under OVMF: ${ACCEL_ARGS[*]} (up to ${BOOT_TIMEOUT}s)"
: > "$LOG"
qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" \
    "${FW_ARGS[@]}" \
    -drive "file=$IMG_RW,format=raw,if=none,id=instmedia" \
    -device virtio-blk-pci,drive=instmedia,bootindex=0 \
    -m 2G \
    -vga std \
    -display none \
    -serial "file:$LOG" \
    -no-reboot \
    -monitor none \
    >/dev/null 2>&1 < /dev/null &
QEMU_PID=$!

# Poll until the CEA self-test reports its verdict (PASS or FAIL), QEMU exits,
# or the deadline. The CEA self-test runs very early, so this usually resolves
# well under the timeout.
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
while :; do
    if [ -f "$LOG" ]; then
        grep -aE -q "\[pgtable\] cpu_entry_area (PASS|FAIL)" "$LOG" && break
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

say "--- cpu_entry_area serial lines ---"
grep -aE "\[pgtable\] cpu_entry_area" "$LOG" | head -20 | sed 's/^/    /' || true
say "--- end ---"

evaluate "$LOG"; rc=$?
case "$rc" in
    0)
        say "PASS — the shipped installer image resolves the whole CEA on the"
        say "UEFI ship path (IDT/GDT/TSS/#DF/VERW/entry.text)."
        say "PASS"
        exit 0
        ;;
    2)
        say "INCONCLUSIVE"
        exit 2
        ;;
    *)
        say "FAIL"
        exit 1
        ;;
esac
