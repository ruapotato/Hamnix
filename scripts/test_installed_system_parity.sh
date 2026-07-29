#!/usr/bin/env bash
# scripts/test_installed_system_parity.sh — the INSTALLED system must be a
# faithful superset of the LIVE medium it was installed from.
#
# WHY THIS GATE EXISTS. A full install per NOTES.md produced a degraded
# system and nothing caught it, because every existing installer gate stops
# at "the installed disk boots and commands resolve". Three user-visible
# capabilities that WORK on the live desktop silently did not survive the
# install:
#
#   1. `enter linux { sh }` -> "sh not found". The target's `.hamnix-roots`
#      was the single line `sysroot .`, so `#distro` did not exist and the
#      `linux` / `debian` `ns clean { bind '#distro' / ... }` recipes had
#      nothing to bind. On the live medium `#distro` is served out of RAM
#      (rc.boot runs `live_distro_up /rootfs.sqfs /live-distro.ext4`); the
#      installed boot takes the other rc.boot branch and never runs it.
#   2. The desktop "Home" folder icon opened the file manager at `/`
#      instead of the user's home: /home was EMPTY on the installed disk
#      (~/Desktop was created but never populated from /etc/skel), so
#      hamdesktop fell back to the generic icon set, whose Home row pointed
#      at "/" — and hamfmscene's start-dir chain hardcoded /home/live before
#      giving up on "/".
#   3. No man pages at all (`/usr/share/man` is staged into the LIVE cpio;
#      no hpm package carries it).
#
# ASSERT ON THE EFFECT, NOT ON A FILE EXISTING. A file can be present at the
# wrong root and still be unreachable — that is precisely the failure mode
# here (the audio assets WERE installed and still nothing played, because
# the question is which root a path resolves against). So every check below
# runs a command on the INSTALLED system and reads its output back off the
# serial log:
#
#   * `enter linux { /bin/busybox echo ... }` must print its marker — i.e.
#     a real Linux binary was found and executed inside the hermetic
#     namespace. A missing #distro cannot fake this.
#   * `hamfmscene --homedirtest` resolves the start dir the way the desktop
#     folder icons do and prints it; PASS requires it NOT be bare "/".
#   * `cat` of the audio assets the player and the boot jingle open by
#     absolute path must return bytes.
#   * `man` must find a page.
#
# Stages (mirrors test_installer_nvme_inram.sh, which is the registered
# install-to-completion harness):
#   Stage A  build the UNATTENDED install medium + a blank NVMe target
#   Stage B  boot the medium; the auto-run installer installs to the NVMe
#   Stage C  boot the NVMe ALONE and drive the parity assertions
#
# Env overrides:
#   BOOT_TIMEOUT       per-stage seconds                (default: 240)
#   INSTALL_WAIT       extra seconds for the install    (default: 500)
#   NVME_SIZE          blank NVMe target size           (default: 3G)
#   OVMF_FD            OVMF firmware path               (auto-resolved)
#   HAMNIX_SKIP_BUILD  1 = reuse a FRESH autorun medium (default: rebuild)
#   KEEP_LOGS          1 = keep logs + qcow2 on PASS    (default: 0)
#   MUTATE             comma-separated assertion label(s) to deliberately
#                      blind, for mutation-testing this gate:
#                      distro | homedir | audio | man | alive

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-240}"
INSTALL_WAIT="${INSTALL_WAIT:-500}"
NVME_SIZE="${NVME_SIZE:-3G}"

# ONE PATH MUST NOT SERVE TWO VARIANTS: the autorun (auto-wiping) medium
# gets its own output path so no other gate can boot it by accident, and so
# an mtime freshness check can never confuse the two variants. Same rule
# test_installer_nvme_inram.sh documents at length.
INSTALLER_IMG="build/hamnix-installer-autorun.img"
NVME_IMG="${NVME_IMG:-build/installed-nvme-parity.qcow2}"

say() { echo "[test_installed_parity] $*"; }

# --- Stage A: the unattended install medium --------------------------
need_build=1
if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ] && [ -f "$INSTALLER_IMG" ]; then
    need_build=0
    say "Stage A: reusing $INSTALLER_IMG (HAMNIX_SKIP_BUILD=1)"
