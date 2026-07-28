#!/usr/bin/env bash
# scripts/test_hamsdl_jpeg_host.sh — FAST, QEMU-free host gate for the hamSDL/
# hamGame IMAGE LOADER's JPEG path — the last common pygame.image.load format
# after BMP + PNG. It wires lib/jpeg.ad (a pure-Adder, integer-only BASELINE
# JPEG decoder: SOF0/SOF1 Huffman, 8x8 integer IDCT, 4:4:4/4:2:2/4:2:0 chroma,
# YCbCr->RGB) through hamGame's game_load_jpeg / game_load_image (FF D8 FF
# sniff) and the host file loader game_host_load_image (pygame.image.load path
# form).
#
# The gate GENERATES a tiny BASELINE JPEG fixture with a SELF-CONTAINED,
# pure-stdlib (no PIL/numpy) baseline JPEG ENCODER — a 16x16 two-region image
# (left half teal, right half orange) — loads it off disk through the exact
# format-sniff dispatch, blits it onto a red display Surface, rasterizes to a
# PPM/PNG a human/agent can LOOK at, and asserts sampled pixels are within a
# per-channel TOLERANCE of the source (JPEG is lossy) — both straight off the
# decoded Surface AND after the raster. The two colour regions also nail spatial
# position (left != right), so a transposed/garbage decode fails. It also
# recompiles the NATIVE x86_64-adder-user build so the dual-target seam can't
# rot. All in milliseconds, no QEMU.
#
# Built with the frozen Python seed compiler. PNG conversion uses
# scripts/ppm_to_png.py (Python stdlib zlib only).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamsdl_jpeg_host"
FIX="$OUT/hamsdl_fix.jpg"
PPM="$OUT/hamsdl_jpeg.ppm"
PNG="$OUT/hamsdl_jpeg.png"
DUMP="$OUT/hamsdl_jpeg_dump.txt"
TOL=8                                    # per-channel lossy-decode tolerance
mkdir -p "$OUT"
fail=0

# ---- 1. Generate the baseline JPEG fixture (pure Python stdlib) ----------
python3 - "$FIX" <<'PY'
# Self-contained BASELINE (SOF0, Huffman, 4:4:4) JPEG encoder — no PIL/numpy.
# Emits a standard JFIF baseline JPEG that any conformant decoder reads; used
# only to feed lib/jpeg.ad a real DCT/Huffman/YCbCr stream (not a shortcut).
import sys, math, struct
ZIG=[0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,
7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,
46,53,60,61,54,47,55,62,63]
QY=[16,11,10,16,24,40,51,61,12,12,14,19,26,58,60,55,14,13,16,24,40,57,69,56,14,
17,22,29,51,87,80,62,18,22,37,56,68,109,103,77,24,35,55,64,81,104,113,92,49,64,
78,87,103,121,120,101,72,92,95,98,112,100,103,99]
QC=[17,18,24,47,99,99,99,99,18,21,26,66,99,99,99,99,24,26,56,99,99,99,99,99,47,
66,99,99,99,99,99,99]+[99]*32
DC_L_BITS=[0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0]; DC_L_VAL=list(range(12))
DC_C_BITS=[0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0]; DC_C_VAL=list(range(12))
AC_L_BITS=[0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d]
AC_L_VAL=[0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,
0x61,0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,
0xd1,0xf0,0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,0x17,0x18,0x19,0x1a,0x25,0x26,
0x27,0x28,0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,
0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,
0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x83,0x84,0x85,0x86,0x87,
0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,
0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,
0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,
0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,
0xf7,0xf8,0xf9,0xfa]
AC_C_BITS=[0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,0x77]
AC_C_VAL=[0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,
0x61,0x71,0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91,0xa1,0xb1,0xc1,0x09,0x23,0x33,
0x52,0xf0,0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34,0xe1,0x25,0xf1,0x17,0x18,0x19,
0x1a,0x26,0x27,0x28,0x29,0x2a,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,
0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,
0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x82,0x83,0x84,0x85,
0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,
0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,
0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,
0xd9,0xda,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf2,0xf3,0xf4,0xf5,0xf6,
0xf7,0xf8,0xf9,0xfa]
def huff(bits,vals):
    c={}; code=0; k=0
    for l in range(1,17):
        for _ in range(bits[l-1]): c[vals[k]]=(code,l); code+=1; k+=1
        code<<=1
    return c
