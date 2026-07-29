#!/usr/bin/env bash
# scripts/test_audio_jingle_ondevice.sh — the SHIPPED IMAGE plays the boot
# jingle ONCE.
#
# The companion to scripts/test_audio_stream_lifetime.sh. That gate proves the
# stream-lifetime contract on a synthetic scenario booted with `-kernel`; THIS
# one proves it on the real product: the installer .img, under UEFI/OVMF, with
# the real desktop spawning the real `/bin/aplay /usr/share/sounds/boot-jingle.wav`
# — the exact sequence behind the user's "on the first sound effect it played the
# END OF THE BOOT JINGLE" report.
#
# WHAT IS ASSERTED, AND ON WHAT
# =============================
# QEMU's `-audiodev wav` backend captures what the emulated codec was actually
# fed. The jingle is 1 428 480 bytes of 48 kHz stereo s16le = 7.44 s of audio.
# So:
#   * the capture must contain a run of NON-SILENT audio ~7.44 s long, and
#   * the TOTAL non-silent audio must be that same ~7.44 s — no more.
# Pre-fix the streaming ring survived its owner and a following writer could
# restart DMA over the leftover lap, so "no more" is the load-bearing half.
#
# The image is booted with the DE's own launch path; nothing is scripted into
# the guest, so a PASS here means an unmodified shipped image behaves.
#
# Pass marker:  [audio_jingle_ondevice] PASS
# Fail marker:  [audio_jingle_ondevice] FAIL
# Skip:         no /dev/kvm, no OVMF firmware (exit 0, loudly)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$PROJ_ROOT"

INSTALLER_IMG="${INSTALLER_IMG:-build/hamnix-installer.img}"
BOOT_WAIT="${BOOT_WAIT:-140}"
# The shipped boot jingle, in seconds of 48 kHz stereo s16le audio.
JINGLE_S=7.44
TOL=0.90

[ -e /dev/kvm ] || { echo "[audio_jingle_ondevice] SKIP: /dev/kvm absent" >&2; exit 0; }
OVMF_FD=""
for c in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd \
         /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    [ -f "$c" ] && { OVMF_FD="$c"; break; }
done
[ -z "$OVMF_FD" ] && { echo "[audio_jingle_ondevice] SKIP: no OVMF firmware" >&2; exit 0; }

# STALE-IMAGE GUARD. Booting a pre-built image would false-GREEN the very
# regression this gate exists for; ensure_installer_img rebuilds when the image
# is older than any tracked build input.
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"
# shellcheck source=_verdict.sh
installer_img_or_verdict "$INSTALLER_IMG" "[audio_jingle_ondevice]"

OVMF_RW=$(mktemp --tmpdir hamnix-aj.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-aj.img.XXXXXX.raw)
LOG=$(mktemp --tmpdir hamnix-aj.XXXXXX.log)
WAV=$(mktemp --tmpdir hamnix-aj.XXXXXX.wav)
cp "$OVMF_FD" "$OVMF_RW"
cp "$INSTALLER_IMG" "$IMG_RW"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || true
    rm -f "$OVMF_RW" "$IMG_RW" "$LOG" "$WAV"
}
trap cleanup EXIT

echo "[audio_jingle_ondevice] booting $INSTALLER_IMG under OVMF (${BOOT_WAIT}s)"
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 2G \
    -vga std -display none -no-reboot \
    -audiodev "wav,id=snd0,path=$WAV" \
    -device intel-hda \
    -device hda-output,audiodev=snd0 \
    -serial stdio </dev/null > "$LOG" 2>&1 &
QEMU_PID=$!
SLEPT=0
while [ "$SLEPT" -lt "$BOOT_WAIT" ]; do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 5
    SLEPT=$((SLEPT + 5))
done
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

echo "[audio_jingle_ondevice] --- guest audio lines ---"
grep -aE "\[hda\]|aplay|jingle" "$LOG" | head -20 || true
echo "[audio_jingle_ondevice] --- end ---"

fail=0
if ! grep -qaF "[hda] init OK" "$LOG"; then
    echo "[audio_jingle_ondevice] FAIL: the HDA driver never came up — nothing" >&2
    echo "[audio_jingle_ondevice]   below was exercised" >&2
    fail=1
fi
if [ ! -s "$WAV" ]; then
    echo "[audio_jingle_ondevice] FAIL: QEMU produced no WAV capture" >&2
    echo "[audio_jingle_ondevice] FAIL" >&2
    exit 1
fi

set +e
python3 - "$WAV" "$JINGLE_S" "$TOL" <<'PY'
import sys, wave
import numpy as np

path, want, tol = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
w = wave.open(path, 'rb')
rate, ch = w.getframerate(), w.getnchannels()
a = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(float)
w.close()
if ch > 1:
    a = a.reshape(-1, ch).mean(axis=1)
wn = max(1, int(rate * 0.05))                      # 50 ms windows
n = len(a) // wn
rms = np.sqrt((a[:n * wn].reshape(n, wn) ** 2).mean(axis=1))
loud = rms >= 300.0
runs, c = [], 0
for v in loud:
    if v:
        c += 1
    elif c:
        runs.append(c * wn / rate)
        c = 0
if c:
    runs.append(c * wn / rate)
total = sum(runs)
longest = max(runs) if runs else 0.0
tag = "[audio_jingle_ondevice]"
print(f"{tag}   capture {len(a)/rate:.2f}s; non-silent runs "
      f"{[round(r,2) for r in runs][:8]}")
print(f"{tag}   longest run {longest:.2f}s, TOTAL non-silent {total:.2f}s, "
      f"jingle is {want:.2f}s")
bad = 0
if abs(longest - want) > tol:
    print(f"{tag} FAIL: the jingle sounded for {longest:.2f}s, expected "
          f"{want:.2f}s (tolerance {tol:.2f}s)", file=sys.stderr)
    bad = 1
else:
    print(f"{tag} PASS: the jingle played in full ({longest:.2f}s)")
if total - want > tol:
    print(f"{tag} FAIL: {total:.2f}s of audio for a {want:.2f}s jingle — "
          f"it is being replayed", file=sys.stderr)
    bad = 1
else:
    print(f"{tag} PASS: the jingle played ONCE ({total:.2f}s total, no replay)")
sys.exit(bad)
PY
arc=$?
set -e
[ "$arc" -ne 0 ] && fail=1

if [ "$fail" -eq 0 ]; then
    echo "[audio_jingle_ondevice] PASS"
    exit 0
fi
echo "[audio_jingle_ondevice] FAIL" >&2
exit 1