fi
if [ "$need_build" -eq 1 ]; then
    say "Stage A: building the UNATTENDED install medium -> $INSTALLER_IMG"
    if ! HAMNIX_INSTALLER_AUTORUN=1 \
         HAMNIX_INSTALLER_IMG_OUT="$INSTALLER_IMG" \
         bash scripts/build_installer_img.sh > /tmp/parity-build.$$.log 2>&1; then
        say "FAIL Stage A: installer build failed." >&2
        tail -60 /tmp/parity-build.$$.log >&2
        rm -f /tmp/parity-build.$$.log
        exit 1
    fi
    rm -f /tmp/parity-build.$$.log
fi
[ -f "$INSTALLER_IMG" ] || { say "FAIL: $INSTALLER_IMG missing" >&2; exit 1; }

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/qemu/OVMF.fd; do
        [ -f "$c" ] && { OVMF_FD="$c"; break; }
    done
fi
[ -n "$OVMF_FD" ] || { say "INCONCLUSIVE: no OVMF firmware found — NOTHING WAS ASSERTED." >&2; exit 125; }

# The `enter linux { sh }` keystone needs the musl busybox fixture INSTALLED onto
# the target. tests/u-binary/u_* is gitignored (.gitignore:147) and
# gen_install_manifest.py SKIPS those manifest entries when the fixture is
# absent — so on a fresh checkout the install would legitimately ship no Linux
# shell and this gate would go RED for an environmental reason, not a code one.
#
# Report that as INCONCLUSIVE (125), never as PASS and never as FAIL. Note the
# shared helper ensure_ubin_or_skip() exits 0 here, which is a SOFT GREEN — the
# class scripts/test_gate_softgreen.sh exists to forbid — so we deliberately do
# not use it.
if [ ! -f tests/u-binary/u_busybox_musl ]; then
    if [ -f scripts/_ensure_ubin.sh ]; then
        # shellcheck disable=SC1091
        . scripts/_ensure_ubin.sh
        ensure_ubin u_busybox_musl musl_busybox >/dev/null 2>&1 || true
    fi
fi
if [ ! -f tests/u-binary/u_busybox_musl ]; then
    say "INCONCLUSIVE: tests/u-binary/u_busybox_musl absent and not buildable here." >&2
    say "             The install ships no Linux shell without it, so the" >&2
    say "             'enter linux { sh }' keystone cannot be observed." >&2
    say "             NOTHING WAS ASSERTED — this is not a pass and not a regression." >&2
    exit 125
fi

rm -f "$NVME_IMG"
qemu-img create -f qcow2 "$NVME_IMG" "$NVME_SIZE" >/dev/null
say "Stage A: NVMe target $NVME_IMG ($NVME_SIZE)"

OVMF_RW=$(mktemp --tmpdir hamnix-parity.ovmf.XXXXXX.fd)
MEDIA_RW=$(mktemp --tmpdir hamnix-parity.media.XXXXXX.img)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$MEDIA_RW"

LOG_B=$(mktemp --tmpdir hamnix-parity-B.XXXXXX.log)
LOG_C=$(mktemp --tmpdir hamnix-parity-C.XXXXXX.log)
FIFO_B=$(mktemp --tmpdir -u hamnix-parity-inB.XXXXXX)
FIFO_C=$(mktemp --tmpdir -u hamnix-parity-inC.XXXXXX)
mkfifo "$FIFO_B" "$FIFO_C"

cleanup() {
    # Kill ONLY our own recorded pids — never a pattern-wide pkill; other
    # agents run QEMU on this host.
    [ -n "${QEMU_B_PID:-}" ] && kill "$QEMU_B_PID" 2>/dev/null
    [ -n "${QEMU_C_PID:-}" ] && kill "$QEMU_C_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$MEDIA_RW" "$FIFO_B" "$FIFO_C"
    if [ "${KEEP_LOGS:-0}" != "1" ]; then
        rm -f "$LOG_B" "$LOG_C" "$NVME_IMG"
    fi
}
trap cleanup EXIT

# --- Stage B: run the installer --------------------------------------
say "Stage B: boot the install medium + blank NVMe; the medium auto-installs"
exec 4<>"$FIFO_B"
exec 3>"$FIFO_B"
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$MEDIA_RW",format=raw,if=none,id=media \
    -device virtio-blk-pci,drive=media,bootindex=0 \
    -drive file="$NVME_IMG",format=qcow2,if=none,id=nvmetgt \
    -device nvme,drive=nvmetgt,serial=hamnvme01,bootindex=1 \
    -m 1536M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&4 > "$LOG_B" 2>&1 &
