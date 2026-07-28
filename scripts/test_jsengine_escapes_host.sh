#!/usr/bin/env bash
# scripts/test_jsengine_escapes_host.sh — FAST, QEMU-free gate for the JS
# SOURCE string-literal escape tokenizer in lib/jsengine.ad (lex_string /
# lex_tmpl_chunk).
#
# Regression guard for the escape decoder: `\b`/`\f`/`\v` used to emit the
# LETTER (b/f/v) instead of the control byte, and `\xHH`/`\uHHHH` were not
# decoded at all (emitted the literal chars). This asserts the exact
# charCodeAt() of each decoded escape — a value that cannot be faked by a
# console leak — for BOTH single/double-quoted literals AND template literals,
# plus a JSON.stringify round-trip. Runs via the x86_64-linux host driver in
# milliseconds; no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-esc] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_esc_compile.log"; then
    echo "[js-esc] FAIL: host driver did not compile"; cat "$OUT/js_esc_compile.log"; exit 1
fi
echo "[js-esc] PASS host driver compiled -> $BIN"

FIX="$OUT/js_escapes.js"
# NOTE: heredoc is quoted so backslashes reach the JS engine verbatim.
cat > "$FIX" <<'EOF'
var ok = 0, fail = 0;
function eq(tag, got, want) {
  if (got === want) { ok = ok + 1; }
  else { fail = fail + 1; console.log("MISMATCH " + tag + " got=" + got + " want=" + want); }
}
// control-byte escapes (double quotes)
eq("dq_b", "a\bc".charCodeAt(1), 8);
eq("dq_f", "x\fy".charCodeAt(1), 12);
eq("dq_v", "\v".charCodeAt(0), 11);
eq("dq_r", "\r".charCodeAt(0), 13);
eq("dq_n", "a\nb".charCodeAt(1), 10);
eq("dq_t", "a\tb".charCodeAt(1), 9);
eq("dq_0", "\0".charCodeAt(0), 0);
// single quotes share the path
eq("sq_b", 'a\bc'.charCodeAt(1), 8);
eq("sq_f", 'x\fy'.charCodeAt(1), 12);
// hex + unicode escapes
eq("hex_A", "\x41", "A");
eq("uni_B", "B", "B");
eq("uni_len", "B".length, 1);
eq("hex_code", "\x08".charCodeAt(0), 8);
// unknown escape -> literal char (JS semantics)
eq("unknown_q", "\q", "q");
// backslash / quotes not regressed
eq("bslash", "\\".charCodeAt(0), 92);
eq("dquote", "\"".charCodeAt(0), 34);
eq("squote", "\'".charCodeAt(0), 39);
// template literals share the escape switch
eq("tpl_b", `a\bc`.charCodeAt(1), 8);
eq("tpl_f", `x\fy`.charCodeAt(1), 12);
eq("tpl_v", `\v`.charCodeAt(0), 11);
eq("tpl_x", `\x41`, "A");
eq("tpl_u", `B`, "B");
// JSON.stringify round-trip of a control byte re-escapes it
eq("json_rt", JSON.stringify("a\bc"), "\"a\\bc\"");
console.log("RESULT ok=" + ok + " fail=" + fail);
EOF

"$BIN" "$FIX" > "$OUT/js_escapes.out" 2>&1
cat "$OUT/js_escapes.out"

if grep -q '^RESULT ok=23 fail=0$' "$OUT/js_escapes.out"; then
    echo "[js-esc] RESULT: PASS"
    exit 0
else
    echo "[js-esc] RESULT: FAIL"
    exit 1
fi
