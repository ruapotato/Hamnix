#!/usr/bin/env bash
# scripts/test_hda_audio.sh — native Intel HDA audio playback.
#
# Boots Hamnix once under QEMU with an `intel-hda` controller + a
# `hda-output` codec wired to QEMU's WAV audio backend, so any PCM the
# native HDA driver streams out via real stream DMA is captured to a host
# WAV file. The kernel self-test (init/main.ad boot:37.aud, gated on
# /etc/audio-test = ENABLE_AUDIO_TEST=1) synthesizes a square-wave tone,
# configures /dev/audioctl, writes the PCM to /dev/audio (the Plan-9
# cdev), and starts the stream.
#
# This test PROVES REAL SOUND, not a probe:
#   * the kernel asserts the HDA controller's link-position counter
#     advanced (stream DMA actually consumed the buffer) — [audio] lines;
#   * the HOST parses the captured WAV and FAILS if it is all-zero /
#     silent, PASSing only when it contains real non-zero samples whose
#     peak amplitude matches the loud tone the kernel generated.
#
# Pass marker:  [test_hda] PASS
# Fail marker:  [test_hda] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
WAV=$(mktemp --suffix=.wav)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$WAV"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_hda] (1/3) Build userland (init + aplay)"
bash scripts/build_user.sh >/dev/null

echo "[test_hda] (2/3) Build kernel with /etc/audio-test marker"
INIT_ELF=build/user/init.elf ENABLE_AUDIO_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[test_hda] (3/3) Boot QEMU with intel-hda -> wav backend"
set +e
# QEMU_AUDIO_DRV/wav audiodev captures the codec output to $WAV.
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

echo "[test_hda] --- audio self-test output ---"
grep -E "\[hda\]|\[audio\]" "$LOG" || true
echo "[test_hda] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_hda] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[audio] FAIL" "$LOG"; then
    echo "[test_hda] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

# Kernel-side assertions (the driver really brought the controller up and
# walked the codec to a DAC/pin path, then ran the stream).
check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_hda] PASS: $label"
    else
        echo "[test_hda] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}
check "controller out of reset"  "[hda] controller out of reset"
check "CORB/RIRB up"             "[hda] CORB/RIRB up"
check "codec + DAC/pin path"     "[hda] DAC nid="
check "init OK"                  "[hda] init OK"
check "PCM streamed to /dev/audio" "[audio] streamed"
check "kernel PASS banner"       "[audio] PASS"

# --- the ground truth: the captured WAV must be NON-SILENT ----------
if [ ! -s "$WAV" ]; then
    echo "[test_hda] FAIL: QEMU produced no WAV file at $WAV" >&2
    fail=1
else
    # Parse the WAV PCM payload and find the peak |sample|. The header is
    # 44 bytes (canonical RIFF/WAVE PCM). We read s16le samples and
    # compute the maximum absolute value; an all-zero (silent) capture
    # has peak 0.
    PEAK=$(python3 - "$WAV" <<'PY'
import sys, struct, wave
path = sys.argv[1]
peak = 0
nframes = 0
try:
    w = wave.open(path, 'rb')
    sw = w.getsampwidth()
    nframes = w.getnframes()
    data = w.readframes(nframes)
    w.close()
    if sw == 2:
        n = len(data) // 2
        if n:
            vals = struct.unpack("<%dh" % n, data[:n*2])
            peak = max(abs(v) for v in vals)
    elif sw == 1:
        peak = max(abs(b - 128) for b in data) if data else 0
    else:
        # fall back: scan raw bytes for any non-zero
        peak = max(data) if data else 0
except Exception as e:
    # Not a parseable wave (e.g. empty) — scan raw payload past 44 bytes.
    raw = open(path, 'rb').read()
    body = raw[44:]
    if body:
        import struct as _s
        n = len(body)//2
        if n:
            vals = _s.unpack("<%dh" % n, body[:n*2])
            peak = max(abs(v) for v in vals)
        nframes = n
print("%d %d" % (peak, nframes))
PY
)
    PEAK_VAL=$(echo "$PEAK" | awk '{print $1}')
    NFRAMES=$(echo "$PEAK" | awk '{print $2}')
    echo "[test_hda] captured WAV: $NFRAMES frames, peak |sample| = $PEAK_VAL"
    # The kernel tone amplitude is 12000; require a comfortably non-zero
    # peak to rule out a silent/zero capture. 1000 is well below the tone
    # peak but far above any rounding noise.
    if [ "${PEAK_VAL:-0}" -ge 1000 ]; then
        echo "[test_hda] PASS: captured WAV is NON-SILENT (real samples)"
    else
        echo "[test_hda] FAIL: captured WAV is silent/zero (peak=$PEAK_VAL)" >&2
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hda] FAIL"
    exit 1
fi

echo "[test_hda] PASS — native HDA driver played a tone via stream DMA; host WAV captured non-silent PCM"