QEMU_B_PID=$!

installed=0
for _ in $(seq 1 $((BOOT_TIMEOUT + INSTALL_WAIT))); do
    if grep -a -q '\[install-nvme\] install complete' "$LOG_B"; then
        installed=1; break
    fi
    if ! kill -0 "$QEMU_B_PID" 2>/dev/null; then
        say "FAIL Stage B: qemu exited during the install." >&2
        tail -120 "$LOG_B" >&2
        exit 1
    fi
    sleep 1
done
kill "$QEMU_B_PID" 2>/dev/null; wait "$QEMU_B_PID" 2>/dev/null
exec 3>&-; exec 4>&-
if [ "$installed" -ne 1 ]; then
    say "FAIL Stage B: 'install complete' not seen." >&2
    tail -120 "$LOG_B" >&2
    exit 1
fi
say "Stage B: install completed."

fails=0
ok()   { say "  OK  : $1"; }
miss() { say "  MISS: $1" >&2; fails=$((fails + 1)); }

# The installer must have reported the two steps this gate is about. These
# are progress markers, not the acceptance proof — Stage C is.
grep -a -q 'Linux namespace installed' "$LOG_B" \
    && ok "installer ran the #distro (Linux namespace) step" \
    || miss "installer never ran the #distro step"
grep -a -q 'install home skeleton' "$LOG_B" \
    && ok "installer ran the home-skeleton step" \
    || miss "installer never ran the home-skeleton step"
# ...and the #distro step must have found a POPULATED source. The first run
# of this gate showed it running against the cpio-resident #distro STUB and
# installing 3 files while skipping 164 — a step that "ran" and delivered
# nothing. Assert a shell actually crossed.
grep -a -q 'install: distro/bin/busybox' "$LOG_B" \
    && ok "the #distro step copied a real shell (distro/bin/busybox)" \
    || miss "the #distro step found no shell at the source — it ran against an empty/stub #distro"

# --- Stage C: boot the INSTALLED disk and prove the capabilities ------
say "Stage C: boot the installed NVMe ALONE (medium detached); drive assertions"
exec 6<>"$FIFO_C"
exec 5>"$FIFO_C"
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$NVME_IMG",format=qcow2,if=none,id=nvmeroot \
    -device nvme,drive=nvmeroot,serial=hamnvme01,bootindex=0 \
    -m 1280M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&6 > "$LOG_C" 2>&1 &
QEMU_C_PID=$!

PROMPT_MARKER='handing off to interactive shell'
cbooted=0
for _ in $(seq 1 "$BOOT_TIMEOUT"); do
    if grep -a -q "$PROMPT_MARKER" "$LOG_C"; then cbooted=1; break; fi
    if ! kill -0 "$QEMU_C_PID" 2>/dev/null; then
        say "FAIL Stage C: qemu exited before the installed-root shell." >&2
        tail -120 "$LOG_C" >&2
        exit 1
    fi
    sleep 1
done
if [ "$cbooted" -ne 1 ]; then
    say "FAIL Stage C: installed-root shell prompt not seen in ${BOOT_TIMEOUT}s." >&2
    tail -120 "$LOG_C" >&2
    exit 1
fi
# hamsh drops the FIRST command typed at a fresh serial prompt (see
# feedback_interactive_test_wait_for_prompt) — send a throwaway line first.
sleep 6
type_c() { printf '%s\n' "$1" >&5; sleep "${2:-4}"; }
type_c "echo PARITY_WARMUP" 4

# (1) THE LINUX NAMESPACE. `enter linux { ... }` forks a child with an
#     EMPTY namespace and binds '#distro' at '/', so this command line can
#     only produce its marker if a real Linux binary was found and executed
#     inside that hermetic root. With no #distro on the disk the enter
#     itself fails and no marker appears.
type_c "enter linux { /bin/busybox echo PARITY_LINUXNS_OK }" 8
#     ...and the shell's own $PATH-walking arm — the exact resolution the
#     user's "enter linux {sh}" needs. busybox `which` prints the resolved
#     path, so this proves `sh` is FOUND without opening an interactive
#     shell the harness would then have to escape from.
type_c "enter linux { which sh }" 8

