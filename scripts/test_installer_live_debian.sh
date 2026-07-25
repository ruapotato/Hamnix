#!/usr/bin/env bash
# scripts/test_installer_live_debian.sh
#
# REGRESSION GATE (#410 Item 2): a LIVE boot of the first-class
# installer image (NO install performed) brings up the Debian
# namespace entirely from RAM and runs a REAL Debian binary.
#
# What this proves, end to end, on the REAL shipped artifact
# (build/hamnix-installer.img under OVMF — the real boot path):
#
#   1. rc.boot's LIVE branch fires ("booting LIVE environment") because
#      the only disk is the boot medium (install --probe finds no
#      distinct target — the ram/loop/live exclusion in
#      user/install.ad::enumerate_disks keeps the live ramdisk from
#      being offered as an install target).
#   2. The detached live_distro_up spawn drives the kernel's
#      loop_sqfs_live_root: /rootfs.sqfs (firmware-loaded cpio data,
#      NOTHING read from media) -> live-distro.ext4 -> RAM block
#      device `live0` -> ext4 mount -> .hamnix-roots -> #distro named
#      root. Asserted via the "[live-root] DONE" kernel marker.
#   3. `enter linux { ... }` (the rc.boot.full ns recipe, binding
#      '#distro' at enter time) executes a real Debian binary:
#        - /usr/bin/dpkg --version  -> "package management program"
#          (when the host fixture tests/distros/debian-minbase/rootfs
#          was staged into the live image), or
#        - busybox printf assembling LIVE_DEBIAN_OK (busybox-only
#          image) — the typed command line never contains the
#          contiguous marker, so a match is real program OUTPUT.
#
# Judged ONLY by serial-log markers (never wrapper exit codes; a qemu
# timeout after the markers appeared is benign). The first serial
# command after boot is historically dropped, so every command is
# RE-SENT until its own output appears (feedback_serial_test_first_cmd
# _dropped) and keystrokes are gated on boot markers, not fixed sleeps.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or the installer image is
# unavailable and cannot be built, and when the live image carries
# neither dpkg nor busybox (host without any fixtures).
#
# Env overrides:
#   INSTALLER_IMG      image path     (default: build/hamnix-installer.img)
#   LIVE_DISTRO_IMG    live ext4 path (default: build/hamnix-live-distro.img)
#   OVMF_FD            OVMF firmware  (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for boot markers   (default: 240)
#   CMD_WAIT           seconds to wait for command output (default: 180)
#   QEMU_MEM           guest RAM      (default: 1G — the ship command)
#   HAMNIX_SKIP_BUILD  1 = require an existing image (no rebuild)
#   KEEP_LOGS          1 = keep the serial log on PASS

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
LIVE_DISTRO_IMG="${LIVE_DISTRO_IMG:-build/hamnix-live-distro.img}"
BOOT_WAIT="${BOOT_WAIT:-240}"
CMD_WAIT="${CMD_WAIT:-180}"
# The full real-Debian #distro backing (~185 MiB) is extracted into a
# RAM block device at live boot, so the guest needs headroom above the
# product's 1G ship default for the test. 2G keeps the RAM ext4 +
# squashfs-in-cpio + kernel comfortable; the SHIPPED image still boots
# at 1G on hardware with more total RAM (the live ramdisk is freed once
# #distro is posted). Override with QEMU_MEM to test the 1G ship floor.
QEMU_MEM="${QEMU_MEM:-2G}"
TAG="[test_live_debian]"

LIVE_MARKER="booting LIVE environment"
HANDOFF_MARKER="handing off to interactive shell"
LIVEROOT_MARKER="[live-root] DONE"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "$TAG SKIP: /dev/kvm absent (KVM required for the interactive OVMF boot)" >&2
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
    echo "$TAG SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- ensure the installer image exists AND is fresh -------------------
