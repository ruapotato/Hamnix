#!/usr/bin/env bash
# scripts/test_hda_volume.sh — DE master volume/mute actually changes the
# HDA output level (#279).
#
# The DE Sound capplet writes `master <pct>` / `mute` to /dev/audioctl. This
# gate PROVES those verbs scale the REAL captured audio, not just a pref:
# it boots the same square-wave tone at three master levels and asserts the
# captured-WAV peak amplitude tracks the level —
#
#     master 100  ->  LOUD  (peak ~ full tone amplitude)
#     master 30   ->  QUIET (peak ~ 30% of loud, well below loud)
#     master 0 + mute -> SILENT (peak ~ 0)
#
# The tone is streamed via the DIRECT /dev/audio write path (playtone/aplay
# path), so this also proves the master gain reaches that path — not only
# the mixer's mixplay render. QEMU's wav audiodev captures the codec output
# to a host WAV per boot; a Python WAV parser reports the peak |sample|.
#
# Pass marker:  [test_hda_volume] PASS
# Fail marker:  [test_hda_volume] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hda_volume] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null

# Boot once at a given master level, capture the WAV, print the peak |sample|.
# $1 = AUDIO_MASTER marker value (e.g. "100", "30", "0 mute"); echoes PEAK.
capture_peak() {
    local master="$1"
    local WAV LOG
    WAV=$(mktemp --suffix=.wav)
    LOG=$(mktemp)

    INIT_ELF=build/user/init.elf ENABLE_AUDIO_TEST=1 AUDIO_MASTER="$master" \
        python3 scripts/build_initramfs.py >/dev/null
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
    kernel_image_compile "$ELF" >/dev/null

    set +e
    timeout 180s qemu-system-x86_64 \
        -kernel "$ELF" \
        -smp 1 -nographic -no-reboot -m 256M -monitor none \
        -audiodev "wav,id=snd0,path=$WAV" \
        -device intel-hda \
        -device hda-output,audiodev=snd0 \
        -serial stdio \
        </dev/null > "$LOG" 2>&1
    local rc=$?
    set -e

    grep -E "\[audio\] master marker" "$LOG" >&2 || true

    local PEAK
    PEAK=$(python3 - "$WAV" <<'PY'
import sys, struct, wave
path = sys.argv[1]
peak = 0
try:
    w = wave.open(path, 'rb')
    n = w.getnframes(); sw = w.getsampwidth()
    data = w.readframes(n); w.close()
    if sw == 2 and data:
        cnt = len(data)//2
        vals = struct.unpack("<%dh" % cnt, data[:cnt*2])
        peak = max(abs(v) for v in vals) if vals else 0
except Exception:
    raw = open(path, 'rb').read()[44:]
    if raw:
        cnt = len(raw)//2
        vals = struct.unpack("<%dh" % cnt, raw[:cnt*2])
        peak = max(abs(v) for v in vals) if vals else 0
print(peak)
PY
)
    rm -f "$LOG" "$WAV"
    echo "${PEAK:-0}"
}

echo "[test_hda_volume] (2/3) Capture at master=100 / master=30 / mute"
PEAK_LOUD=$(capture_peak "100")
echo "[test_hda_volume]   master=100 -> peak |sample| = $PEAK_LOUD"
PEAK_QUIET=$(capture_peak "30")
echo "[test_hda_volume]   master=30  -> peak |sample| = $PEAK_QUIET"
PEAK_MUTE=$(capture_peak "0 mute")
echo "[test_hda_volume]   mute       -> peak |sample| = $PEAK_MUTE"

echo "[test_hda_volume] (3/3) Assert loud > quiet > silent"
fail=0

# LOUD must be a real, non-silent tone (the kernel amplitude is 12000).
if [ "$PEAK_LOUD" -lt 8000 ]; then
    echo "[test_hda_volume] FAIL: master=100 not loud (peak=$PEAK_LOUD, want >=8000)" >&2
    fail=1
fi
# QUIET must be clearly attenuated vs loud (30% ~ 3600; require well under
# loud and above rounding noise).
if [ "$PEAK_QUIET" -ge "$PEAK_LOUD" ] || [ "$PEAK_QUIET" -lt 100 ]; then
    echo "[test_hda_volume] FAIL: master=30 not an attenuated tone" \
         "(quiet=$PEAK_QUIET vs loud=$PEAK_LOUD)" >&2
    fail=1
fi
# QUIET should be roughly 30% of LOUD — assert it is at most half of loud to
# prove real scaling (not just a slightly-different capture).
if [ "$PEAK_QUIET" -gt $((PEAK_LOUD / 2)) ]; then
    echo "[test_hda_volume] FAIL: master=30 not attenuated enough" \
         "(quiet=$PEAK_QUIET, expected <= loud/2 = $((PEAK_LOUD/2)))" >&2
    fail=1
fi
# MUTE must be silent (allow a tiny epsilon for any codec priming click).
if [ "$PEAK_MUTE" -ge 100 ]; then
    echo "[test_hda_volume] FAIL: mute not silent (peak=$PEAK_MUTE)" >&2
    fail=1
fi

# Restore a default (marker-free) initramfs so a following build isn't
# left with the audio-test markers planted.
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true

if [ "$fail" -ne 0 ]; then
    echo "[test_hda_volume] FAIL"
    exit 1
fi

echo "[test_hda_volume] PASS — HDA master volume scales the captured output:" \
     "loud=$PEAK_LOUD quiet=$PEAK_QUIET mute=$PEAK_MUTE"
