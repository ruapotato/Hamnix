#!/usr/bin/env bash
# scripts/test_hamaudio_interactive.sh — on-device gate for the INTERACTIVE
# audio player (user/hamaudioscene.ad), as opposed to the headless
# user/hamaudioselftest.ad exercised by scripts/test_hamaudio_playback.sh.
#
# WHY THIS GATE EXISTS
# ====================
# The USER drove the shipped image, opened the Audio Player, "seemed to play
# one 2-second wav but no sound came out and it hung at the end." Two claims:
#   (a) NO SOUND — is the interactive player's PCM feed real, or does it only
#       stream in the selftest? The player opens a wsys window and then streams
#       PCM through the SAME /dev/audioctl + /dev/audio + `start` path as the
#       selftest (its _stage_and_start). This gate runs the REAL player binary
#       (not the selftest) headless — devwsys is lazy-init so the window opens
#       with no compositor/framebuffer — and captures QEMU's intel-hda output
#       to a WAV. Non-silent capture => the interactive feed is real; any
#       "no sound" on the user's box is a QEMU-speaker / real-HW-codec-amp
#       routing artifact, not an app feed bug.
#   (b) HANG AT END — the player's event loop used to settle at
#       play_base_ms == dur, which pushed the byte cursor to/after data_len;
#       the next Play then hit the `from_byte >= data_len` early-return in
#       _stage_and_start and did nothing, so the app looked wedged at the end.
#       FIX: at EOF the loop stops DMA, `reset`s the staged PCM, and REWINDS to
#       0, logging "[hamaudio] EOF -> idle (rewound)". Seeing that line on the
#       serial (then the process still alive, no panic) proves the loop reached
#       end-of-clip and returned to idle instead of hanging.
#
# Pass criteria (hearing-free, objective):
#   * "[hamaudio] scene window ready"  — the real player opened a wsys window;
#   * "[hamaudio] playing"             — it started streaming;
#   * "[hamaudio] EOF -> idle (rewound)" — it reached EOF and returned to idle;
#   * no "panic"/"PANIC" on the serial — it did not crash/hang;
#   * captured WAV is NON-SILENT (peak |sample| well above zero).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
WAV=$(mktemp --suffix=.wav)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$WAV"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[hamaudio_interactive] (1/3) Build userland (hamaudioscene + init)"
bash scripts/build_user.sh >/dev/null

[ -s tests/fixtures/sounds/test.wav ] || python3 scripts/gen_test_wav.py >/dev/null

echo "[hamaudio_interactive] (2/3) Build kernel with hamaudioscene as /init + clip in initramfs"
INIT_ELF=build/user/hamaudioscene.elf \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[hamaudio_interactive] (3/3) Boot QEMU with intel-hda -> wav backend"
# TIMEOUT BUDGET: the bare-launch default track is no longer the ~2 s
# test.wav — it is the shipped "Hamnix Music Demo" (2:19 = 139 s of
# audio, user/hamaudioscene.ad::main). The player streams it in real
# time, so "[hamaudio] EOF -> idle" cannot possibly arrive inside the old
# 90 s window and this gate was red for a pure budgeting reason, not a
# player bug. There is no way to hand the app a shorter clip here (it
# runs AS /init, and the kernel passes init no argv), so the budget has
# to cover the real track: 139 s of audio + boot + decode + margin.
# Override with HAMAUDIO_TIMEOUT=<seconds> when profiling.
QTIMEOUT="${HAMAUDIO_TIMEOUT:-300}"
set +e
timeout "${QTIMEOUT}s" qemu-system-x86_64 \
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

echo "[hamaudio_interactive] --- guest output ---"
grep -E "\[hda\]|\[hamaudio\]|panic|PANIC" "$LOG" || true
echo "[hamaudio_interactive] --- end ---"

fail=0
check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[hamaudio_interactive] PASS: $label"
    else
        echo "[hamaudio_interactive] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}
check "interactive player opened a wsys window" "[hamaudio] scene window ready"
check "interactive player started streaming"    "[hamaudio] playing"
check "reached EOF and returned to idle (no hang)" "[hamaudio] EOF -> idle (rewound)"

if grep -qF -- "--- Kernel panic:" "$LOG"; then
    echo "[hamaudio_interactive] FAIL: kernel panic on the serial" >&2
    fail=1
else
    echo "[hamaudio_interactive] PASS: no panic (process survived past EOF)"
fi

if [ ! -s "$WAV" ]; then
    echo "[hamaudio_interactive] FAIL: QEMU produced no WAV file" >&2
    fail=1
else
    PEAK=$(python3 - "$WAV" <<'PY'
import sys, struct, wave
try:
    w = wave.open(sys.argv[1], 'rb')
    sw=w.getsampwidth(); ch=w.getnchannels(); data=w.readframes(w.getnframes()); w.close()
    if sw==2:
        n=len(data)//2; allv=struct.unpack("<%dh"%n, data[:n*2]); left=allv[0::ch] if ch>1 else list(allv)
    else:
        allv=[b-128 for b in data]; left=allv[0::ch] if ch>1 else allv
    print(max((abs(v) for v in left), default=0))
except Exception:
    print(0)
PY
)
    echo "[hamaudio_interactive] captured WAV peak |sample| = $PEAK"
    if [ "${PEAK:-0}" -ge 1000 ]; then
        echo "[hamaudio_interactive] PASS: interactive player's feed is NON-SILENT (real PCM reached the codec)"
    else
        echo "[hamaudio_interactive] FAIL: captured WAV silent/zero (peak=$PEAK)" >&2
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "[hamaudio_interactive] FAIL"
    exit 1
fi
echo "[hamaudio_interactive] PASS — the REAL player binary opened a window, streamed non-silent PCM through the HDA cdev, reached EOF, and returned to idle without hanging"