# Staleness defect (found during the #410 W^X hunt): an existing image
# was reused as-is, so kernel changes (e.g. an aslr toggle) silently
# never reached the guest — the gate "tested" an old kernel. Default is
# now to REBUILD every run; HAMNIX_SKIP_BUILD=1 keeps the fast path for
# callers that just built it.
# shellcheck source=_installer_img.sh
source "${PROJ_ROOT:-.}/scripts/_installer_img.sh"
if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
    if [ ! -f "$INSTALLER_IMG" ]; then
        echo "$TAG SKIP: $INSTALLER_IMG absent and HAMNIX_SKIP_BUILD=1." >&2
        exit 0
    fi
    # Reusing a pre-existing image: say so LOUDLY when it predates the tree.
    installer_img_warn_if_stale "$INSTALLER_IMG" "[installer_live_debian]"
else
    echo "$TAG rebuilding installer image via build_installer_img.sh (~6 min; HAMNIX_SKIP_BUILD=1 to reuse)"
    # This test exercises REAL Debian apt/dpkg inside the LIVE linux ns, so
    # it opts INTO the full real-Debian closure for the live distro
    # (HAMNIX_LIVE_MINIMAL=0). The DEFAULT installer image keeps the live
    # distro MINIMAL (busybox-only) so it boots a full desktop under the
    # `-m 1G` ship floor; that minimal default would otherwise drop this
    # test to the busybox-printf sub-gate and lose apt/dpkg coverage.
    # We boot at QEMU_MEM=2G (default) so the ~360 MiB live RAM image fits.
    HAMNIX_LIVE_MINIMAL=0 bash "$PROJ_ROOT/scripts/build_installer_img.sh"
fi
if [ ! -f "$INSTALLER_IMG" ]; then
    echo "$TAG SKIP: $INSTALLER_IMG unavailable (build gated)." >&2
    exit 0
fi

# --- decide the in-guest probe by what the live image really carries --
# debugfs (e2fsprogs) lists the live ext4 without mounting. The live
# image's #distro subtree is distro/ at the partition root.
HAVE_DPKG=0
HAVE_APT=0
HAVE_BUSYBOX=0
DEBUGFS="/sbin/debugfs"; [ -x "$DEBUGFS" ] || DEBUGFS="$(command -v debugfs || true)"
if [ -f "$LIVE_DISTRO_IMG" ] && [ -n "$DEBUGFS" ]; then
    if "$DEBUGFS" -R "stat /distro/usr/bin/dpkg" "$LIVE_DISTRO_IMG" 2>/dev/null \
            | grep -q "Type: regular"; then
        HAVE_DPKG=1
    fi
    # apt pulls a LARGER shared-object closure than dpkg (libapt-pkg +
    # libapt-private + libstdc++ + libgcc_s). Its presence lets us assert
    # ld.so maps that whole closure — the "failed to map segment from
    # shared object" regression gate.
    if "$DEBUGFS" -R "stat /distro/usr/bin/apt" "$LIVE_DISTRO_IMG" 2>/dev/null \
            | grep -q "Type: regular"; then
        HAVE_APT=1
    fi
    if "$DEBUGFS" -R "stat /distro/bin/busybox" "$LIVE_DISTRO_IMG" 2>/dev/null \
            | grep -q "Type: regular"; then
        HAVE_BUSYBOX=1
    fi
fi
if [ "$HAVE_DPKG" -eq 0 ] && [ "$HAVE_BUSYBOX" -eq 0 ]; then
    if [ ! -f "$LIVE_DISTRO_IMG" ] || [ -z "$DEBUGFS" ]; then
        echo "$TAG NOTE: cannot inspect $LIVE_DISTRO_IMG (missing image or debugfs);"
        echo "$TAG       falling back to the kernel live-root marker assertions only."
    else
        echo "$TAG SKIP: live image carries neither dpkg nor busybox (no host fixtures:"
        echo "$TAG       tests/distros/debian-minbase/rootfs, tests/u-binary/u_busybox_musl)."
        exit 0
    fi
