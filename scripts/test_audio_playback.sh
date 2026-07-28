#!/usr/bin/env bash
# scripts/test_audio_playback.sh — USERLAND native audio playback.
#
# The companion to scripts/test_hda_audio.sh. That gate proves the native
# HDA stack from the KERNEL's seat (the boot self-test writes the tone).
# THIS gate proves the path a real user program takes: it runs the native
# userland `playtone` tool AS /init, so a guest PROGRAM — not the kernel —
# opens /dev/audioctl + /dev/audio, streams a synthesized square-wave tone,
# and starts the stream. QEMU's intel-hda + hda-output codec is wired to
# the WAV audio backend, capturing whatever the guest actually played.
#
# Full path exercised, guest-program-first:
#   playtone (userland)
#     -> sys_write /dev/audioctl + /dev/audio  (Plan-9 cdev, no ioctls)
#     -> devaudio cdev  -> HDA stream DMA  -> codec  -> host WAV capture
#
# Pass criteria (hearing-free, objective):
#   * the guest program logged it played the tone ([playtone] played ...);
#   * the captured WAV is NON-SILENT (peak |sample| well above zero);
#   * the WAV's dominant frequency (measured by zero-crossings) matches the
#     ~1 kHz tone the guest generated — proving it's the RIGHT signal, not
#     just noise.
#
# Pass marker:  [test_audio_playback] PASS
# Fail marker:  [test_audio_playback] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
WAV=$(mktemp --suffix=.wav)
LOG=$(mktemp)
TONE_HZ=1000
trap 'rm -f "$LOG" "$WAV"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_audio_playback] (1/3) Build userland (playtone + init)"
bash scripts/build_user.sh >/dev/null

echo "[test_audio_playback] (2/3) Build kernel with playtone as /init"
# INIT_ELF override: the kernel execs build/user/playtone.elf as the first
# userland process. It plays a ~1 kHz square wave then waits out the tone.
INIT_ELF=build/user/playtone.elf \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_audio_playback] (3/3) Boot QEMU with intel-hda -> wav backend"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -audiodev "wav,id=snd0,path=$WAV" \
    -device intel-hda \
    -device hda-output,audiodev=snd0 \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_audio_playback] --- guest output ---"
grep -E "\[hda\]|\[playtone\]" "$LOG" || true
echo "[test_audio_playback] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_audio_playback] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_audio_playback] PASS: $label"
    else
        echo "[test_audio_playback] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}
# The HDA driver must have brought the controller up on a normal boot
# (hda_init runs unconditionally when a class-0403 device is present).
check "HDA controller init OK"        "[hda] init OK"
# The GUEST PROGRAM (not the kernel) reports it played the tone.
check "userland playtone ran"         "[playtone] played"

# --- ground truth: parse the captured WAV -------------------------------
if [ ! -s "$WAV" ]; then
    echo "[test_audio_playback] FAIL: QEMU produced no WAV file at $WAV" >&2
    fail=1
else
    RESULT=$(python3 - "$WAV" "$TONE_HZ" <<'PY'
import sys, struct, wave
path = sys.argv[1]
want_hz = float(sys.argv[2])
peak = 0
nframes = 0
rate = 0
zc = 0
try:
    w = wave.open(path, 'rb')
    sw = w.getsampwidth()
    ch = w.getnchannels()
    rate = w.getframerate()
    nframes = w.getnframes()
    data = w.readframes(nframes)
    w.close()
    # Decode the LEFT channel to s16 samples.
    left = []
    if sw == 2:
        n = len(data) // 2
        allv = struct.unpack("<%dh" % n, data[:n*2])
        left = allv[0::ch] if ch > 1 else list(allv)
    elif sw == 1:
        allv = [b - 128 for b in data]
        left = allv[0::ch] if ch > 1 else allv
    if left:
        peak = max(abs(v) for v in left)
    # Count zero-crossings (sign changes) over the non-silent region to
    # estimate the dominant frequency. Two zero-crossings per period.
    prev = 0
    active = 0
    for v in left:
        if abs(v) < peak // 4:   # ignore near-silence lead-in/out
            continue
        active += 1
        s = 1 if v >= 0 else -1
        if prev != 0 and s != prev:
            zc += 1
        prev = s
    freq = 0.0
    if active > 0 and rate > 0:
        # active samples span (active/rate) seconds; freq = (zc/2)/seconds.
        secs = active / float(rate)
        if secs > 0:
            freq = (zc / 2.0) / secs
    print("%d %d %d %.1f" % (peak, nframes, rate, freq))
except Exception as e:
    print("0 0 0 0.0")
PY
)
    PEAK_VAL=$(echo "$RESULT" | awk '{print $1}')
    NFRAMES=$(echo "$RESULT" | awk '{print $2}')
    WRATE=$(echo "$RESULT" | awk '{print $3}')
    FREQ=$(echo "$RESULT" | awk '{print $4}')
    echo "[test_audio_playback] captured WAV: $NFRAMES frames @ ${WRATE}Hz, peak |sample| = $PEAK_VAL, measured tone ~= ${FREQ}Hz"

    if [ "${PEAK_VAL:-0}" -ge 1000 ]; then
        echo "[test_audio_playback] PASS: captured WAV is NON-SILENT (real samples)"
    else
        echo "[test_audio_playback] FAIL: captured WAV is silent/zero (peak=$PEAK_VAL)" >&2
        fail=1
    fi

    # Frequency must be within +-30% of the 1 kHz tone. Zero-crossing
    # estimation over a square wave is robust; a wide band tolerates any
    # capture-rate resampling while still rejecting noise / wrong signals.
    FREQ_OK=$(python3 -c "f=$FREQ; lo=$TONE_HZ*0.7; hi=$TONE_HZ*1.3; print(1 if lo<=f<=hi else 0)")
    if [ "$FREQ_OK" = "1" ]; then
        echo "[test_audio_playback] PASS: dominant tone ~${FREQ}Hz matches the ${TONE_HZ}Hz guest tone"
    else
        echo "[test_audio_playback] FAIL: measured ${FREQ}Hz is not the ${TONE_HZ}Hz tone" >&2
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_audio_playback] FAIL"
    exit 1
fi

echo "[test_audio_playback] PASS — userland playtone streamed a ${TONE_HZ}Hz tone through the native HDA cdev; host WAV captured the right, non-silent signal"
