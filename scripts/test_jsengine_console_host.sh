#!/usr/bin/env bash
# scripts/test_jsengine_console_host.sh — FAST, QEMU-free regression gate proving
# that LARGE console.log output survives INTACT on BOTH host console paths:
#
#   * user/js_host.ad        — the raw JS engine (lib/web/js): writes out_buf
#                              (4 MiB) straight to stdout.
#   * user/hambrowse_host.ad — the browser harness (lib/htmlengine + lib/web/dom):
#                              captures the engine's console into js_con_buf and
#                              re-emits it as `JSLOG` lines through obuf.
#
# It guards two truncation bugs that USED to cap console output at ~a few hundred
# bytes and forced every test_jsengine_*host.sh / test_hambrowse_*host.sh gate to
# split its assertions into many tiny fixtures:
#   1. hambrowse_host `obuf: Array[256]` was flushed only at loop-end, so it
#      silently dropped every byte past 255 (the "few hundred bytes" wall).
#   2. `_js_capture_console` / `js_con_buf` capped the engine->html copy at 8191.
# Both are now streaming / generous; this gate asserts the LAST line of a large
# multi-line log AND a large single string survive on each path.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"; mkdir -p "$OUT"
JS_BIN="$OUT/js_host"; HB_BIN="$OUT/hambrowse_host"
fail=0

echo "[js-con] compiling js_host (raw engine) for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$JS_BIN" 2>"$OUT/con_js_compile.log"; then
    echo "[js-con] FAIL: js_host did not compile"; cat "$OUT/con_js_compile.log"; exit 1
fi
echo "[js-con] PASS js_host compiled -> $JS_BIN"

echo "[js-con] compiling hambrowse_host (browser harness) for x86_64-linux ..."
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$HB_BIN" 2>"$OUT/con_hb_compile.log"; then
    echo "[js-con] FAIL: hambrowse_host did not compile"; cat "$OUT/con_hb_compile.log"; exit 1
fi
echo "[js-con] PASS hambrowse_host compiled -> $HB_BIN"

# ---- fixtures: 800 log lines + one long single string ------------------------
N=800
JSF="$OUT/con_big.js"; HTF="$OUT/con_big.html"
python3 - "$N" "$JSF" "$HTF" <<'PY'
import sys
n = int(sys.argv[1]); jsf, htf = sys.argv[2], sys.argv[3]
body = ";".join('console.log("LINE-%05d-abcdefghijklmnopqrstuvwxyz")' % i for i in range(n))
# a long single string too (well past the old ~256/8191 caps but under sp_buf)
body += ';var s="";for(var k=0;k<2000;k++){s+="Z";}console.log("BIGSTR:"+s.length)'
open(jsf, "w").write(body + "\n")
open(htf, "w").write("<html><body><script>" + body + "</script></body></html>\n")
PY

# ---- path 1: raw engine (js_host) -------------------------------------------
JD="$OUT/con_js.out"
"$JS_BIN" "$JSF" >"$JD" 2>&1 || { echo "[js-con] FAIL: js_host exited non-zero"; cat "$JD"; exit 1; }
got_lines=$(grep -c '^LINE-' "$JD")
if [ "$got_lines" -eq "$N" ]; then echo "[js-con] PASS js_host emitted all $N lines"; else
    echo "[js-con] FAIL js_host emitted $got_lines/$N lines (truncated)"; fail=1; fi
if grep -q '^LINE-00000-abcdefghijklmnopqrstuvwxyz$' "$JD"; then echo "[js-con] PASS js_host first line intact"; else
    echo "[js-con] FAIL js_host first line missing"; fail=1; fi
if grep -q "^LINE-0079[0-9]-abcdefghijklmnopqrstuvwxyz$" "$JD" && \
   grep -q '^LINE-00799-abcdefghijklmnopqrstuvwxyz$' "$JD"; then echo "[js-con] PASS js_host LAST line intact"; else
    echo "[js-con] FAIL js_host last line (LINE-00799) truncated"; fail=1; fi
if grep -q '^BIGSTR:2000$' "$JD"; then echo "[js-con] PASS js_host long single string survived"; else
    echo "[js-con] FAIL js_host long single string truncated"; fail=1; fi

# ---- path 2: browser harness (hambrowse_host) -------------------------------
HD="$OUT/con_hb.out"
"$HB_BIN" "$HTF" 880 >"$HD" 2>&1 || { echo "[js-con] FAIL: hambrowse_host exited non-zero"; cat "$HD"; exit 1; }
hb_lines=$(grep -c '^JSLOG LINE-' "$HD")
if [ "$hb_lines" -eq "$N" ]; then echo "[js-con] PASS hambrowse emitted all $N JSLOG lines"; else
    echo "[js-con] FAIL hambrowse emitted $hb_lines/$N JSLOG lines (truncated)"; fail=1; fi
if grep -q '^JSLOG LINE-00000-abcdefghijklmnopqrstuvwxyz$' "$HD"; then echo "[js-con] PASS hambrowse first JSLOG intact"; else
    echo "[js-con] FAIL hambrowse first JSLOG missing"; fail=1; fi
if grep -q '^JSLOG LINE-00799-abcdefghijklmnopqrstuvwxyz$' "$HD"; then echo "[js-con] PASS hambrowse LAST JSLOG intact"; else
    echo "[js-con] FAIL hambrowse last JSLOG (LINE-00799) truncated"; fail=1; fi
if grep -q '^JSLOG BIGSTR:2000$' "$HD"; then echo "[js-con] PASS hambrowse long single string survived"; else
    echo "[js-con] FAIL hambrowse long single string truncated"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "[js-con] RESULT: FAIL"; exit 1; fi
echo "[js-con] RESULT: PASS"
