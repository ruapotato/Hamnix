#!/usr/bin/env bash
# scripts/test_jsengine_ceiling_host.sh — FAST, QEMU-free gate proving the
# engine survives a large volume of console.log output + string allocation
# WITHOUT silently dropping output.
#
# Regression for the output/allocation ceiling: console.log accumulates into a
# fixed out_buf and every "a"+i concat permanently consumes the string pool, so
# after enough lines further output was silently truncated (the final line was
# cut mid-string and a trailing DONE marker never appeared) — with ZERO DOM
# calls. This drives 20000 concatenated log lines and asserts BOTH the final
# sentinel line AND the exact expected line count survive.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-ceil] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_ceil_compile.log"; then
    echo "[js-ceil] FAIL: host driver did not compile"; cat "$OUT/js_ceil_compile.log"; exit 1
fi

N=20000
js="$OUT/js_ceil.js"
cat > "$js" <<EOF
for (var i = 0; i < $N; i++) {
  console.log("line " + i + " padding padding padding padding");
}
console.log("DONE-MARKER-" + $N);
EOF

got="$OUT/js_ceil.out"
"$BIN" "$js" > "$got" 2>&1

fail=0
if ! grep -q "^DONE-MARKER-$N\$" "$got"; then
    echo "[js-ceil] FAIL: sentinel 'DONE-MARKER-$N' missing (output truncated)"
    echo "  last line seen: '$(tail -1 "$got")'"
    fail=1
else
    echo "[js-ceil] PASS sentinel present (no output truncation)"
fi

# N data lines + 1 sentinel line
want=$((N + 1))
lines=$(wc -l < "$got")
if [ "$lines" -ne "$want" ]; then
    echo "[js-ceil] FAIL: expected $want lines, got $lines"
    fail=1
else
    echo "[js-ceil] PASS line count = $want"
fi

if [ "$fail" -eq 0 ]; then
    echo "[js-ceil] RESULT: PASS"; exit 0
else
    echo "[js-ceil] RESULT: FAIL"; exit 1
fi
