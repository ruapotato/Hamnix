#!/usr/bin/env bash
# scripts/test_hamaudio_host.sh — FAST, QEMU-free host gate for the hamaudio
# player: the WAV DECODER (lib/wavdecode.ad) and the player UI
# (lib/hamaudiocore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Mirrors scripts/test_ham2048_host.sh.
#
# It proves, in milliseconds and with no audio hardware:
#   1. lib/wavdecode.ad decodes the shipped royalty-free fixture
#      tests/fixtures/sounds/test.wav and extracts the EXACT format, sample-
#      frame count, duration, PCM checksum and peak that Python's `wave`
#      module computes over the same file — a real decoder correctness signal.
#   2. the pure player core lays out + builds the scene, which rasterizes to a
#      PNG a human/agent can LOOK at (before = idle, after = playing mid-clip
#      with a lit blue progress bar + green level meter).
#   3. the pure input handlers enqueue the right commands (space -> play/pause,
#      progress-bar click -> seek to ~50%, Play button -> play/pause).
#   4. the NATIVE user/hamaudioscene.ad still compiles from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamaudio_host"
WAV="tests/fixtures/sounds/test.wav"
mkdir -p "$OUT"
fail=0

# Ensure the fixture exists (regenerate deterministically if missing).
if [ ! -s "$WAV" ]; then
    echo "[hamaudio-host] regenerating $WAV"
    python3 scripts/gen_test_wav.py "$WAV" || { echo "[hamaudio-host] FAIL gen wav"; exit 1; }
fi

echo "[hamaudio-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamaudioscene_host.ad "$BIN" 2>"$OUT/hamaudio_compile.log"; then
    echo "[hamaudio-host] FAIL: host harness did not compile"; cat "$OUT/hamaudio_compile.log"; exit 1
fi
echo "[hamaudio-host] PASS host harness compiled -> $BIN"

echo "[hamaudio-host] compiling NATIVE hamaudioscene for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamaudioscene.ad "$OUT/hamaudio_native.elf" 2>"$OUT/hamaudio_native.log"; then
    echo "[hamaudio-host] FAIL: native hamaudioscene did not compile"; cat "$OUT/hamaudio_native.log"; exit 1
fi
echo "[hamaudio-host] PASS native hamaudioscene still compiles"

# --- DEFAULT-OPEN: bare `hamaudioscene` must default to the shipped music demo,
# NOT test.wav. Verify (1) at the source level that track 0 of the bare-launch
# playlist is the music-demo mp3, and (2) by actually DECODING the shipped
# fixture through the SAME mp3 path the app uses (rate/channels/duration).
DEMO_MP3="tests/fixtures/sounds/hamnix-music-demo.mp3"
if grep -Eq 'track_paths\[0\].*hamnix-music-demo\.mp3' user/hamaudioscene.ad; then
    echo "[hamaudio-host] PASS bare-launch default track 0 = the Hamnix Music Demo mp3"
else
    echo "[hamaudio-host] FAIL bare-launch default is not the music demo"; fail=1
fi
if grep -Eq 'track_paths\[0\].*test\.wav' user/hamaudioscene.ad; then
    echo "[hamaudio-host] FAIL test.wav is still the default open (track 0)"; fail=1
else
    echo "[hamaudio-host] PASS test.wav is no longer the default open"
fi
if [ -s "$DEMO_MP3" ]; then
    MP3BIN="$OUT/hamaudio_mp3_host"
    if python3 -m compiler.adder compile --target=x86_64-linux \
            user/hamaudioscene_mp3_host.ad -o "$MP3BIN" 2>"$OUT/hamaudio_demo_compile.log"; then
        DEMODUMP="$OUT/hamaudio_demo_dump.txt"
        if "$MP3BIN" "$DEMO_MP3" "$OUT/demo_b.ppm" "$OUT/demo_a.ppm" >"$DEMODUMP" 2>&1; then
            df() { grep -E "^$1 " "$DEMODUMP" | head -1 | awk '{print $2}'; }
            [ "$(df DECODE_OK)" = "1" ] && echo "[hamaudio-host] PASS default music-demo mp3 decodes (lib/mp3decode)" || { echo "[hamaudio-host] FAIL default music-demo mp3 did not decode"; fail=1; }
            DRATE=$(df RATE); DCH=$(df CHANNELS); DDUR=$(df DURATION_MS)
            if [ -n "$DRATE" ] && [ "$DRATE" -gt 0 ] && [ -n "$DCH" ] && [ "$DCH" -gt 0 ] && [ -n "$DDUR" ] && [ "$DDUR" -gt 0 ]; then
                echo "[hamaudio-host] PASS default music-demo format: rate=${DRATE} ch=${DCH} dur=${DDUR}ms"
            else
                echo "[hamaudio-host] FAIL default music-demo format bad: rate=$DRATE ch=$DCH dur=$DDUR"; fail=1
            fi
        else
            echo "[hamaudio-host] FAIL music-demo decode harness exited non-zero"; cat "$DEMODUMP"; fail=1
        fi
    else
        echo "[hamaudio-host] FAIL mp3 host harness did not compile"; cat "$OUT/hamaudio_demo_compile.log"; fail=1
    fi
