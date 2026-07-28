#!/usr/bin/env bash
# scripts/test_hamaudio_mp3_host.sh — FAST, QEMU-free host gate proving the DE
# audio-player app UI renders correctly when given a REAL .mp3.
#
# The on-device MP3 playback through the HDA sink is already verified, and the
# MP3 decoder itself (lib/mp3decode.ad) is proven against ffmpeg by
# scripts/test_mp3decode_host.sh. The remaining honest gap was the PLAYER APP UI
# rendering an .mp3 (window + chrome + filename + waveform/level meter drawn from
# DECODED mp3 samples). This gate closes it on the host:
#
#   1. lib/mp3decode.ad DECODES the shipped royalty-free fixture
#      tests/fixtures/sounds/test.mp3 (44100 Hz mono) to PCM.
#   2. the SAME pure player core (lib/hamaudiocore.ad) lays out + builds the
#      scene, rasterized by lib/hamui_host.ad to a PNG a human/agent can LOOK at
#      (before = idle, after = playing mid-clip with a lit blue progress bar +
#      green level meter fed by mp3decode_peak over the decoded PCM).
#   3. DETERMINISTIC pixel readback proves the app chrome plus a NON-BLANK
#      progress fill (blue #3d7dff) and level-meter fill (green #33d17a) — from
#      the decoded mp3, NOT a WAV-only path, NOT a zero meter.
#   4. the scene display-list carries the app title + the .mp3 filename.
#   5. the NATIVE user/hamaudioscene.ad (which routes .mp3 through this decoder)
#      still compiles for x86_64-adder-user.
#
# This shares the format-agnostic UI code with the WAV host gate
# (scripts/test_hamaudio_host.sh); the two together prove BOTH source paths feed
# the identical player UI.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamaudio_mp3_host"
MP3="tests/fixtures/sounds/test.mp3"
GOLDEN="tests/fixtures/sounds/test.mp3.golden"
mkdir -p "$OUT"
fail=0

if [ ! -s "$MP3" ]; then
    echo "[hamaudio-mp3-host] regenerating $MP3 (needs ffmpeg)"
    python3 scripts/gen_test_mp3.py || { echo "[hamaudio-mp3-host] FAIL gen mp3"; exit 1; }
fi

echo "[hamaudio-mp3-host] compiling mp3 UI host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamaudioscene_mp3_host.ad "$BIN" 2>"$OUT/hamaudio_mp3_compile.log"; then
    echo "[hamaudio-mp3-host] FAIL: host harness did not compile"; cat "$OUT/hamaudio_mp3_compile.log"; exit 1
fi
echo "[hamaudio-mp3-host] PASS host harness compiled -> $BIN"

echo "[hamaudio-mp3-host] compiling NATIVE hamaudioscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamaudioscene.ad "$OUT/hamaudio_native.elf" 2>"$OUT/hamaudio_mp3_native.log"; then
    echo "[hamaudio-mp3-host] FAIL: native hamaudioscene did not compile"; cat "$OUT/hamaudio_mp3_native.log"; exit 1
fi
echo "[hamaudio-mp3-host] PASS native hamaudioscene still compiles"

echo "[hamaudio-mp3-host] rendering the audio player from $MP3 ..."
DUMP="$OUT/hamaudio_mp3_dump.txt"
BEFORE="$OUT/hamaudio_mp3_before.ppm"
AFTER="$OUT/hamaudio_mp3_after.ppm"
if ! "$BIN" "$MP3" "$BEFORE" "$AFTER" >"$DUMP" 2>&1; then
    echo "[hamaudio-mp3-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

# Render the PPMs to PNGs (saved for eyeballing) using the stdlib-only converter.
for f in before after; do
    if python3 scripts/ppm_to_png.py "$OUT/hamaudio_mp3_$f.ppm" "$OUT/hamaudio_mp3_$f.png" 2>"$OUT/hamaudio_mp3_png.log"; then
        echo "[hamaudio-mp3-host] PASS rendered $OUT/hamaudio_mp3_$f.png ($(file -b "$OUT/hamaudio_mp3_$f.png" 2>/dev/null))"
    else
        echo "[hamaudio-mp3-host] FAIL png conversion ($f)"; cat "$OUT/hamaudio_mp3_png.log"; fail=1
    fi
done

field()  { grep -E "^$1 " "$DUMP"   | head -1 | awk '{print $2}'; }
gfield() { grep -E "^$1 " "$GOLDEN" | head -1 | awk '{print $2}'; }

