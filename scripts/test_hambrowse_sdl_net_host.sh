#!/usr/bin/env bash
# scripts/test_hambrowse_sdl_net_host.sh — QEMU-free host gate for the
# INTERACTIVE hambrowse window fetching a LIVE https:// page over the Plan-9
# /net stack (user/hambrowse_sdl_host.ad -> UNCHANGED user/http9.ad/net9.ad,
# linked against the host /net shim scripts/net9_host_shim.c: real sockets +
# OpenSSL TLS). Companion to scripts/test_net9_host.sh (which proves the raw
# transport); this one proves the full UI path: typing an https URL + Enter
# LOADS and RENDERS the fetched page in the real engine.
#
# It:
#   1. Compiles the engine (x86_64-linux, --emit-asm) and gcc-links it against
#      the /net shim + OpenSSL.
#   2. Compiles the SDL2 bridge.
#   3. Device parity: user/hambrowse.ad still compiles+links for
#      x86_64-adder-user (the on-device browser using http9/net9 must not
#      regress; the shim is host-only).
#   4. Runs the bridge HEADLESS (SDL dummy driver), replaying: focus the URL
#      bar, clear it, type https://example.com/ + Enter, scroll — then asserts
#      the child exited 0 and the rendered CONTENT CHANGED to the fetched page.
#
# The live-fetch assertion SKIPs (non-fatal) if the host has no network; the
# build + device-parity gates always run.
#
# Pass marker: [test_hambrowse_sdl_net] PASS

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
CHILD="$OUT/hambrowse_sdl_net"
BRIDGE="$OUT/hambrowse_sdl_bridge"
ASM="$OUT/hambrowse_sdl_net.s"
SHIM_O="$OUT/net9_host_shim.o"
LIBSDL="/usr/lib/x86_64-linux-gnu/libSDL2-2.0.so.0"
FRAMES="$OUT/hambrowse_sdl_net_frames"
SCRIPT="$OUT/hambrowse_sdl_net_events.txt"
mkdir -p "$OUT" "$FRAMES"
rm -f "$FRAMES"/frame*.ppm
fail=0

echo "[test_hambrowse_sdl_net] (1/4) compiling engine (x86_64-linux, emit-asm) ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux --emit-asm \
        user/hambrowse_sdl_host.ad -o "$OUT/hambrowse_sdl_net_fs.elf" \
        >"$OUT/hambrowse_sdl_net_compile.log" 2>&1; then
    echo "[test_hambrowse_sdl_net] FAIL: engine did not compile"
    cat "$OUT/hambrowse_sdl_net_compile.log"; exit 1
fi
mv -f user/hambrowse_sdl_host.s "$ASM"
if ! gcc -O2 -c scripts/net9_host_shim.c -o "$SHIM_O" 2>"$OUT/net9_host_shim_compile.log"; then
    echo "[test_hambrowse_sdl_net] FAIL: shim did not compile"
    cat "$OUT/net9_host_shim_compile.log"; exit 1
fi
if ! gcc -no-pie -O2 "$ASM" "$SHIM_O" -lssl -lcrypto -o "$CHILD" \
        2>"$OUT/hambrowse_sdl_net_link.log"; then
    echo "[test_hambrowse_sdl_net] FAIL: engine link failed"
    cat "$OUT/hambrowse_sdl_net_link.log"; exit 1
fi
echo "[test_hambrowse_sdl_net] PASS engine linked with /net shim -> $CHILD"

echo "[test_hambrowse_sdl_net] (2/4) compiling SDL2 bridge ..."
if [ ! -e "$LIBSDL" ]; then
    echo "[test_hambrowse_sdl_net] FAIL: $LIBSDL absent (install libsdl2-2.0-0)"; exit 1
fi
if ! gcc -O2 scripts/hambrowse_sdl_bridge.c -o "$BRIDGE" "$LIBSDL" \
        2>"$OUT/hambrowse_sdl_bridge_compile.log"; then
    echo "[test_hambrowse_sdl_net] FAIL: bridge did not compile"
    cat "$OUT/hambrowse_sdl_bridge_compile.log"; exit 1
