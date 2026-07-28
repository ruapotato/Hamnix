#!/usr/bin/env bash
# scripts/test_hambrowse_btncenter_host.sh — FAST, QEMU-free gate for two
# push-button paint fixes in the native browser engine:
#
#  (1) OWN-BACKGROUND FILL (lib/web/dom/forms.ad <button> path). A <button> whose
#      author background resolves to none — google's "AI Mode" pill ships
#      `.plR5qb{background:inherit}` and paints its light-grey via a descendant
#      fill-layer our engine does not composite — must fall back to the UA
#      push-button grey (#e0e3e7), NOT let the COLOURED container it sits on show
#      through as a transparent-looking pill. The button reads its OWN matched
#      background, not the ambient container background.
#
#  (2) VERTICALLY-CENTRED LABEL (lib/htmlpage.ad button paint). A control taller
#      than one text row (CSS `height`, or google's ~36px search / AI-Mode pills)
#      must centre its label in the BOX, not leave it at the first text row's
#      baseline hugging the top edge.
#
# Fixture: tests/fixtures/hambrowse_btncenter.html — an `background:inherit`
# <button> on a #3366cc bar, and a `height:44px` submit button on white.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
FIX="tests/fixtures/hambrowse_btncenter.html"
mkdir -p "$OUT"
fail=0

echo "[hb-btncenter] compiling text harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$OUT/hambrowse_host" 2>"$OUT/compile.log"; then
    echo "[hb-btncenter] FAIL: host harness did not compile"; cat "$OUT/compile.log"; exit 1
fi
echo "[hb-btncenter] PASS host harness compiled"

echo "[hb-btncenter] compiling native hambrowse for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hambrowse.ad "$OUT/hambrowse_native.elf" 2>"$OUT/native.log"; then
    echo "[hb-btncenter] FAIL: native hambrowse did not compile"; cat "$OUT/native.log"; exit 1
fi
echo "[hb-btncenter] PASS native hambrowse still compiles"

# ---- (1) own-background fill: the inherit button gets the UA grey face -------
D="$OUT/btncenter.txt"
"$OUT/hambrowse_host" "$FIX" 900 >"$D" 2>&1 || { echo "[hb-btncenter] FAIL: text render exited non-zero"; cat "$D"; exit 1; }
b0=$(grep -E "^SEGBTN 0 " "$D" | head -1)
echo "[hb-btncenter] $b0"
if printf '%s' "$b0" | grep -qF "bg#e0e3e7"; then
    echo "[hb-btncenter] PASS: inherit-bg button fills with UA grey #e0e3e7 (not container blue)"
else
    echo "[hb-btncenter] FAIL: inherit-bg button did not get UA grey — got [$b0]"; fail=1
fi
if printf '%s' "$b0" | grep -qF "bg#3366cc"; then
    echo "[hb-btncenter] FAIL: inherit-bg button leaked the container background #3366cc"; fail=1
fi

# ---- (2) vertically-centred label: pixel check on the rendered PNG ----------
echo "[hb-btncenter] compiling pixel backend ..."
if ! adder_bin x86_64-linux user/hambrowse_host_gfx.ad "$OUT/hambrowse_gfx" 2>"$OUT/gfxc.log"; then
    echo "[hb-btncenter] FAIL: pixel backend did not compile"; cat "$OUT/gfxc.log"; exit 1
fi
PPM="$OUT/btncenter.ppm"; PNG="$OUT/btncenter.png"
"$OUT/hambrowse_gfx" "$FIX" "$PPM" 900 >/dev/null 2>&1 || { echo "[hb-btncenter] FAIL: pixel render exited non-zero"; exit 1; }
python3 scripts/ppm_to_png.py "$PPM" "$PNG" >/dev/null 2>&1 || { echo "[hb-btncenter] FAIL: png conversion"; exit 1; }

cverdict=$(python3 - "$PNG" <<'PY'
import sys,zlib,struct
def readpng(fn):
    d=open(fn,'rb').read();i=8;W=H=0;idat=b''
    while i<len(d):
        ln=struct.unpack('>I',d[i:i+4])[0];typ=d[i+4:i+8];chunk=d[i+8:i+8+ln]
        if typ==b'IHDR':W,H=struct.unpack('>II',chunk[:8])
        elif typ==b'IDAT':idat+=chunk
        i+=12+ln
    raw=zlib.decompress(idat);stride=W*3;prev=bytes(stride);out=bytearray();pos=0
    for y in range(H):
        f=raw[pos];pos+=1;line=bytearray(raw[pos:pos+stride]);pos+=stride
        for x in range(stride):
            a=line[x-3] if x>=3 else 0;b=prev[x];c=prev[x-3] if x>=3 else 0
            if f==1:line[x]=(line[x]+a)&255
            elif f==2:line[x]=(line[x]+b)&255
            elif f==3:line[x]=(line[x]+((a+b)>>1))&255
            elif f==4:
                p=a+b-c;pa=abs(p-a);pb=abs(p-b);pc=abs(p-c)
                pr=a if(pa<=pb and pa<=pc) else(b if pb<=pc else c);line[x]=(line[x]+pr)&255
        prev=bytes(line);out+=line
    return W,H,out
W,H,px=readpng(sys.argv[1])
# The TALL button is the LOWER grey box on the white lower half. Find the widest
# contiguous grey-box row band (>=60 grey px) in the bottom 2/3 of the image, and
# the dark-ink rows within it.
def rowstats(y):
    grey=dark=0
    for x in range(W):
        p=(y*W+x)*3;r,g,b=px[p],px[p+1],px[p+2]
        if 205<=r<=235 and 205<=g<=235 and 210<=b<=240: grey+=1
        if r<100 and g<100 and b<100: dark+=1
    return grey,dark
boxrows=[];inkrows=[]
for y in range(H//3,H):
    grey,dark=rowstats(y)
    if grey>=60: boxrows.append(y)
    if dark>3: inkrows.append(y)
# restrict ink to inside the box band
if not boxrows or not inkrows:
    print("NOBOX"); sys.exit(0)
btop,bbot=boxrows[0],boxrows[-1]
ink=[y for y in inkrows if btop<=y<=bbot]
if not ink:
    print("NOINK"); sys.exit(0)
box_c=(btop+bbot)/2.0
ink_c=(ink[0]+ink[-1])/2.0
off=abs(ink_c-box_c)
box_h=bbot-btop
print(f"box {btop}..{bbot} (c={box_c:.1f} h={box_h}) ink {ink[0]}..{ink[-1]} (c={ink_c:.1f}) off={off:.1f}")
# The label centre must sit within ~1/6 of the box height of the box centre; a
# top-hugging label (the pre-fix bug) sits ~1/4 box-height above centre.
if box_h>=30 and off <= box_h/6.0:
    print("CENTERED")
PY
)
echo "[hb-btncenter] tall-button: $cverdict"
if printf '%s' "$cverdict" | grep -qF "CENTERED"; then
    echo "[hb-btncenter] PASS: tall submit-button label is vertically centred in its box"
else
    echo "[hb-btncenter] FAIL: tall submit-button label is NOT vertically centred — $cverdict"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "[hb-btncenter] RESULT: FAIL"; exit 1; fi
echo "[hb-btncenter] RESULT: PASS"
