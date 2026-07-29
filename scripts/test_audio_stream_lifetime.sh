#!/usr/bin/env bash
# scripts/test_audio_stream_lifetime.sh — AUDIO STREAM LIFETIME, asserted on
# the PCM the codec actually emitted.
#
# THE REPORTS THIS GATE EXISTS FOR (shipped image, hands-on, 2026-07-28)
#   1. "on the first sound effect it played the end of the boot jingle"
#   2. "on close it played the last sound effect over and over"
#   3. "two apps playing audio ... 1/2 the sounds don't play while the music
#      is playing"
#
# WHY IT ASSERTS ON SAMPLES AND NOT ON AN EXIT STATUS
# ===================================================
# Every one of those three bugs is INVISIBLE to a status check: the writes all
# succeed, every process exits 0, and the driver reports a running stream. The
# only witness that can tell them apart is the audio itself. So this gate boots
# user/audiolife.ad as /init with QEMU's `-audiodev wav` backend capturing the
# codec output to a host WAV, and then reads that WAV back:
#
#   * scripts/_audio_wav_timeline.py folds the capture to mono, slices it into
#     25 ms windows, and runs a Goertzel bin at 300 / 1000 / 1500 Hz. Each
#     window gets a label: which of the three scenario tones was sounding.
#   * The three assertions below are statements about THAT TIMELINE.
#
# THE SCENARIO (see user/audiolife.ad for the full timeline)
#   A "jingle" 1000 Hz, streamopen+drain, process exits      (= /bin/aplay)
#   B "sfx"     300 Hz, raw /dev/audio writes, no drain,
#               process exits mid-flight                     (= hamgame snake)
#   C "music"  1500 Hz, long streamopen + nonblock producer  (= the DE player)
#
# ASSERTIONS (all on the captured samples)
#   SYM1  The FIRST sounding window at/after B starts is 300 Hz, not 1000 Hz.
#         A 1000 Hz window there means B's first effect replayed A's ring.
#   SYM2  Within SYM2_SETTLE_MS of B's last burst the capture goes SILENT and
#         STAYS silent for the whole idle window. Any 300 Hz there means the
#         ring outlived the process that owned it.
#   SYM3  While C's 1500 Hz music is sounding, ALL SIX of B's 300 Hz bursts are
#         present in the mix. Fewer than six means effects were dropped rather
#         than mixed.
#
# Pass marker:  [audio_lifetime] PASS
# Fail marker:  [audio_lifetime] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF="$PROJ_ROOT/build/hamnix-kernel.elf"
WAV=$(mktemp --suffix=.wav)
LOG=$(mktemp)
TL=$(mktemp --suffix=.json)
trap 'rm -f "$LOG" "$WAV" "$TL"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[audio_lifetime] (1/4) Build userland (audiolife + init)"
bash scripts/build_user.sh >/dev/null

echo "[audio_lifetime] (2/4) Build kernel with audiolife as /init"
INIT_ELF=build/user/audiolife.elf python3 scripts/build_initramfs.py >/dev/null
. "$PROJ_ROOT/scripts/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

echo "[audio_lifetime] (3/4) Boot QEMU with intel-hda -> wav capture"
set +e
timeout 220s qemu-system-x86_64 \
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

echo "[audio_lifetime] --- guest scenario markers ---"
grep -E "\[audiolife\]|\[hda\] init" "$LOG" || true
echo "[audio_lifetime] --- end ---"

fail=0
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[audio_lifetime] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi
if ! grep -qF "[audiolife] SCENARIO done" "$LOG"; then
    echo "[audio_lifetime] FAIL: the scenario never reached its end marker —" >&2
    echo "[audio_lifetime]   nothing below was actually exercised" >&2
    fail=1
fi
if [ ! -s "$WAV" ]; then
    echo "[audio_lifetime] FAIL: QEMU produced no WAV capture" >&2
    echo "[audio_lifetime] FAIL" >&2
    exit 1
fi

echo "[audio_lifetime] (4/4) Assert on the captured PCM"
set +e
python3 "$PROJ_ROOT/scripts/_audio_lifetime_assert.py" "$WAV"
arc=$?
set -e
[ "$arc" -ne 0 ] && fail=1

if [ "$fail" -eq 0 ]; then
    echo "[audio_lifetime] PASS"
    exit 0
fi
echo "[audio_lifetime] FAIL" >&2
exit 1
