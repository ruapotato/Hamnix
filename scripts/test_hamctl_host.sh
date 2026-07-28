#!/usr/bin/env bash
# scripts/test_hamctl_host.sh — FAST, QEMU-free host gate for the Control
# Center hub (lib/hamctlcore.ad drawn through lib/hamscene.ad + rasterized by
# lib/hamui_host.ad). Renders the three capplet pages (Appearance / Date &
# Time / About) to PNGs a human/agent can LOOK at, drives scripted pointer
# clicks (pick a wallpaper swatch, switch category, bump the UTC offset) and
# asserts the action codes + resulting state, AND confirms the NATIVE Hamnix
# build still compiles from the same core.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hamctl_host"
mkdir -p "$OUT"
fail=0

echo "[ctl-host] compiling core+harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/hamctl_host.ad "$BIN" 2>"$OUT/ctl_compile.log"; then
    echo "[ctl-host] FAIL: host harness did not compile"; cat "$OUT/ctl_compile.log"; exit 1
fi
echo "[ctl-host] PASS host harness compiled -> $BIN"

echo "[ctl-host] compiling NATIVE hamctl for x86_64-adder-user ..."
if ! adder_bin x86_64-adder-user user/hamctl.ad "$OUT/hamctl_native.elf" 2>"$OUT/ctl_native.log"; then
    echo "[ctl-host] FAIL: native hamctl did not compile"; cat "$OUT/ctl_native.log"; exit 1
fi
echo "[ctl-host] PASS native hamctl still compiles"

DUMP="$OUT/ctl_dump.txt"
if ! "$BIN" "$OUT/ctl_appear.ppm" "$OUT/ctl_dt.ppm" "$OUT/ctl_display.ppm" \
        "$OUT/ctl_mouse.ppm" "$OUT/ctl_kbd.ppm" "$OUT/ctl_sound.ppm" \
        "$OUT/ctl_power.ppm" "$OUT/ctl_net.ppm" "$OUT/ctl_about.ppm" >"$DUMP" 2>&1; then
    echo "[ctl-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi

for f in appear dt display mouse kbd sound power net about; do
    if python3 scripts/ppm_to_png.py "$OUT/ctl_$f.ppm" "$OUT/ctl_$f.png" 2>"$OUT/ctl_png.log"; then
        echo "[ctl-host] PASS rendered $OUT/ctl_$f.png"
    else
        echo "[ctl-host] FAIL png conversion ($f)"; cat "$OUT/ctl_png.log"; fail=1
    fi
done

assert_grep() {
    if grep -Eq -- "$1" "$DUMP"; then echo "[ctl-host] PASS $2";
    else echo "[ctl-host] FAIL $2 (missing: $1)"; fail=1; fi
}