DCL=huff(DC_L_BITS,DC_L_VAL); ACL=huff(AC_L_BITS,AC_L_VAL)
DCC=huff(DC_C_BITS,DC_C_VAL); ACC=huff(AC_C_BITS,AC_C_VAL)
COS=[[math.cos((2*x+1)*u*math.pi/16) for x in range(8)] for u in range(8)]
def Cf(u): return (1/math.sqrt(2)) if u==0 else 1.0
def fdct(b):
    o=[0.0]*64
    for v in range(8):
        for u in range(8):
            s=0.0
            for y in range(8):
                for x in range(8): s+=b[y*8+x]*COS[u][x]*COS[v][y]
            o[v*8+u]=0.25*Cf(u)*Cf(v)*s
    return o
class BW:
    def __init__(s): s.b=bytearray(); s.acc=0; s.n=0
    def put(s,code,length):
        for i in range(length-1,-1,-1):
            s.acc=(s.acc<<1)|((code>>i)&1); s.n+=1
            if s.n==8:
                s.b.append(s.acc)
                if s.acc==0xFF: s.b.append(0)
                s.acc=0; s.n=0
    def flush(s):
        if s.n>0:
            s.acc=(s.acc<<(8-s.n))|((1<<(8-s.n))-1); s.b.append(s.acc)
            if s.acc==0xFF: s.b.append(0)
            s.acc=0; s.n=0
def mag(v):
    a=abs(v); s=0
    while a: s+=1; a>>=1
    return s
def blk(bw,block,q,dct,act,pred):
    d=fdct(block); qz=[int(round(d[i]/q[i])) for i in range(64)]
    diff=qz[0]-pred; s=mag(diff); code,length=dct[s]; bw.put(code,length)
    if s>0:
        val=diff if diff>=0 else diff-1+(1<<s); bw.put(val&((1<<s)-1),s)
    run=0
    for k in range(1,64):
        c=qz[ZIG[k]]
        if c==0: run+=1
        else:
            while run>15: cc,ll=act[0xF0]; bw.put(cc,ll); run-=16
            s=mag(c); cc,ll=act[(run<<4)|s]; bw.put(cc,ll)
            val=c if c>=0 else c-1+(1<<s); bw.put(val&((1<<s)-1),s); run=0
    if run>0: cc,ll=act[0x00]; bw.put(cc,ll)
    return qz[0]
def emit(W,H,rgb):
    out=bytearray()
    def seg(m,p):
        out.extend(b'\xff'+bytes([m])); out.extend(struct.pack('>H',len(p)+2)); out.extend(p)
    out.extend(b'\xff\xd8')
    seg(0xE0,b'JFIF\x00'+bytes([1,1,0])+struct.pack('>HH',1,1)+bytes([0,0]))
    seg(0xDB,bytes([0x00])+bytes(QY[ZIG[i]] for i in range(64)))
    seg(0xDB,bytes([0x01])+bytes(QC[ZIG[i]] for i in range(64)))
    seg(0xC0,bytes([8])+struct.pack('>HH',H,W)+bytes([3,1,0x11,0,2,0x11,1,3,0x11,1]))
    seg(0xC4,bytes([0x00])+bytes(DC_L_BITS)+bytes(DC_L_VAL))
    seg(0xC4,bytes([0x10])+bytes(AC_L_BITS)+bytes(AC_L_VAL))
    seg(0xC4,bytes([0x01])+bytes(DC_C_BITS)+bytes(DC_C_VAL))
    seg(0xC4,bytes([0x11])+bytes(AC_C_BITS)+bytes(AC_C_VAL))
    seg(0xDA,bytes([3,1,0x00,2,0x11,3,0x11,0,63,0]))
    bw=BW(); pY=pCb=pCr=0
    for my in range(0,H,8):
        for mx in range(0,W,8):
            Yb=[0]*64; Cb=[0]*64; Cr=[0]*64
            for yy in range(8):
                for xx in range(8):
                    r,g,b=rgb(mx+xx,my+yy)
                    Yb[yy*8+xx]=0.299*r+0.587*g+0.114*b-128
                    Cb[yy*8+xx]=128-0.168736*r-0.331264*g+0.5*b-128
                    Cr[yy*8+xx]=128+0.5*r-0.418688*g-0.081312*b-128
            pY=blk(bw,Yb,QY,DCL,ACL,pY)
            pCb=blk(bw,Cb,QC,DCC,ACC,pCb)
            pCr=blk(bw,Cr,QC,DCC,ACC,pCr)
    bw.flush(); out.extend(bw.b); out.extend(b'\xff\xd9')
    return bytes(out)
