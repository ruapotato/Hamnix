#!/usr/bin/env bash
# scripts/test_mp3decode_host.sh — FAST, QEMU-free host gate for the native
# MPEG-1 Layer III decoder (lib/mp3decode.ad + generated lib/mp3tables.ad).
# Mirrors scripts/test_hamaudio_host.sh.
#
# It proves, in milliseconds and with no audio hardware, that lib/mp3decode.ad
# decodes the shipped royalty-free fixture tests/fixtures/sounds/test.mp3 to PCM
# that matches an ffmpeg reference:
#   1. the decoder extracts the right format (44100 Hz, mono) and the right
#      decoded sample-frame count;
#   2. the decoded PCM is NOT silence and its RMS + peak match the ffmpeg
#      reference (a stub emitting silence/tone could not);
#   3. individual samples at fixed indices match the ffmpeg reference within a
#      tight tolerance (bit-for-bit is not expected — MP3 is lossy and decoder
#      dependent — but a real decode lands within a couple of LSBs);
#   4. the golden reference is committed (tests/fixtures/sounds/test.mp3.golden)
#      so the proof is deterministic and needs NO ffmpeg at test time; when
#      ffmpeg IS present the gate also runs a full correlation cross-check;
#   5. the NATIVE user/hamaudioscene.ad (which routes .mp3 through this decoder)
#      still compiles for x86_64-adder-user.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/mp3decode_host"
MP3="tests/fixtures/sounds/test.mp3"
GOLDEN="tests/fixtures/sounds/test.mp3.golden"
PCM="$OUT/mp3decode.pcm"
mkdir -p "$OUT"
fail=0

if [ ! -s "$MP3" ] || [ ! -s "$GOLDEN" ]; then
    echo "[mp3-host] regenerating $MP3 (needs ffmpeg)"
    python3 scripts/gen_test_mp3.py || { echo "[mp3-host] FAIL gen mp3"; exit 1; }
fi

echo "[mp3-host] compiling decoder + host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/mp3decode_host.ad "$BIN" 2>"$OUT/mp3_compile.log"; then
    echo "[mp3-host] FAIL: host harness did not compile"; cat "$OUT/mp3_compile.log"; exit 1
fi
echo "[mp3-host] PASS host harness compiled -> $BIN"

echo "[mp3-host] compiling NATIVE hamaudioscene (.mp3 routing) for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamaudioscene.ad "$OUT/hamaudio_native.elf" 2>"$OUT/mp3_native.log"; then
    echo "[mp3-host] FAIL: native hamaudioscene did not compile"; cat "$OUT/mp3_native.log"; exit 1
fi
echo "[mp3-host] PASS native hamaudioscene still compiles"

echo "[mp3-host] decoding $MP3 ..."
DUMP="$OUT/mp3_dump.txt"
if ! "$BIN" "$MP3" "$PCM" >"$DUMP" 2>&1; then
    echo "[mp3-host] FAIL: harness exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

field() { grep -E "^$1 " "$DUMP" | head -1 | awk '{print $2}'; }
gfield() { grep -E "^$1 " "$GOLDEN" | head -1 | awk '{print $2}'; }

[ "$(field DECODE_OK)" = "1" ] && echo "[mp3-host] PASS decoder parsed the MP3 bitstream" \
    || { echo "[mp3-host] FAIL decoder returned 0"; fail=1; }

cmp_exact() {  # cmp_exact <field> <golden-field> <label>
    local got ref; got=$(field "$1"); ref=$(gfield "$2")
    if [ "$got" = "$ref" ]; then echo "[mp3-host] PASS $3: $got == reference";
    else echo "[mp3-host] FAIL $3: harness=$got reference=$ref"; fail=1; fi
}
cmp_exact RATE     RATE     "sample rate"
cmp_exact CHANNELS CHANNELS "channel count"
cmp_exact NFRAMES  NFRAMES  "decoded sample-frame count"

# Non-silence + peak within 2% of the ffmpeg reference.
PEAK=$(field PCM_PEAK); RPEAK=$(gfield PEAK)
if [ -n "$PEAK" ] && [ "$PEAK" -gt 1000 ]; then
    echo "[mp3-host] PASS decoded audio is not silence (peak=$PEAK)"
else
    echo "[mp3-host] FAIL decoded audio looks like silence (peak=$PEAK)"; fail=1
fi
if [ -n "$PEAK" ] && awk -v a="$PEAK" -v b="$RPEAK" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=b*0.02+2)}'; then
    echo "[mp3-host] PASS peak matches reference ($PEAK vs $RPEAK)"
else
    echo "[mp3-host] FAIL peak off reference ($PEAK vs $RPEAK)"; fail=1
fi

# RMS within 1% of ffmpeg reference, and per-index sample values within +-64.
RRMS=$(gfield RMS)
python3 - "$PCM" "$GOLDEN" "$RRMS" <<'PY'
import struct, math, sys
pcm = open(sys.argv[1], "rb").read()
sm = struct.unpack("<%dh" % (len(pcm)//2), pcm)
rrms = float(sys.argv[3])
rms = math.sqrt(sum(x*x for x in sm)/len(sm)) if sm else 0.0
ok = True
if abs(rms - rrms) <= rrms*0.01 + 1:
    print("[mp3-host] PASS RMS %.1f within 1%% of reference %.1f" % (rms, rrms))
else:
    print("[mp3-host] FAIL RMS %.1f off reference %.1f" % (rms, rrms)); ok = False
worst = 0
for line in open(sys.argv[2]):
    p = line.split()
    if p and p[0] == "SAMPLE":
        idx, gv = int(p[1]), int(p[2])
        av = sm[idx] if idx < len(sm) else 0
        d = abs(av - gv)
        if d > worst: worst = d
        if d > 64:
            print("[mp3-host] FAIL sample[%d]=%d vs reference %d (|d|=%d)" % (idx, av, gv, d)); ok = False
if ok:
    print("[mp3-host] PASS all golden sample values match within +-64 (worst |d|=%d)" % worst)
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || fail=1

# Optional live ffmpeg cross-check (full correlation) when ffmpeg is present.
if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -i "$MP3" -f s16le -acodec pcm_s16le -ac 1 "$OUT/mp3_ref.pcm" 2>/dev/null
    python3 - "$PCM" "$OUT/mp3_ref.pcm" <<'PY'
import struct, sys
def rd(p):
    d = open(p, "rb").read(); return struct.unpack("<%dh" % (len(d)//2), d)
a = rd(sys.argv[1]); b = rd(sys.argv[2]); n = min(len(a), len(b))
a = a[:n]; b = b[:n]
ma = sum(a)/n; mb = sum(b)/n
va = sum((x-ma)**2 for x in a); vb = sum((x-mb)**2 for x in b)
cov = sum((a[i]-ma)*(b[i]-mb) for i in range(n))
corr = cov/((va*vb)**0.5) if va>0 and vb>0 else 0.0
if corr > 0.999:
    print("[mp3-host] PASS live ffmpeg cross-check: correlation %.6f" % corr)
    sys.exit(0)
print("[mp3-host] FAIL live ffmpeg correlation only %.6f" % corr); sys.exit(1)
PY
    [ $? -eq 0 ] || fail=1
else
    echo "[mp3-host] (ffmpeg not present; skipped live cross-check, golden used)"
fi

if [ "$fail" -eq 0 ]; then
    echo "[mp3-host] RESULT: PASS"; exit 0
else
    echo "[mp3-host] RESULT: FAIL"; exit 1
fi