else
    echo "[hamaudio-host] WARN music-demo fixture absent ($DEMO_MP3) — skipping decode check"
fi

echo "[hamaudio-host] running host harness on $WAV ..."
DUMP="$OUT/hamaudio_dump.txt"
BEFORE="$OUT/hamaudio_before.ppm"
AFTER="$OUT/hamaudio_after.ppm"
PLAYLIST="$OUT/hamaudio_playlist.ppm"
TRANSPORT="$OUT/hamaudio_transport.ppm"
if ! "$BIN" "$WAV" "$BEFORE" "$AFTER" "$PLAYLIST" "$TRANSPORT" >"$DUMP" 2>&1; then
    echo "[hamaudio-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

# Render the PPMs to PNGs (saved for eyeballing) using the stdlib-only converter.
for f in before after playlist transport; do
    if python3 scripts/ppm_to_png.py "$OUT/hamaudio_$f.ppm" "$OUT/hamaudio_$f.png" 2>"$OUT/hamaudio_png.log"; then
        echo "[hamaudio-host] PASS rendered $OUT/hamaudio_$f.png ($(file -b "$OUT/hamaudio_$f.png" 2>/dev/null))"
    else
        echo "[hamaudio-host] FAIL png conversion ($f)"; cat "$OUT/hamaudio_png.log"; fail=1
    fi
done

field() { grep -E "^$1 " "$DUMP" | head -1 | awk '{print $2}'; }

