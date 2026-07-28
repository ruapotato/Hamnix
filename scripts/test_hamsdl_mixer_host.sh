#!/usr/bin/env bash
# scripts/test_hamsdl_mixer_host.sh — FAST, QEMU-free host gate for the hamGame
# MIXER: the pygame.mixer-shaped tone synthesis + multi-voice SOFTWARE mixer
# (lib/hammixer.ad) wired through lib/hamgame.ad. Complements
# scripts/test_hamsdl_audio_host.sh (single-channel file playback registry) by
# proving the *summing* mixer that layer lacks.
#
# It proves, on the raw PCM the mixer produces (no audio hardware, no QEMU):
#   1. game_synth_tone renders a 440 Hz square, 50 ms, vol 128 at 22050 Hz with
#      the correct LENGTH (rate*dur = 1102 frames), correct PERIOD (44 sign
#      changes == 2*freq*dur_s zero crossings), and full AMPLITUDE (32767);
#   2. halving the volume halves the amplitude (16383) — linear scaling;
#   3. MIXING two in-phase full-scale tones SATURATES: the summed sample is a
#      POSITIVE 32767 (an unclamped s16 store would WRAP negative), and the mix
#      peak/min hit the s16 ceiling/floor — a real clamp, with teeth;
#   4. concurrent VOICES are tracked and drain to silence;
#   5. game_load_sound decodes the shipped 16-bit WAV (lib/wavdecode.ad) to a
#      Sound whose rate/sample-count match Python's `wave` reference.
#   6. the NATIVE (x86_64-adder-user) mixer demo still compiles (dual-target).
#
# Built with the frozen Python seed compiler.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamgame_mixer_host"
WAV="tests/fixtures/sounds/test.wav"
mkdir -p "$OUT"
fail=0

if [ ! -s "$WAV" ]; then
    echo "[hamsdl-mixer] regenerating $WAV"
    python3 scripts/gen_test_wav.py "$WAV" || { echo "[hamsdl-mixer] FAIL gen wav"; exit 1; }
fi

echo "[hamsdl-mixer] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamgame_mixer_host.ad "$BIN" 2>"$OUT/hamgame_mixer_compile.log"; then
    echo "[hamsdl-mixer] FAIL: host harness did not compile"; cat "$OUT/hamgame_mixer_compile.log"; exit 1
fi
echo "[hamsdl-mixer] PASS host harness compiled -> $BIN"

echo "[hamsdl-mixer] compiling NATIVE mixer demo for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamgame_mixer_demo.ad "$OUT/hamgame_mixer_native.elf" 2>"$OUT/hamgame_mixer_native.log"; then
    echo "[hamsdl-mixer] FAIL: native mixer demo did not compile"; cat "$OUT/hamgame_mixer_native.log"; exit 1
fi
echo "[hamsdl-mixer] PASS native mixer demo compiles (device dual-target intact)"

echo "[hamsdl-mixer] running host harness on $WAV ..."
DUMP="$OUT/hamgame_mixer_dump.txt"
if ! "$BIN" "$WAV" >"$DUMP" 2>&1; then
    echo "[hamsdl-mixer] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

field() { grep -E "^$1 " "$DUMP" | head -1 | awk '{print $2}'; }

expect() {  # expect <field> <value> <label>
    local got ref; got=$(field "$1"); ref="$2"
    if [ "$got" = "$ref" ]; then
        echo "[hamsdl-mixer] PASS $3: $got"
    else
        echo "[hamsdl-mixer] FAIL $3: got=$got want=$ref"; fail=1
    fi
}

# --- 1. tone length / period / amplitude ----------------------------------
# rate*dur = 22050*50/1000 = 1102 frames -> 2204 bytes.
expect RATE        22050  "mixer sample rate"
expect TONE_FRAMES 1102   "synth length == rate*duration"
expect TONE_BYTES  2204   "synth byte length == frames*2 (s16le)"
# period = 22050/440 = 50 samples; transitions at every multiple of 25 up to
# 1100 => 44 sign changes == 2*freq*dur_s (2*440*0.05).
expect TONE_ZC     44     "square period: zero crossings == 2*freq*dur_s"
expect TONE_PEAK   32767  "full-volume amplitude == s16 max"

# --- 2. linear volume scaling ---------------------------------------------
expect TONE_PEAK_HALF 16383 "half volume halves amplitude (32767*64/128)"

# --- 3. mix saturation (the whole point of a software mixer) --------------
expect PLAY_V0       0     "first tone took voice 0"
expect PLAY_V1       1     "second tone took voice 1"
expect VOICES_BEFORE 2     "two concurrent voices active before render"
# 32767 + 32767 = 65534 MUST clamp to +32767. A missing clamp would store
# 65534 into int16 and wrap to -2 (negative) -> this catches it.
expect MIX_FIRST     32767 "in-phase sum saturates POSITIVE (no wrap)"
expect MIX_PEAK      32767 "mix peak pinned at s16 ceiling"
expect MIX_MIN       -32768 "mix trough pinned at s16 floor (both halves clamp)"
expect VOICES_AFTER  0     "voices drained to silence after the clip ended"

# --- 5. WAV load vs Python `wave` reference -------------------------------
REF=$(python3 - "$WAV" <<'PY'
import sys, wave
w = wave.open(sys.argv[1], 'rb')
n = w.getnframes(); rate = w.getframerate()
print(rate, n)   # mono 16-bit: sample count == frame count
PY
)
read -r R_RATE R_SAMPLES <<<"$REF"
echo "[hamsdl-mixer] python reference: rate=$R_RATE samples=$R_SAMPLES"
[ "$(field SND_SLOT)" != "-1" ] && [ -n "$(field SND_SLOT)" ] \
    && echo "[hamsdl-mixer] PASS game_load_sound decoded the WAV (slot $(field SND_SLOT))" \
    || { echo "[hamsdl-mixer] FAIL game_load_sound did not decode the WAV"; fail=1; }
expect SND_RATE     "$R_RATE"     "loaded Sound rate matches wave reference"
expect SND_SAMPLES  "$R_SAMPLES"  "loaded Sound sample count matches reference"

if [ "$fail" -eq 0 ]; then
    echo "[hamsdl-mixer] RESULT: PASS"
    exit 0
else
    echo "[hamsdl-mixer] RESULT: FAIL"
    exit 1
fi