# (2) THE HOME DIRECTORY the desktop's folder icons resolve to. The FM's
#     --homedirtest arm runs the SAME _fm_apply_start_dir() the Home icon
#     drives and prints the resolved path; it self-fails on bare "/".
type_c "hamfmscene --homedirtest" 6
#     ...and the launcher set that keeps hamdesktop off its fallback icons.
type_c "ls /home/live/Desktop" 5

# (3) AUDIO ASSET PATHS. These are the absolute paths hamaudioscene seeds
#     its playlist with and that hamde's boot jingle opens. `cat` proves
#     the path RESOLVES on the installed root, which is the question — the
#     bytes existing somewhere is not.
type_c "cat /usr/share/music/hamnix-music-demo.mp3 | wc -c" 6
type_c "cat /usr/share/sounds/boot-jingle.wav | wc -c" 6

# (4) MAN PAGES.
type_c "man hamsh" 5
type_c "echo PARITY_DONE_99" 4
sleep 3
kill "$QEMU_C_PID" 2>/dev/null; wait "$QEMU_C_PID" 2>/dev/null
exec 5>&-; exec 6>&-

# --- Stage C assertions ----------------------------------------------
# MUTATE=<name>[,<name>...] deliberately blinds the named assertion(s) so
# the gate can be mutation-tested: it must go RED for exactly the named
# markers and stay green everywhere else. A blinded check reports its own
# MISS line, so one run with the full list shows each grep is wired to its
# own assertion rather than to a shared code path.
mutated=",${MUTATE:-},"
grep_c() {
    local re="$1"
    local label="$2"
    # An empty label is never mutable (guard against ",," matching it).
    if [ -n "$label" ] && [ "${mutated#*,${label},}" != "$mutated" ]; then
        return 1
    fi
    grep -aE -q "$re" "$LOG_C"
}

grep_c '^PARITY_LINUXNS_OK' distro \
    && ok "KEYSTONE: enter linux { ... } executed a Linux binary (#distro exists)" \
    || miss "KEYSTONE: enter linux { ... } produced no marker — the installed system has NO Linux namespace"
grep_c '^/bin/sh' distro \
    && ok "KEYSTONE: enter linux { which sh } printed /bin/sh — sh resolves" \
    || miss "KEYSTONE: 'enter linux { sh }' does not resolve — the exact user-reported failure"
if grep -a -q 'sh not found\|not found: sh' "$LOG_C"; then
    miss "the shell reported 'sh not found' inside enter linux"
fi

if grep_c '\[hamfm\] homedirtest PASS' homedir; then
    ok "KEYSTONE: the file manager's home resolves to a real home (not /)"
    say "        $(grep -a '\[hamfm\] homedir=' "$LOG_C" | tail -1)"
else
    miss "KEYSTONE: the file manager falls back to '/' — the desktop Home icon opens the filesystem root"
fi
grep_c 'terminal\.desktop' homedir \
    && ok "the install user's ~/Desktop carries the launcher set" \
    || miss "~/Desktop is empty — hamdesktop will fall back to the generic icon list"

grep_c '^2236800' audio \
    && ok "KEYSTONE: /usr/share/music/hamnix-music-demo.mp3 resolves + reads back whole" \
    || miss "KEYSTONE: the audio player's default track path does not resolve on the installed root"
grep_c '^1428652' audio \
    && ok "KEYSTONE: /usr/share/sounds/boot-jingle.wav resolves + reads back whole" \
    || miss "KEYSTONE: the boot jingle asset path does not resolve on the installed root"

grep_c 'NAME|SYNOPSIS|hamsh —' man \
    && ok "man pages installed (man hamsh returned a page)" \
    || miss "man pages missing on the installed system"

grep_c '^PARITY_DONE_99' alive \
    && ok "the installed shell stayed alive through every command" \
    || miss "the installed shell died mid-run"

if [ "$fails" -ne 0 ]; then
    say "FAILED ($fails assertion(s)) — last 140 lines of the installed-boot log:" >&2
    tail -140 "$LOG_C" >&2
    exit 1
fi
say "PASS: the installed system is a faithful superset of the live medium"
say "  (Linux namespace + home skeleton + audio asset paths + man pages all"
say "   verified by running commands on the INSTALLED disk, not by inspecting"
say "   the build)"
exit 0