# --- GROUND TRUTH: Python `wave` reference over the SAME file --------------
REF=$(python3 - "$WAV" <<'PY'
import sys, wave, struct
w = wave.open(sys.argv[1], 'rb')
n = w.getnframes(); ch = w.getnchannels(); sw = w.getsampwidth(); rate = w.getframerate()
data = w.readframes(n)
csum = sum(data) & 0xffffffff
sm = struct.unpack("<%dh" % (len(data)//2), data)
peak = max(abs(x) for x in sm) if sm else 0
print(rate, ch, sw*8, n, n*1000//rate, len(data), csum, peak)
PY
)
read -r R_RATE R_CH R_BITS R_NF R_DUR R_DLEN R_CSUM R_PEAK <<<"$REF"
echo "[hamaudio-host] python reference: rate=$R_RATE ch=$R_CH bits=$R_BITS nframes=$R_NF dur=$R_DUR datalen=$R_DLEN csum=$R_CSUM peak=$R_PEAK"

cmp_field() {  # cmp_field <DUMP-field> <ref-value> <label>
    local got ref; got=$(field "$1"); ref="$2"
    if [ "$got" = "$ref" ]; then
        echo "[hamaudio-host] PASS decode $3: $got == reference"
    else
        echo "[hamaudio-host] FAIL decode $3: harness=$got reference=$ref"; fail=1
    fi
}

if [ "$(field DECODE_OK)" = "1" ]; then
    echo "[hamaudio-host] PASS lib/wavdecode parsed the RIFF/WAVE container"
else
    echo "[hamaudio-host] FAIL lib/wavdecode did not parse the container"; fail=1
fi
cmp_field RATE        "$R_RATE" "sample rate"
cmp_field CHANNELS    "$R_CH"   "channel count"
cmp_field BITS        "$R_BITS" "bit depth"
cmp_field NFRAMES     "$R_NF"   "sample-frame count"
cmp_field DURATION_MS "$R_DUR"  "duration (ms)"
cmp_field DATALEN     "$R_DLEN" "PCM payload length"
cmp_field PCM_CHECKSUM "$R_CSUM" "PCM byte checksum (bit-exact payload)"
cmp_field PCM_PEAK    "$R_PEAK" "PCM peak sample"

# --- INPUT command queue --------------------------------------------------
[ "$(field CMD_SPACE)" = "1" ] && echo "[hamaudio-host] PASS space toggles play/pause (CMD_PLAYPAUSE)" || { echo "[hamaudio-host] FAIL space did not enqueue play/pause"; fail=1; }
[ "$(field CMD_SEEK)" = "3" ]  && echo "[hamaudio-host] PASS progress-bar click enqueues a SEEK"          || { echo "[hamaudio-host] FAIL bar click did not enqueue a seek"; fail=1; }
[ "$(field CMD_PLAY)" = "1" ]  && echo "[hamaudio-host] PASS Play button enqueues play/pause"             || { echo "[hamaudio-host] FAIL Play button did not enqueue play/pause"; fail=1; }
# Seeking to the centre of the bar must land near 50% of the duration.
SEEK=$(field SEEK_MS)
if [ -n "$SEEK" ] && awk -v s="$SEEK" -v d="$R_DUR" 'BEGIN{exit !(s>d*0.4 && s<d*0.6)}'; then
    echo "[hamaudio-host] PASS centre-bar seek landed mid-clip: ${SEEK}ms (~50% of ${R_DUR}ms)"
else
    echo "[hamaudio-host] FAIL centre-bar seek off target: ${SEEK}ms of ${R_DUR}ms"; fail=1
fi

# --- SCENE display-list assertions ---------------------------------------
assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[hamaudio-host] PASS $2";
    else echo "[hamaudio-host] FAIL $2 (missing: $1)"; fail=1; fi
}
assert_grep '^# scene v1 hamui'                    "scene header emitted"
assert_grep '^glyphs 12 8 \"Audio Player\"'        "bold title in the header"
assert_grep '^glyphs 20 44 \"test.wav\"'           "now-playing filename shown"
assert_grep '^roundrect .* 6 #'                    "rounded transport buttons drawn"

# --- RASTER proof: the lit bars actually rendered the right colours --------
# PIX_BAR is the blue progress fill (#3d7dff = 4029951), PIX_METER the green
# level fill (#33d17a = 3395962), sampled from the 'after' (playing) frame.
[ "$(field PIX_BAR)" = "4029951" ]  && echo "[hamaudio-host] PASS progress bar rasterized blue (#3d7dff)"  || { echo "[hamaudio-host] FAIL progress bar not blue: $(field PIX_BAR)"; fail=1; }
[ "$(field PIX_METER)" = "3395962" ] && echo "[hamaudio-host] PASS level meter rasterized green (#33d17a)" || { echo "[hamaudio-host] FAIL level meter not green: $(field PIX_METER)"; fail=1; }

# --- PLAYLIST panel (taller frame): track list + active-row highlight + click
# -> SELECT. The active row (#25406a = 2441322) must be highlighted, and a
# click on a different row must enqueue HAMAUDIO_CMD_SELECT (4) with that row's
# index. Proves the new playlist UI both RENDERS and ROUTES input.
[ "$(field TRACK_COUNT)" = "3" ] && echo "[hamaudio-host] PASS playlist holds 3 tracks" || { echo "[hamaudio-host] FAIL playlist track count: $(field TRACK_COUNT)"; fail=1; }
PLR=$(field PL_ROWS)
if [ -n "$PLR" ] && [ "$PLR" -ge 3 ]; then
    echo "[hamaudio-host] PASS taller window opened $PLR playlist rows"
else
    echo "[hamaudio-host] FAIL playlist rows did not open in tall window: $PLR"; fail=1
fi
[ "$(field PIX_ACTIVE_ROW)" = "2441322" ] && echo "[hamaudio-host] PASS active track row rasterized highlight (#25406a)" || { echo "[hamaudio-host] FAIL active row not highlighted: $(field PIX_ACTIVE_ROW)"; fail=1; }
assert_grep '^glyphs 20 [0-9]+ \"Playlist\"' "playlist heading drawn"
assert_grep '^glyphs [0-9]+ [0-9]+ \"intro.wav\"' "track 0 name drawn"
assert_grep '^glyphs [0-9]+ [0-9]+ \"outro.mp3\"' "track 2 name drawn"
[ "$(field CMD_SELECT)" = "4" ] && echo "[hamaudio-host] PASS playlist-row click enqueues a SELECT" || { echo "[hamaudio-host] FAIL row click did not enqueue SELECT: $(field CMD_SELECT)"; fail=1; }
[ "$(field SEL_INDEX)" = "0" ] && echo "[hamaudio-host] PASS SELECT targets the clicked row (index 0)" || { echo "[hamaudio-host] FAIL SELECT index wrong: $(field SEL_INDEX)"; fail=1; }

# --- VLC-style extended transport (tall window): prev/next, volume, repeat,
# shuffle. Proves each control both APPEARS (extended layout) and ROUTES the
# right command / toggles the right state.
[ "$(field EXTENDED)" = "1" ] && echo "[hamaudio-host] PASS tall window enables the extended transport" || { echo "[hamaudio-host] FAIL extended transport not enabled: $(field EXTENDED)"; fail=1; }
[ "$(field CMD_NEXT)" = "6" ] && echo "[hamaudio-host] PASS Next button enqueues CMD_NEXT" || { echo "[hamaudio-host] FAIL Next button routing: $(field CMD_NEXT)"; fail=1; }
[ "$(field CMD_PREV)" = "5" ] && echo "[hamaudio-host] PASS Prev button enqueues CMD_PREV" || { echo "[hamaudio-host] FAIL Prev button routing: $(field CMD_PREV)"; fail=1; }
[ "$(field CMD_VOLUME)" = "7" ] && echo "[hamaudio-host] PASS volume slider enqueues CMD_VOLUME" || { echo "[hamaudio-host] FAIL volume routing: $(field CMD_VOLUME)"; fail=1; }
VOL=$(field VOLUME)
if [ -n "$VOL" ] && [ "$VOL" -ge 20 ] && [ "$VOL" -le 30 ]; then
    echo "[hamaudio-host] PASS quarter-slider click set volume to ~25% ($VOL)"
else
    echo "[hamaudio-host] FAIL quarter-slider volume off target: $VOL"; fail=1
fi
# Repeat cycles off(0) -> all(1) -> one(2); toggles must NOT enqueue a command.
[ "$(field REPEAT_1)" = "1" ] && echo "[hamaudio-host] PASS first Repeat click -> repeat-all (1)" || { echo "[hamaudio-host] FAIL repeat click 1: $(field REPEAT_1)"; fail=1; }
[ "$(field REPEAT_2)" = "2" ] && echo "[hamaudio-host] PASS second Repeat click -> repeat-one (2)" || { echo "[hamaudio-host] FAIL repeat click 2: $(field REPEAT_2)"; fail=1; }
[ "$(field CMD_AFTER_RPT)" = "0" ] && echo "[hamaudio-host] PASS Repeat toggle is pure UI state (no driver command)" || { echo "[hamaudio-host] FAIL repeat toggle leaked a command: $(field CMD_AFTER_RPT)"; fail=1; }
[ "$(field SHUFFLE)" = "1" ] && echo "[hamaudio-host] PASS Shuffle click turns shuffle on" || { echo "[hamaudio-host] FAIL shuffle toggle: $(field SHUFFLE)"; fail=1; }
# The extended transport display list must carry the new controls' labels.
assert_grep '^glyphs [0-9]+ [0-9]+ \"Prev\"'   "Prev button label drawn"
assert_grep '^glyphs [0-9]+ [0-9]+ \"Next\"'   "Next button label drawn"
assert_grep '^glyphs [0-9]+ [0-9]+ \"Volume\"' "Volume slider labelled"
assert_grep '^glyphs [0-9]+ [0-9]+ \"Shuf\"'   "Shuffle toggle drawn"
assert_grep '^glyphs [0-9]+ [0-9]+ \"Rpt\"'    "Repeat toggle drawn"

if [ "$fail" -eq 0 ]; then
    echo "[hamaudio-host] RESULT: PASS"
    exit 0
else
    echo "[hamaudio-host] RESULT: FAIL"
    exit 1
fi