def px(x,y):
    return (0,160,160) if x<8 else (230,120,20)
data=emit(16,16,px)
open(sys.argv[1],'wb').write(data)
print("[jpeg-host] generated %d-byte baseline JPEG fixture (16x16 4:4:4)"%len(data))
PY
if [ ! -s "$FIX" ]; then
    echo "[jpeg-host] FAIL: could not generate JPEG fixture"; exit 1
fi
# Sanity: the fixture must actually be a JPEG (FF D8 FF prefix).
if [ "$(od -An -tx1 -N3 "$FIX" | tr -d ' ')" != "ffd8ff" ]; then
    echo "[jpeg-host] FAIL: fixture is not a JPEG (bad SOI/marker prefix)"; exit 1
fi

# ---- 2. Compile the host harness -----------------------------------------
echo "[jpeg-host] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamsdl_jpeg_host.ad "$BIN" 2>"$OUT/hamsdl_jpeg_compile.log"; then
    echo "[jpeg-host] FAIL: host harness did not compile"; cat "$OUT/hamsdl_jpeg_compile.log"; exit 1
fi
echo "[jpeg-host] PASS host harness compiled -> $BIN"

# ---- 3. Native dual-target compile (lib/jpeg.ad + hamgame on device) -----
echo "[jpeg-host] compiling NATIVE hamgamedemo (exercises lib/jpeg + hamgame) ..."
if ! adder_bin x86_64-adder-user user/hamgamedemo.ad "$OUT/hamgamedemo_jpeg_native.elf" 2>"$OUT/hamsdl_jpeg_native.log"; then
    echo "[jpeg-host] FAIL: native build did not compile"; cat "$OUT/hamsdl_jpeg_native.log"; exit 1
fi
echo "[jpeg-host] PASS native build still compiles (device dual-target intact)"

# ---- 4. Run the harness --------------------------------------------------
echo "[jpeg-host] running JPEG-load harness ..."
if ! "$BIN" "$FIX" "$PPM" >"$DUMP" 2>&1; then
    echo "[jpeg-host] FAIL: harness exited non-zero"; cat "$DUMP"; exit 1
fi

if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/hamsdl_jpeg_png.log"; then
    echo "[jpeg-host] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[jpeg-host] FAIL png conversion"; cat "$OUT/hamsdl_jpeg_png.log"; fail=1
fi

kv() { awk -v k="$1" '$1==k{print $2}' "$DUMP"; }

assert_eq() {
    local key="$1" want="$2" msg="$3" got
    got="$(kv "$key")"
    if [ "$got" = "$want" ]; then
        echo "[jpeg-host] PASS $msg ($key=$got)"
    else
        echo "[jpeg-host] FAIL $msg ($key: want $want, got '$got')"; fail=1
    fi
}

