#!/usr/bin/env bash
# scripts/test_de_mem_gate.sh — RAM-footprint gate.
#
# Boots the installer image under the user's EXACT ship command
# (-enable-kvm -cpu host -bios OVMF -drive virtio -m 1G -vga std), waits
# for rc.5's [mem_gate] before_apps / after_apps /proc/meminfo dumps and
# the [visual_gate] done marker, then screendumps the composited desktop
# to a PNG. Prints MemFree before/after the DE app set so a footprint
# reduction can be proven, and confirms no `elf: OOM` / `memblock_alloc
# ... failed`.
#
# Env: INSTALLER_IMG, OVMF_FD, BOOT_WAIT (default 240), GATE_WAIT
# (default 200), OUT_DIR.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# The footprint we want to measure is the DE app SET (compositor + panel +
# the launched apps). Those app launches now live in rc.5's boot-time DE
# self-test (/etc/rc.d/rc.5.selftest), baked into the image ONLY when built
# with HAMNIX_DE_SELFTEST=1 — a normal user boot omits them for a clean
# desktop. So this gate boots a DEDICATED self-test image (distinct path, so
# it never clobbers the clean shipped build/hamnix-installer.img). Without
# it the gate still PASSES but before_apps == after_apps (no app delta).
export HAMNIX_DE_SELFTEST=1
INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer-selftest.img}"
export HAMNIX_INSTALLER_IMG_OUT="$INSTALLER_IMG"
BOOT_WAIT="${BOOT_WAIT:-240}"
GATE_WAIT="${GATE_WAIT:-220}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_mem_gate/$TS}"
HANDOFF_MARKER="handing off to interactive shell"

[ -e /dev/kvm ] || { echo "[mem_gate] SKIP: /dev/kvm absent" >&2; exit 0; }
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    for c in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd; do
        [ -f "$c" ] && OVMF_FD="$c" && break
    done
fi
[ -f "$OVMF_FD" ] || { echo "[mem_gate] SKIP: no OVMF" >&2; exit 0; }
# Missing OR STALE -> rebuild. This gate boots a DEDICATED image path, which
# the old "rebuild only when absent" rule pinned to whatever was built first.
# See scripts/_installer_img.sh.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
ensure_installer_img "$INSTALLER_IMG" "[mem_gate]" || exit 0
[ -f "$INSTALLER_IMG" ] || { echo "[mem_gate] FAIL: no $INSTALLER_IMG" >&2; exit 1; }

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/serial.log"
MON="$OUT_DIR/mon.sock"
IMG_RW="$OUT_DIR/disk.img"
OVMF_RW="$OUT_DIR/ovmf.fd"
cp "$INSTALLER_IMG" "$IMG_RW"
cp "$OVMF_FD" "$OVMF_RW"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 1G \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio \
    > "$LOG" 2>&1 < /dev/null &
QEMU_PID=$!
trap 'kill -9 "$QEMU_PID" 2>/dev/null; rm -f "$MON"' EXIT

echo "[mem_gate] booting (pid $QEMU_PID); waiting ${BOOT_WAIT}s for handoff..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    grep -aq "$HANDOFF_MARKER" "$LOG" && { booted=1; break; }
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done
[ "$booted" = 1 ] || { echo "[mem_gate] FAIL: no handoff in ${BOOT_WAIT}s"; tail -40 "$LOG"; exit 1; }
echo "[mem_gate] booted; waiting ${GATE_WAIT}s for [visual_gate] done..."

done_seen=0
for _ in $(seq 1 "$GATE_WAIT"); do
    grep -aq "\[visual_gate\] done" "$LOG" && { done_seen=1; break; }
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done

# Screendump the final composited desktop via the monitor socket.
screendump() {
    local ppm="$OUT_DIR/desktop.ppm" png="$OUT_DIR/desktop.png"
    printf 'screendump %s\n' "$ppm" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1 || \
        { echo "screendump $ppm" | nc -U "$MON" >/dev/null 2>&1; }
    sleep 0.5
    if [ -s "$ppm" ]; then
        if command -v convert >/dev/null 2>&1; then convert "$ppm" "$png" 2>/dev/null; fi
        echo "[mem_gate] desktop PPM $(wc -c < "$ppm") bytes -> $png"
    else
        echo "[mem_gate] WARN: screendump empty"
    fi
}
screendump

echo "=================== MEM GATE RESULTS ==================="
echo "--- before_apps (base DE session: compositor+desktop+panel+term+fm+calc+editor) ---"
awk '/\[mem_gate\] before_apps/{f=1;next} /\[mem_gate\] after_apps/{f=0} f' "$LOG" | grep -aE 'Mem:|total *free' | head -3
echo "--- after_apps (full app set incl. visual-gate apps) ---"
awk '/\[mem_gate\] after_apps/{f=1;next} /\[visual_gate\] done/{f=0} f' "$LOG" | grep -aE 'Mem:|total *free' | head -3
echo "--- OOM / alloc-fail check ---"
# Catch genuine OOM / allocation-failure markers, but NOT the benign
# "<N> OOM" success COUNTER that stress self-tests print on a clean boot
# (e.g. mm_smoke's "[pa-stress] churn done: 256 iters, 0 OOM"). The old
# bare-`OOM` pattern matched that counter and made the gate ALWAYS report
# "OOM markers present" even when the boot was clean — a false-red. The
# `[0-9]+ OOM` filter drops the count-suffixed diagnostic lines only; real
# failures like "elf: OOM", "memblock_alloc ... failed", "out of memory",
# "OOM killer ..." and "[memcg] OOM cgroup ..." carry no "<N> OOM" suffix
# and still trip the check.
OOM_HITS="$(grep -aiE 'elf6?4?: OOM|memblock_alloc.*fail|OOM[ -]kill|OOM cgroup|out of memory' "$LOG" | grep -avE '[0-9]+ OOM')"
if [ -n "$OOM_HITS" ]; then
    printf '%s\n' "$OOM_HITS"
    echo "[mem_gate] *** OOM/alloc-fail markers present ***"
else
    echo "[mem_gate] no OOM/alloc-fail markers"
fi
echo "[mem_gate] done_seen=$done_seen  log=$LOG  png=$OUT_DIR/desktop.png"
