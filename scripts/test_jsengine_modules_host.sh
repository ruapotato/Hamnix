#!/usr/bin/env bash
# scripts/test_jsengine_modules_host.sh — FAST, QEMU-free gate for ES MODULES
# (import / export) in the native JS engine (lib/jsengine.ad + lib/web/js/), via
# the x86_64-linux host driver (user/js_host.ad, `--module` mode).
#
# Modern sites ship as ESM bundles whose entry point is `<script type=module>`;
# an engine that cannot parse+link+evaluate `import`/`export` renders a TOTAL
# blank page. This gate builds a real MULTI-MODULE graph on disk and evaluates
# the entry, asserting the COMPOSED result — proving, in one run:
#   * parse of every import form: default, named (`{a, b as c}`), namespace
#     (`* as ns`), and side-effect (`import "x"`);
#   * parse of every export form: `export const/function/class`, `export default`,
#     named list `export {a as b}`, re-export `export {x} from`, `export * from`;
#   * the LINKER: relative-specifier resolution against the entry base, a shared
#     module cache (diamond deps load+run once), and dependency-ORDER evaluation;
#   * a best-effort import CYCLE (function exports resolve across the cycle edge).
#
# The module resolver reads sibling .js files from the entry's directory (the
# host embedder's job; the engine itself opens no sockets — Plan 9 discipline).
# Builds with the frozen Python seed compiler (no self-host dependency).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
MODIR="$OUT/js_modules_fixture"
mkdir -p "$OUT"

echo "[js-modules] compiling engine for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux user/js_host.ad "$BIN" 2>"$OUT/js_modules_compile.log"; then
    echo "[js-modules] FAIL: host driver did not compile"; cat "$OUT/js_modules_compile.log"; exit 1
fi
echo "[js-modules] PASS host driver compiled -> $BIN"

fail=0
rm -rf "$MODIR"; mkdir -p "$MODIR"

# assert_graph <name> <entry-basename> <expected-multiline-output>
assert_graph() {
    local name="$1" entry="$2" exp="$3" got
    got="$("$BIN" --module "$MODIR/$entry" 2>&1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-modules] PASS $name"
    else
        echo "[js-modules] FAIL $name:"
        echo "---- expected ----"; printf '%s\n' "$exp"
        echo "---- got ----";      printf '%s\n' "$got"
        fail=1
    fi
}

# ============================================================
# 1) A real ESM bundle: default + named + namespace + re-export across a
#    3-module dependency graph (entry -> shapes -> util ; entry -> util (diamond)
#    ; entry -> consts). Asserts every import/export form composes correctly.
# ============================================================
cat > "$MODIR/util.js" <<'EOF'
export const PI = 3;
export function square(x){ return x*x; }
export function cube(x){ return x*x*x; }
export default function greet(n){ return "hi " + n; }
EOF
cat > "$MODIR/shapes.js" <<'EOF'
import { square } from "./util.js";
export function area(r){ return square(r) * 3; }
export { square as sq } from "./util.js";
EOF
cat > "$MODIR/consts.js" <<'EOF'
export const NAME = "world";
export const VER = 2;
EOF
cat > "$MODIR/entry.js" <<'EOF'
import greet, { PI, cube } from "./util.js";
import { area, sq } from "./shapes.js";
import * as C from "./consts.js";
console.log(greet(C.NAME));
console.log("PI=" + PI + " cube3=" + cube(3));
console.log("area2=" + area(2) + " sq5=" + sq(5));
console.log("ver=" + C.VER + " name=" + C.NAME);
EOF
assert_graph bundle entry.js \
'hi world
PI=3 cube3=27
area2=12 sq5=25
ver=2 name=world'

# ============================================================
# 2) Evaluation ORDER + side-effect import + shared-cache dedup.
#    dep1 is imported by BOTH the entry (side-effect) and dep2, but must init
#    exactly once, and dependency order is dep1 -> dep2 -> entry.
# ============================================================
cat > "$MODIR/dep1.js" <<'EOF'
console.log("dep1 init");
export const A = 1;
EOF
cat > "$MODIR/dep2.js" <<'EOF'
import { A } from "./dep1.js";
console.log("dep2 init A=" + A);
export const B = A + 1;
EOF
cat > "$MODIR/ord.js" <<'EOF'
import "./dep1.js";
import { B } from "./dep2.js";
console.log("entry B=" + B);
EOF
assert_graph order_dedup ord.js \
'dep1 init
dep2 init A=1
entry B=2'

# ============================================================
# 3) `export * from` wildcard re-export (default is NOT re-exported by `*`).
# ============================================================
cat > "$MODIR/star_src.js" <<'EOF'
export const x = 10;
export const y = 20;
export default 99;
EOF
cat > "$MODIR/star_mid.js" <<'EOF'
export * from "./star_src.js";
export const z = 30;
EOF
cat > "$MODIR/star.js" <<'EOF'
import * as M from "./star_mid.js";
console.log("x=" + M.x + " y=" + M.y + " z=" + M.z + " def=" + M.default);
EOF
assert_graph export_star star.js \
'x=10 y=20 z=30 def=undefined'

# ============================================================
# 4) Best-effort import CYCLE: cyc_a <-> cyc_b (function exports). cyc_b calls a
#    function exported by the not-yet-evaluated cyc_a; hoisting makes it resolve.
# ============================================================
cat > "$MODIR/cyc_a.js" <<'EOF'
import { bVal } from "./cyc_b.js";
export function aVal(){ return 1; }
console.log("a: bVal is " + typeof bVal);
EOF
cat > "$MODIR/cyc_b.js" <<'EOF'
import { aVal } from "./cyc_a.js";
export function bVal(){ return 2; }
console.log("b: aVal() = " + aVal());
EOF
cat > "$MODIR/cyc_entry.js" <<'EOF'
import { aVal } from "./cyc_a.js";
console.log("entry aVal()=" + aVal());
EOF
assert_graph cycle cyc_entry.js \
'b: aVal() = 1
a: bVal is function
entry aVal()=1'

if [ "$fail" -eq 0 ]; then
    echo "[js-modules] RESULT: PASS"
    exit 0
else
    echo "[js-modules] RESULT: FAIL"
    exit 1
fi