# --- DECODE sanity: the mp3 really decoded (details proven by test_mp3decode) -
if [ "$(field DECODE_OK)" = "1" ]; then
    echo "[hamaudio-mp3-host] PASS lib/mp3decode decoded the MP3 bitstream"
else
    echo "[hamaudio-mp3-host] FAIL lib/mp3decode did not decode the mp3"; fail=1
fi
cmp_gold() {  # cmp_gold <dump-field> <golden-field> <label>
    local got ref; got=$(field "$1"); ref=$(gfield "$2")
    if [ "$got" = "$ref" ]; then echo "[hamaudio-mp3-host] PASS $3: $got == golden";
    else echo "[hamaudio-mp3-host] FAIL $3: harness=$got golden=$ref"; fail=1; fi
}
cmp_gold RATE     RATE     "sample rate"
cmp_gold CHANNELS CHANNELS "channel count"
cmp_gold NFRAMES  NFRAMES  "decoded sample-frame count"

# Duration must be non-zero (the player's progress bar/time readout depend on it).
DUR=$(field DURATION_MS)
if [ -n "$DUR" ] && [ "$DUR" -gt 0 ]; then
    echo "[hamaudio-mp3-host] PASS duration decoded (${DUR}ms) -> progress bar scaled"
else
    echo "[hamaudio-mp3-host] FAIL duration is zero/absent"; fail=1
fi

# The meter must be fed a real, non-trivial level from the decoded PCM.
LVL=$(field METER_LEVEL)
if [ -n "$LVL" ] && [ "$LVL" -gt 1000 ]; then
    echo "[hamaudio-mp3-host] PASS level meter fed from decoded mp3 (level=$LVL)"
else
    echo "[hamaudio-mp3-host] FAIL level meter got silence/zero from mp3 (level=$LVL)"; fail=1
fi

# --- INPUT command queue (shared core, mp3-driven) ------------------------
[ "$(field CMD_SPACE)" = "1" ] && echo "[hamaudio-mp3-host] PASS space toggles play/pause" || { echo "[hamaudio-mp3-host] FAIL space did not enqueue play/pause"; fail=1; }
[ "$(field CMD_SEEK)" = "3" ]  && echo "[hamaudio-mp3-host] PASS progress-bar click enqueues a SEEK" || { echo "[hamaudio-mp3-host] FAIL bar click did not enqueue a seek"; fail=1; }
SEEK=$(field SEEK_MS)
if [ -n "$SEEK" ] && awk -v s="$SEEK" -v d="$DUR" 'BEGIN{exit !(s>d*0.4 && s<d*0.6)}'; then
    echo "[hamaudio-mp3-host] PASS centre-bar seek landed mid-clip: ${SEEK}ms (~50% of ${DUR}ms)"
else
    echo "[hamaudio-mp3-host] FAIL centre-bar seek off target: ${SEEK}ms of ${DUR}ms"; fail=1
fi

# --- SCENE display-list assertions (app chrome + mp3 filename) ------------
assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamaudio-mp3-host] PASS $2";
    else echo "[hamaudio-mp3-host] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_grep '^# scene v1 hamui'             "scene header emitted"
assert_grep '^glyphs 12 8 \"Audio Player\"' "bold title in the header"
assert_grep '^glyphs 20 44 \"test.mp3\"'    "now-playing .mp3 filename shown"
assert_grep '^roundrect .* 6 #'             "rounded transport buttons drawn"

# --- RASTER proof: the lit bars actually rendered from the decoded mp3 -----
# PIX_BAR is the blue progress fill (#3d7dff = 4029951), PIX_METER the green
# level fill (#33d17a = 3395962), sampled from the 'after' (playing) frame.
[ "$(field PIX_BAR)" = "4029951" ]   && echo "[hamaudio-mp3-host] PASS progress bar rasterized blue (#3d7dff)"  || { echo "[hamaudio-mp3-host] FAIL progress bar not blue: $(field PIX_BAR)"; fail=1; }
[ "$(field PIX_METER)" = "3395962" ] && echo "[hamaudio-mp3-host] PASS level meter rasterized green (#33d17a) from decoded mp3" || { echo "[hamaudio-mp3-host] FAIL level meter not green: $(field PIX_METER)"; fail=1; }

if [ "$fail" -eq 0 ]; then
    echo "[hamaudio-mp3-host] RESULT: PASS"
    exit 0
else
    echo "[hamaudio-mp3-host] RESULT: FAIL"
    exit 1
fi