# Assert an "R G B" triple is within +/-TOL of the wanted triple (lossy JPEG).
assert_tol() {
    local key="$1" wr="$2" wg="$3" wb="$4" msg="$5"
    local line r g b
    line="$(awk -v k="$key" '$1==k{print $2, $3, $4}' "$DUMP")"
    r="$(echo "$line" | awk '{print $1}')"
    g="$(echo "$line" | awk '{print $2}')"
    b="$(echo "$line" | awk '{print $3}')"
    if [ -z "$r" ] || [ -z "$g" ] || [ -z "$b" ]; then
        echo "[jpeg-host] FAIL $msg ($key: no pixel dumped)"; fail=1; return
    fi
    local dr=$(( r - wr )); local dg=$(( g - wg )); local db=$(( b - wb ))
    dr=${dr#-}; dg=${dg#-}; db=${db#-}
    if [ "$dr" -le "$TOL" ] && [ "$dg" -le "$TOL" ] && [ "$db" -le "$TOL" ]; then
        echo "[jpeg-host] PASS $msg ($key=$r $g $b ~ $wr $wg $wb, tol $TOL)"
    else
        echo "[jpeg-host] FAIL $msg ($key=$r $g $b, want ~$wr $wg $wb +/-$TOL)"; fail=1
    fi
}

# --- Format sniff + decode into a Surface ---------------------------------
assert_eq SJ  0  "baseline JPEG sniffed (FF D8 FF) + decoded into a Surface"
assert_eq SJW 16 "JPEG width decoded"
assert_eq SJH 16 "JPEG height decoded"

# --- Colour correctness straight off the decoded Surface (lossy tolerance) -
assert_tol SJ_L  0   160 160 "JPEG left-region teal decoded (Surface)"
assert_tol SJ_L2 0   160 160 "JPEG left-region teal decoded, 2nd sample"
assert_tol SJ_R  230 120 20  "JPEG right-region orange decoded (Surface)"
assert_tol SJ_R2 230 120 20  "JPEG right-region orange decoded, 2nd sample"

# --- Rasterized framebuffer: blit -> present -> PNG colour-correct ----------
assert_eq PRIMS 1 "frame rasterized one image primitive"
assert_tol FB_BG 255 0   0   "background stays red where unblitted"
assert_tol FB_L  0   160 160 "JPEG left-region teal blitted into the raster"
assert_tol FB_R  230 120 20  "JPEG right-region orange blitted into the raster"

# --- Spatial sanity: the two regions must be DISTINCT (not a flat/garbage decode)
LR="$(awk '$1=="SJ_L"{print $2}' "$DUMP")"; RR="$(awk '$1=="SJ_R"{print $2}' "$DUMP")"
if [ -n "$LR" ] && [ -n "$RR" ] && [ "$(( RR - LR ))" -ge 100 ]; then
    echo "[jpeg-host] PASS left/right regions are spatially distinct (R $LR vs $RR)"
else
    echo "[jpeg-host] FAIL regions not distinct — decode may be flat/garbage (R $LR vs $RR)"; fail=1
fi

# --- Non-blank PNG (a healthy count of non-background pixels) ---------------
if python3 - "$PPM" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
assert d[:2]==b'P6'
i=2; vals=[]
while len(vals)<3:
    while i<len(d) and d[i] in b' \t\n\r': i+=1
    if d[i:i+1]==b'#':
        while i<len(d) and d[i] not in b'\n': i+=1
        continue
    s=i
    while i<len(d) and d[i] not in b' \t\n\r': i+=1
    vals.append(int(d[s:i]))
w,h,mx=vals; i+=1; px=d[i:]
bg=(0xff,0x00,0x00); n=0
for k in range(0,len(px)-2,3):
    if abs(px[k]-bg[0])>12 or abs(px[k+1]-bg[1])>12 or abs(px[k+2]-bg[2])>12: n+=1
print("NON-BG-PIXELS",n)
sys.exit(0 if n>=200 else 1)   # a 16x16 sprite = 256 px over the red backdrop
PY
then
    echo "[jpeg-host] PASS frame is non-blank (the JPEG sprite is present in the raster)"
else
    echo "[jpeg-host] FAIL frame looks blank"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[jpeg-host] RESULT: PASS"
    exit 0
else
    echo "[jpeg-host] RESULT: FAIL"
    exit 1
fi
