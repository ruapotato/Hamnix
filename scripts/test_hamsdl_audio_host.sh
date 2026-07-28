#!/usr/bin/env bash
# scripts/test_hamsdl_audio_host.sh — FAST, QEMU-free host gate for the hamSDL
# AUDIO API: the SDL_mixer/pygame-style sound layer on the hamSDL game surface
# (lib/hamsdl_audio.ad registry core + lib/hamsdl_audio_dev.ad device backend +
# lib/hamsdl_audio_host.ad host backend). Mirrors scripts/test_hamsdl_host.sh /
# scripts/test_hamaudio_host.sh.
#
# It proves, in milliseconds and with no audio hardware:
#   1. sdl_load_sound() BRIDGES to the verified decode stack — it decodes the
#      shipped royalty-free tests/fixtures/sounds/test.wav to the EXACT format
#      (rate/channels/bits/PCM length) Python's `wave` module reports, and
#      decodes test.mp3 via lib/mp3decode into a named registry slot.
#   2. sdl_play_sound() targets the loaded sound (LAST_PLAY == the load slot) and
#      REJECTS an unknown name; sdl_play_music() latches the loop + music slot.
#   3. sdl_set_volume()/sdl_audio_volume() round-trip and clamp to 0..128.
#   4. the DEVICE build (user/hamsdl_audio_demo.ad, lib/hamsdl_audio_dev.ad) still
#      compiles for x86_64-adder-user, so the dual-target seam can't silently rot.
#
# The actual DAC output (guest -> devaudio -> HDA -> codec) is proven by the
# on-device capture gate scripts/test_hamaudio_playback.sh; this gate is the
# fast structural signal that the new API wires to hamaudiocore's decode+/dev/audio
# stack correctly.
#
# Built with the frozen Python seed compiler (compiles 100% of the tree).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsdl_audio_host"
WAV="tests/fixtures/sounds/test.wav"
MP3="tests/fixtures/sounds/test.mp3"
mkdir -p "$OUT"
fail=0

# Ensure the WAV fixture exists (regenerate deterministically if missing).
if [ ! -s "$WAV" ]; then
    echo "[hamsdl-audio] regenerating $WAV"
    python3 scripts/gen_test_wav.py "$WAV" || { echo "[hamsdl-audio] FAIL gen wav"; exit 1; }
fi
if [ ! -s "$MP3" ]; then
    echo "[hamsdl-audio] FAIL missing fixture $MP3"; exit 1
fi

echo "[hamsdl-audio] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsdl_audio_host.ad "$BIN" 2>"$OUT/hamsdl_audio_compile.log"; then
    echo "[hamsdl-audio] FAIL: host harness did not compile"; cat "$OUT/hamsdl_audio_compile.log"; exit 1
fi
echo "[hamsdl-audio] PASS host harness compiled -> $BIN"

echo "[hamsdl-audio] compiling NATIVE audio demo for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamsdl_audio_demo.ad "$OUT/hamsdl_audio_native.elf" 2>"$OUT/hamsdl_audio_native.log"; then
    echo "[hamsdl-audio] FAIL: native audio demo did not compile"; cat "$OUT/hamsdl_audio_native.log"; exit 1
fi
echo "[hamsdl-audio] PASS native audio demo compiles (device dual-target intact)"

echo "[hamsdl-audio] running host harness on $WAV + $MP3 ..."
DUMP="$OUT/hamsdl_audio_dump.txt"
if ! "$BIN" "$WAV" "$MP3" >"$DUMP" 2>&1; then
    echo "[hamsdl-audio] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

field() { grep -E "^$1 " "$DUMP" | head -1 | awk '{print $2}'; }

expect() {  # expect <field> <value> <label>
    local got ref; got=$(field "$1"); ref="$2"
    if [ "$got" = "$ref" ]; then
        echo "[hamsdl-audio] PASS $3: $got"
    else
        echo "[hamsdl-audio] FAIL $3: got=$got want=$ref"; fail=1
    fi
}

# --- GROUND TRUTH: Python `wave` reference over the SAME wav ---------------
REF=$(python3 - "$WAV" <<'PY'
import sys, wave
w = wave.open(sys.argv[1], 'rb')
n = w.getnframes(); ch = w.getnchannels(); sw = w.getsampwidth(); rate = w.getframerate()
print(rate, ch, sw*8, len(w.readframes(n)))
PY
)
read -r R_RATE R_CH R_BITS R_DLEN <<<"$REF"
echo "[hamsdl-audio] python reference: rate=$R_RATE ch=$R_CH bits=$R_BITS datalen=$R_DLEN"

expect INIT      0        "sdl_audio_init opened the (structural) device"
[ "$(field LOAD_SLOT)" != "-1" ] && echo "[hamsdl-audio] PASS sdl_load_sound decoded+registered the wav (slot $(field LOAD_SLOT))" || { echo "[hamsdl-audio] FAIL sdl_load_sound did not register the wav"; fail=1; }
expect RATE      "$R_RATE"  "decoded sample rate matches wave reference"
expect CHANNELS  "$R_CH"    "decoded channel count matches reference"
expect BITS      "$R_BITS"  "decoded bit depth matches reference"
expect DATALEN   "$R_DLEN"  "decoded PCM length matches reference"

# --- play targeting ---
expect PLAY_OK   0        "sdl_play_sound played the loaded sound"
if [ "$(field LAST_PLAY)" = "$(field LOAD_SLOT)" ]; then
    echo "[hamsdl-audio] PASS sdl_play_sound targeted the loaded slot"
else
    echo "[hamsdl-audio] FAIL play targeted wrong slot: last=$(field LAST_PLAY) load=$(field LOAD_SLOT)"; fail=1
fi
expect PLAY_MISSING -1     "sdl_play_sound rejects an unknown name"

# --- volume round-trip + clamp ---
expect VOL_GET      64     "sdl_set_volume/sdl_audio_volume round-trip"
expect VOL_CLAMP_HI 128    "volume clamps at 128 (SDL_mixer unity)"
expect VOL_CLAMP_LO 0      "volume clamps at 0 (silent)"

# --- music streaming intent (real mp3 decode) ---
expect MUSIC_OK    0       "sdl_play_music decoded+staged the mp3"
[ "$(field MUSIC_SLOT)" != "-1" ] && echo "[hamsdl-audio] PASS music registered in a slot ($(field MUSIC_SLOT))" || { echo "[hamsdl-audio] FAIL music slot not registered"; fail=1; }
expect MUSIC_LOOP  1       "sdl_play_music latched the loop flag"
MR=$(field MUSIC_RATE)
if [ -n "$MR" ] && [ "$MR" -gt 0 ]; then
    echo "[hamsdl-audio] PASS mp3 decoded to a real sample rate (${MR} Hz)"
else
    echo "[hamsdl-audio] FAIL mp3 decode produced no rate: $MR"; fail=1
fi
MDL=$(field MUSIC_DATALEN)
if [ -n "$MDL" ] && [ "$MDL" -gt 0 ]; then
    echo "[hamsdl-audio] PASS mp3 decoded to a non-empty PCM buffer (${MDL} bytes)"
else
    echo "[hamsdl-audio] FAIL mp3 decode produced no PCM: $MDL"; fail=1
fi
expect MUSIC_STOPPED 1     "sdl_stop_music stopped the music stream"
expect COUNT        2      "registry holds the SFX + reserved music slot"

if [ "$fail" -eq 0 ]; then
    echo "[hamsdl-audio] RESULT: PASS"
    exit 0
else
    echo "[hamsdl-audio] RESULT: FAIL"
    exit 1
fi