fi
echo "[test_hambrowse_sdl_net] PASS bridge compiled -> $BRIDGE"

echo "[test_hambrowse_sdl_net] (3/4) device parity: user/hambrowse.ad for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hambrowse.ad -o "$OUT/hambrowse_device.elf" \
        >"$OUT/hambrowse_device.log" 2>&1; then
    echo "[test_hambrowse_sdl_net] FAIL: device hambrowse regressed"
    cat "$OUT/hambrowse_device.log"; fail=1
else
    echo "[test_hambrowse_sdl_net] PASS device hambrowse still compiles (dual-target intact)"
fi

# ---- (4) headless live-fetch navigation ------------------------------------
# RE-PROBED 2026-07-27: (200,28) predated the Chrome-shaped window chrome (a
# 34px TAB STRIP above a 44px TOOLBAR, lib/web/state.ad), so the click landed
# on the tab strip and the omnibox never took focus — every keystroke below
# went nowhere and the page never navigated. The toolbar spans y=34..78.
cat > "$SCRIPT" <<'EVENTS'
click 300 56
ctrlkey 97
key 8
text https://example.com/
key 13
wheel -2
quit
EVENTS

have_net=0
if getent hosts example.com >/dev/null 2>&1; then have_net=1; fi

echo "[test_hambrowse_sdl_net] (4/4) headless live https navigation ..."
if [ "$have_net" -eq 0 ]; then
    echo "[test_hambrowse_sdl_net] SKIP live nav: host has no network (build + parity still gated)"
else
    if ! SDL_VIDEODRIVER=dummy timeout 60 "$BRIDGE" "$CHILD" \
            "tests/fixtures/hambrowse_sdl_home.html" \
            --test "$SCRIPT" "$FRAMES" >"$OUT/hambrowse_sdl_net_run.log" 2>&1; then
        echo "[test_hambrowse_sdl_net] FAIL: bridge/child exited non-zero"
        cat "$OUT/hambrowse_sdl_net_run.log"; fail=1
    else
        cat "$OUT/hambrowse_sdl_net_run.log"
        python3 - "$FRAMES" <<'PY'
import sys,glob,os,hashlib
d=sys.argv[1]
paths=sorted(glob.glob(os.path.join(d,"frame*.ppm")))
if len(paths)<6:
    print("[test_hambrowse_sdl_net] FAIL: too few frames (%d)"%len(paths)); sys.exit(1)
def load(p):
    with open(p,"rb") as f:
        assert f.readline().strip()==b"P6"
        w,h=map(int,f.readline().split()); f.readline()
        return w,h,f.read(w*h*3)
# content region = below the chrome. RE-PINNED 2026-07-27 from y>=40 to the
# real CONTENT_Y (78): the old cut still included the omnibox, so the typed
# URL's keystrokes registered as "content" changes.
def sig(w,h,b): return hashlib.sha1(b[78*w*3:]).hexdigest()
frames=[load(p) for p in paths]
sigs=[sig(*fr) for fr in frames]
home=sigs[0]; distinct=set(sigs)
print("[test_hambrowse_sdl_net] frames=%d distinct_content=%d"%(len(frames),len(distinct)))
ok=True
if len(distinct)<2:
    print("[test_hambrowse_sdl_net] FAIL: content never changed (live page not rendered)"); ok=False
else:
    print("[test_hambrowse_sdl_net] PASS content changed across %d distinct pages"%len(distinct))
if any(s!=home for s in sigs[5:]):
    print("[test_hambrowse_sdl_net] PASS typed https URL loaded + rendered a new page")
else:
    print("[test_hambrowse_sdl_net] FAIL: typed https URL did not change the page"); ok=False
sys.exit(0 if ok else 1)
PY
        [ $? -ne 0 ] && fail=1
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_hambrowse_sdl_net] PASS"
else
    echo "[test_hambrowse_sdl_net] FAIL"
fi
exit $fail