# --- Appearance page ---
assert_grep '^glyphs 10 8 \"Control Center\"'      "hub title bar"
assert_grep '^glyphs 152 40 \"Desktop Wallpaper\"' "Appearance page heading"
assert_grep '^ACT_SWATCH 2'                         "swatch click returns ACT_WALL(2)"
assert_grep '^SEL_SWATCH 3'                         "picked swatch index 3"
# Default wallpaper option: the DE's out-of-box indigo-slate gradient is now a
# labelled, selectable picker entry (image index 0) that routes to the same
# wallpaper sink — so a user who picked Sunset/Ocean/Tiles/a colour can get back.
assert_grep '^glyphs .*\"Default\"'                 "Default wallpaper option labelled in picker"
assert_grep '^ACT_WALLIMG 7'                        "Default thumbnail click returns ACT_WALLIMG(7)"
assert_grep '^SEL_IMAGE 0'                           "Default is image index 0 (routes to wallpaper sink)"
assert_grep '^SEL_KIND 1'                            "Default selection latched as an image wallpaper"
# --- Date & Time page ---
assert_grep '^ACT_CAT_DT 1'                         "sidebar switched to Date & Time (ACT_CAT)"
assert_grep '^glyphs .*\"Date & Time\"'             "Date & Time heading"
assert_grep 'Sun Jul 12  14:30'                     "current date/time rendered"
assert_grep '^ACT_TZ 3'                             "UTC +/- returns ACT_TZ(3)"
assert_grep '^TZ_OFF 2'                             "two + clicks -> UTC+2"
# --- Display page (framebuffer read-out + UI-scale stepper) ---
assert_grep '^ACT_CAT_DISP 1'                       "sidebar switched to Display (ACT_CAT)"
assert_grep '^glyphs .*\"Display\"'                 "Display heading"
assert_grep '^glyphs .*\"1024x768\"'                "resolution read-out rendered"
assert_grep '^glyphs .*\"32-bit\"'                  "colour depth read-out rendered"
assert_grep '^glyphs .*\"4096 B/row\"'              "stride read-out rendered"
assert_grep '^ACT_DISP 4'                           "scale stepper returns ACT_DISPLAY(4)"
assert_grep '^DISP_SCALE 2'                         "UI scale bumped 1x -> 2x"
assert_grep '^glyphs .*\"2x\"'                      "scale value rendered after bump"
# --- Mouse page (speed + primary button + scroll direction) ---
assert_grep '^ACT_CAT_MOUSE 1'                      "sidebar switched to Mouse (ACT_CAT)"
assert_grep '^glyphs .*\"Pointer speed:\"'          "Mouse pointer-speed row"
assert_grep '^ACT_MOUSE 5'                          "mouse control returns ACT_MOUSE(5)"
assert_grep '^MS_SPEED 6'                           "pointer speed bumped 5 -> 6"
assert_grep '^MS_PRIMARY 1'                         "primary button set to Right"
assert_grep '^MS_NATURAL 1'                         "scroll set to Natural"
assert_grep '^glyphs .*\"Natural\"'                 "Natural toggle rendered"
# --- Keyboard page (repeat delay/rate + layout read-out) ---
assert_grep '^ACT_CAT_KBD 1'                        "sidebar switched to Keyboard (ACT_CAT)"
assert_grep '^glyphs .*\"Repeat delay:\"'           "Keyboard repeat-delay row"
assert_grep '^ACT_KBD 6'                            "kbd control returns ACT_KBD(6)"
assert_grep '^KB_DELAY 550'                         "repeat delay bumped 500 -> 550ms"
assert_grep '^KB_RATE 22'                           "repeat rate bumped 20 -> 22/s"
assert_grep '^glyphs .*\"us\"'                      "keyboard layout read-out rendered"
# --- Sound page (honest no-device read-out + volume/mute WIP prefs) ---
assert_grep '^ACT_CAT_SOUND 1'                      "sidebar switched to Sound (ACT_CAT)"
assert_grep '^glyphs .*\"Sound\"'                   "Sound heading"
assert_grep '^glyphs .*\"No audio device\"'         "honest no-audio-device read-out"
assert_grep '^glyphs .*\"Volume:\"'                 "Sound volume row"
assert_grep '^ACT_SOUND 8'                          "sound control returns ACT_SOUND(8)"
assert_grep '^SND_VOL 80'                            "volume bumped 70 -> 80"
assert_grep '^SND_MUTE 1'                            "mute toggled off -> on"
# --- Power & Session page (real actions + uptime/power read-out) ---
assert_grep '^ACT_CAT_POWER 1'                      "sidebar switched to Power (ACT_CAT)"
assert_grep '^glyphs .*\"Power & Session\"'         "Power heading"
assert_grep '^glyphs .*\"0:12:34\"'                 "uptime read-out rendered"
assert_grep '^glyphs .*\"AC \(no battery\)\"'       "honest AC/no-battery power source"
assert_grep '^glyphs .*\"Lock Screen\"'             "Lock Screen action button rendered"
assert_grep '^glyphs .*\"Reboot\"'                  "Reboot action button rendered"
assert_grep '^ACT_LOCK 9'                           "Lock Screen returns ACT_LOCK(9)"
assert_grep '^ACT_REBOOT 12'                        "Reboot returns ACT_REBOOT(12)"
# --- Network page (SYS_NETCFG read-out + real SET_DNS sink) ---
assert_grep '^ACT_CAT_NET 1'                        "sidebar switched to Network (ACT_CAT)"
assert_grep '^glyphs .*\"Network\"'                 "Network heading"
assert_grep '^glyphs .*\"192.168.1.50\"'            "IP address read-out rendered"
assert_grep '^glyphs .*\"255.255.255.0\"'           "netmask read-out rendered"
assert_grep '^glyphs .*\"dhcp\"'                    "config source (dhcp) rendered"
assert_grep '^glyphs .*\"8.8.8.8\"'                 "DNS preset button rendered"
assert_grep '^ACT_NET 13'                           "DNS preset returns ACT_NET(13)"
assert_grep '^NET_DNS_PREF 1'                       "Google DNS preset latched (pref 1)"
# --- About page ---
assert_grep '^ACT_CAT_ABOUT 1'                      "sidebar switched to About"
assert_grep '^ABOUT_N 7'                            "seven About facts populated"
assert_grep '^glyphs .*\"About This System\"'       "About heading"
assert_grep 'glyphs .*\"hamnix\"'                   "hostname value rendered"
assert_grep 'glyphs .*\"2048 MB\"'                  "memory value rendered"
# --- rasterizer sanity ---
# Modern cohesive headerbar: a cool-blue vertical gradient (was a flat
# #3584e4). Scanline 4 of the azure gradient rasterizes to #618ac5.
assert_grep '^PIX 4 4 #618ac5'                      "raster headerbar pixel = cool-blue gradient"
# Selected sidebar category = MATE selection-blue row (#3584e4), matching the
# context-menu / applet-chooser highlight instead of a barely-darker sunk button.
assert_grep '^PIX 120 55 #3584e4'                   "selected sidebar row = MATE blue"

if [ "$fail" -ne 0 ]; then echo "[ctl-host] OVERALL FAIL"; exit 1; fi
echo "[ctl-host] OVERALL PASS"