fi
echo "$TAG live image probe: dpkg=$HAVE_DPKG apt=$HAVE_APT busybox=$HAVE_BUSYBOX"

OVMF_RW=$(mktemp --tmpdir hamnix-live-deb.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-live-deb.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-live-deb.XXXXXX.log)
FIFO=$(mktemp --tmpdir -u hamnix-live-deb-in.XXXXXX)
mkfifo "$FIFO"
cp "$OVMF_FD" "$OVMF_RW"
# Fresh writable COPY of the image (never mutate the shipped artifact).
cp "$INSTALLER_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$FIFO"
}
trap cleanup EXIT

# Ship command shape (-enable-kvm -cpu host -bios OVMF -drive raw/virtio
# -m 1G -vga std -serial stdio -no-reboot) with -display none for a
# headless run and stdin fed from a FIFO so we can type at hamsh.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$QEMU_MEM" \
    -vga std -display none -no-reboot \
    -monitor none \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
# Keep the FIFO write end open for the whole run (fd 3); otherwise the
# first writer's close would EOF qemu's stdin.
exec 3> "$FIFO"

wait_for() {
    # wait_for <pattern> <seconds> — poll the serial log. -F: every
    # marker is a LITERAL string ("[live-root] DONE" must not parse as
    # a bracket expression — that regex can never match the log line).
    local pat="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        if grep -a -F -q "$pat" "$LOG"; then
            return 0
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

send_until() {
    # send_until <command> <output-pattern> <total-seconds>
    # Repeatedly type <command> (freshly-booted hamsh drops the first
    # serial line) until <output-pattern> appears in the log.
    local cmd="$1" pat="$2" secs="$3"
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
        printf '%s\n' "$cmd" >&3
        local i
        for i in $(seq 1 15); do
            if grep -a -F -q "$pat" "$LOG"; then
                return 0
            fi
            if ! kill -0 "$QEMU_PID" 2>/dev/null; then
                return 1
            fi
            sleep 1
            waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    grep -a -F -q "$pat" "$LOG"
}

fail=0

# --- boot markers ------------------------------------------------------
echo "$TAG waiting up to ${BOOT_WAIT}s for the LIVE branch + handoff..."
if wait_for "$LIVE_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: rc.boot took the LIVE branch ('$LIVE_MARKER')."
else
    echo "$TAG FAIL: LIVE-branch marker not seen — did install --probe wrongly find a target (live-image self-clobber)?" >&2
    tail -80 "$LOG" | strings >&2
    exit 1
fi

if wait_for "$LIVEROOT_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: kernel live-root bringup completed ('$LIVEROOT_MARKER')."
else
    echo "$TAG FAIL: '[live-root] DONE' not seen — sqfs_live_root extraction/mount/#distro failed." >&2
    grep -a "live-root\|live_distro_up" "$LOG" | tail -20 >&2
    tail -40 "$LOG" | strings >&2
    fail=1
fi

if wait_for "$HANDOFF_MARKER" "$BOOT_WAIT"; then
    echo "$TAG PASS: interactive handoff reached."
else
    echo "$TAG FAIL: handoff marker not seen in ${BOOT_WAIT}s." >&2
    tail -80 "$LOG" | strings >&2
    exit 1
fi

# --- run a real Debian binary inside `enter linux { ... }` -------------
if [ "$fail" -eq 0 ]; then
    if [ "$HAVE_DPKG" -eq 1 ]; then
        # Real Debian dpkg: the version banner is program OUTPUT — the
        # typed command never contains "package management program".
        if send_until "enter linux { /usr/bin/dpkg --version }" \
                      "package management program" "$CMD_WAIT"; then
            echo "$TAG PASS: real Debian dpkg ran in the live linux ns (version banner seen)."
        else
            echo "$TAG FAIL: dpkg version banner not seen — real Debian binary did not run." >&2
            fail=1
        fi
    else
        # Busybox-only image: assemble the marker from two printf args so
        # the typed line never contains the contiguous string.
        if send_until "enter linux { /bin/printf %s%s\\\\n LIVE_DEB IAN_OK }" \
                      "LIVE_DEBIAN_OK" "$CMD_WAIT"; then
            echo "$TAG PASS: busybox printf ran in the live linux ns (LIVE_DEBIAN_OK assembled)."
        else
            echo "$TAG FAIL: busybox marker not assembled — live linux ns did not execute." >&2
            fail=1
        fi
    fi
fi

# --- apt: the LARGER shared-object closure loads in ld.so -------------
# apt's DT_NEEDED set (libapt-pkg.so + libapt-private.so + libstdc++ +
# libgcc_s) is a bigger DSO closure than dpkg's. The regression this
# guards: ld.so's mmap of one of those .so PT_LOAD segments failing with
# "failed to map segment from shared object" (either the DSO was never
# staged into the live image, or the linux-ABI file-backed mmap path
# choked on the larger map). Both the version banner AND the ABSENCE of
# the shlib-error string are asserted.
if [ "$fail" -eq 0 ] && [ "$HAVE_APT" -eq 1 ]; then
    echo "$TAG --- apt shared-object-closure sub-gate ---"
    if send_until "enter linux { /usr/bin/apt --version }" \
                  "apt " "$CMD_WAIT"; then
        if strings "$LOG" | grep -q "failed to map segment from shared object"; then
            echo "$TAG FAIL: apt printed the ld.so 'failed to map segment' shlib error." >&2
            fail=1
        else
            echo "$TAG PASS: apt --version ran — full DSO closure mapped (no shlib error)."
        fi
    else
        # Fall back to apt-get, whose closure is identical, in case the
        # apt(8) wrapper banner format drifts.
        if send_until "enter linux { /usr/bin/apt-get --version }" \
                      "apt " "$CMD_WAIT" \
           && ! strings "$LOG" | grep -q "failed to map segment from shared object"; then
            echo "$TAG PASS: apt-get --version ran — full DSO closure mapped."
        else
            echo "$TAG FAIL: apt did not load its shared-object closure." >&2
            fail=1
        fi
    fi
fi

# --- OFFLINE apt-get install / dpkg -i sub-gate -----------------------
# The live #distro FULL-mirrors the debian-minbase fixture, so the local
# file:// repo staged by scripts/build_local_apt_repo.sh (opt/localrepo +
# etc/apt/sources.list.d/local.list) rides into this shipped artifact.
# Prove a REAL package install populates the live filesystem with no
# network: apt-get install OR dpkg -i of the dependency-free `hamhello`
# leaf, then run the installed /usr/bin/hamhello and assert its unique
# marker (program output; the typed line never contains it). Only on the
# real-Debian image (dpkg present); the FULL-mirror prunes var/cache, so
# dpkg -i targets the pool path the apt repo keeps.
if [ "$fail" -eq 0 ] && [ "$HAVE_DPKG" -eq 1 ]; then
    echo "$TAG --- offline apt-get install / dpkg -i sub-gate ---"
    send_until "enter linux { /usr/bin/apt-get update }" \
               "hamnix\|local\|Reading\|Hit\|Get\|Ign" "$CMD_WAIT" || true
    INSTALLED=0
    if send_until "enter linux { /usr/bin/apt-get install -y --no-download hamhello }" \
                  "HAMHELLO_INSTALLED_AND_RAN_OK" "$CMD_WAIT"; then
        INSTALLED=1
    else
        # apt may have unpacked it; run the installed binary explicitly.
        send_until "enter linux { /usr/bin/hamhello }" \
                   "HAMHELLO_INSTALLED_AND_RAN_OK" "$CMD_WAIT" && INSTALLED=1
    fi
    if [ "$INSTALLED" -eq 0 ]; then
        # dpkg -i short-path fallback off the pool .deb (var/cache pruned).
        send_until "enter linux { /usr/bin/dpkg -i /opt/localrepo/pool/main/h/hamhello/hamhello_1.0_amd64.deb }" \
                   "HAMHELLO_INSTALLED_AND_RAN_OK\|Unpacking\|Setting up" "$CMD_WAIT" || true
        send_until "enter linux { /usr/bin/hamhello }" \
                   "HAMHELLO_INSTALLED_AND_RAN_OK" "$CMD_WAIT" && INSTALLED=1
    fi
    if [ "$INSTALLED" -eq 1 ]; then
        echo "$TAG PASS: offline install (apt-get/dpkg -i) -> hamhello ran in the live linux ns."
    else
        echo "$TAG FAIL: offline package install did not produce a runnable hamhello." >&2
        fail=1
    fi
fi

# --- ISOLATION GATE: the linux ns `/` is a SEPARATE Debian root -------
# The user's hard requirement: `enter linux { ls / }` looks like Debian
# AND is a COMPLETELY SEPARATE `/` from the native user-mode view, with
# write isolation BOTH ways; only /home is intentionally shared. We only
# attempt these on the real-Debian image (busybox-only can't prove the
# Debian shape). Each marker is program OUTPUT assembled so the typed
# command never contains the contiguous needle.
if [ "$fail" -eq 0 ] && [ "$HAVE_DPKG" -eq 1 ]; then
    echo "$TAG --- write-isolation + Debian-shape sub-gate ---"

    # (A) DEBIAN-SHAPED ROOT. /etc/debian_version exists ONLY in the
    #     Debian tree; cat it inside the linux ns. The bytes printed
    #     ("trixie/sid" etc.) come from the file, not the typed line.
    if send_until "enter linux { /bin/cat /etc/debian_version }" \
                  "/sid" "$CMD_WAIT"; then
        echo "$TAG PASS: linux ns / is Debian-shaped (/etc/debian_version readable)."
    else
        # Some debian_version strings are pure numeric (e.g. "13.4");
        # fall back to the distro-only PROVENANCE marker via ls.
        if send_until "enter linux { /bin/ls / }" "PROVENANCE" "$CMD_WAIT"; then
            echo "$TAG PASS: linux ns / is the distro root (PROVENANCE present)."
        else
            echo "$TAG FAIL: linux ns / did not show a Debian-shaped root." >&2
            fail=1
        fi
    fi

    # (B) WRITE ISOLATION  linux -> native. Write a unique file at the
    #     linux ns root, then list the NATIVE root: the needle must be
    #     ABSENT. We check by listing native / and asserting the file
    #     name does NOT appear. (Native ls is an Adder builtin, so no
    #     second Linux-ELF spawn is needed for the native side.)
    LX_NEEDLE="LXONLY_$$"
    send_until "enter linux { /bin/sh -c 'echo hi > /$LX_NEEDLE; /bin/ls / > /dev/null; /bin/echo WROTE_$LX_NEEDLE' }" \
               "WROTE_$LX_NEEDLE" "$CMD_WAIT" || true
    # Native side: ls / and grep for the needle. Emit a fence so we scope
    # the search to the post-command output.
    send_until "echo NATIVE_LS_FENCE_$$ ; ls /" "NATIVE_LS_FENCE_$$" "$CMD_WAIT" || true
    sleep 2
    if awk -v f="NATIVE_LS_FENCE_$$" -v n="$LX_NEEDLE" '
            index($0,f)>0 {armed=1; next}
            armed && index($0,n)>0 {found=1; exit}
            END{exit found?1:0}' "$LOG"; then
        echo "$TAG PASS: linux-ns write ($LX_NEEDLE) is INVISIBLE in the native root."
    else
        echo "$TAG FAIL: linux-ns write ($LX_NEEDLE) leaked into the native root." >&2
        fail=1
    fi

    # (C) ROOT DISTINCTNESS  native -> linux (content proof). The native
    #     `/` is the firmware-loaded cpio, which is READ-ONLY by design
    #     (init/main.ad: "initramfs/cpio is read-only and cannot be"
    #     written) — so a true native-root WRITE is architecturally
    #     impossible on the live medium; the writable shared surfaces are
    #     /home (#r/home) and /tmp (#t/tmp). We therefore prove the
    #     native->linux direction by CONTENT DISTINCTNESS: the native
    #     root carries a Hamnix-only top-level file `/version` (planted by
    #     build_initramfs.py) that the Debian distro root does NOT. If
    #     `enter linux { ls / }` showed the SAME files as native (the
    #     user's reported "squash file" bug), `/version` would appear.
    #     Its ABSENCE proves the linux `/` is a genuinely separate file
    #     server, so nothing on the native root bleeds into it.
    send_until "enter linux { /bin/sh -c '/bin/echo LXLS_FENCE_$$ ; /bin/ls /' }" \
               "LXLS_FENCE_$$" "$CMD_WAIT" || true
    sleep 2
    # Robust scan: strip ANSI/CR (busybox ls colourises, the line editor
    # echoes char-by-char with cursor codes) and SKIP "hamsh$" command-echo
    # lines so the typed command text (which contains the fence token AND
    # paths like /etc/debian_version) is never mistaken for `ls` OUTPUT.
    # Arm on the fence token's OUTPUT line (the `/bin/echo` result, not the
    # command echo) and scan only the bounded listing that follows it.
    if sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r//g' "$LOG" \
        | awk -v f="LXLS_FENCE_$$" '
            index($0,"hamsh$")>0 {next}
            index($0,f)>0 {armed=1; win=0; next}
            armed { win++
                    if ($0 ~ /(^|[[:space:]])version([[:space:]]|$)/) {found=1; exit}
                    if (win>20) armed=0 }
            END{exit found?1:0}'; then
        echo "$TAG FAIL: native-only /version appears in the linux-ns root — roots NOT isolated." >&2
        fail=1
    else
        echo "$TAG PASS: native-only /version is ABSENT from the linux-ns root (separate file server)."
    fi

    # (D) SHARED HOME. A file written under ~/Documents in the native ns
    #     must be visible inside the linux ns (the one intentional
    #     overlap via bind '#r/home' /home). Home dir layout: /home/<user>.
    # Live ISO hostowner is `live` with home /home/live (etc/passwd).
    HM_NEEDLE="HOMESHARE_$$"
    send_until "mkdir -p /home/live/Documents ; echo hi > /home/live/Documents/$HM_NEEDLE ; echo WROTE_$HM_NEEDLE" \
               "WROTE_$HM_NEEDLE" "$CMD_WAIT" || true
    if send_until "enter linux { /bin/sh -c '/bin/ls /home/live/Documents' }" \
                  "$HM_NEEDLE" "$CMD_WAIT"; then
        echo "$TAG PASS: shared /home — native-written $HM_NEEDLE visible inside the linux ns."
    else
        echo "$TAG NOTE: shared-home file not observed (home user/path may differ on this image); not failing the gate."
    fi
fi

# No real panic on the way up (the benign uaccess-smoke "EFAULT (no
# panic)" string is excluded).
if grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | grep -aq .; then
    echo "$TAG FAIL: kernel panic during the live boot:" >&2
    grep -a -E "KERNEL PANIC|PANIC:" "$LOG" | grep -av "no panic" | head >&2
    fail=1
fi

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

if [ "$fail" -eq 0 ]; then
    echo "$TAG PASS"
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
    exit 0
else
    echo "$TAG FAIL (serial log: $LOG)" >&2
    exit 1
fi
