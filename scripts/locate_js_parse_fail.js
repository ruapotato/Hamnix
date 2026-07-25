// scripts/locate_js_parse_fail.js — localize hambrowse's "SyntaxError: unexpected
// token" inside a huge MINIFIED bundle down to the smallest AST node that still
// fails to parse.
//
// Method: parse the bundle with acorn (bundled with node), then descend the AST.
// For each candidate node we take its exact source slice, wrap it in a function
// body that is PARSED BUT NEVER CALLED, and run it through the hambrowse host
// engine. Parse-only isolation means ReferenceErrors from missing scope do not
// confuse the search — we look strictly for "SyntaxError".
//
// Usage: node scripts/locate_js_parse_fail.js <file.js> [--stmt-scan]
const fs = require('fs');
const os = require('os');
const path = require('path');
const cp = require('child_process');
const acorn = require('acorn');

const BIN = 'build/host/hambrowse_probe_host';
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'jsloc-'));
let runs = 0;

function fails(src, asExpr) {
  runs++;
  const body = asExpr ? `var __z = (${src});` : src;
  const html = '<!doctype html><html><body><script>\nfunction __never(){\n' +
    body.replace(/<\/script/gi, '<\\/script') + '\n}\n</script></body></html>';
  const f = path.join(tmp, 'p.html');
  fs.writeFileSync(f, html);
  let out = '';
  try {
    out = cp.execFileSync(BIN, [f, '1024'], { encoding: 'utf8', timeout: 600000 });
  } catch (e) { out = (e.stdout || '') + (e.stderr || ''); }
  return /JSERR .*SyntaxError/.test(out);
}

const file = process.argv[2];
const src = fs.readFileSync(file, 'utf8');
let ast;
try {
  ast = acorn.parse(src, { ecmaVersion: 'latest', sourceType: 'script' });
} catch (e) {
  console.log('acorn itself cannot parse this file:', e.message);
  process.exit(1);
}

if (!fails(src, false)) {
  console.log('hambrowse parses this file fine (no SyntaxError).');
  process.exit(0);
}
console.log('bundle size', src.length, '— descending AST...');

function children(node) {
  const out = [];
  for (const k of Object.keys(node)) {
    if (k === 'start' || k === 'end' || k === 'type' || k === 'loc') continue;
    const v = node[k];
    if (Array.isArray(v)) { for (const x of v) if (x && typeof x.type === 'string') out.push(x); }
    else if (v && typeof v.type === 'string') out.push(v);
  }
  return out.sort((a, b) => a.start - b.start);
}

let cur = ast, depth = 0;
const trail = [];
for (;;) {
  const kids = children(cur);
  let next = null;
  for (const k of kids) {
    const slice = src.slice(k.start, k.end);
    const isExpr = /Expression$|Literal$|Identifier|Element|Property|Pattern$/.test(k.type);
    if (fails(slice, isExpr)) { next = k; break; }
  }
  if (!next) break;
  cur = next; depth++;
  trail.push(`${cur.type}[${cur.start}..${cur.end}] len=${cur.end - cur.start}`);
  if (depth > 400) break;
}

console.log('--- smallest failing node ---');
console.log(trail.slice(-6).join('\n'));
console.log('type:', cur.type, 'len:', cur.end - cur.start, `(engine runs: ${runs})`);
const slice = src.slice(cur.start, cur.end);
console.log('SOURCE:');
console.log(slice.length > 1500 ? slice.slice(0, 1500) + ' …[truncated]' : slice);
console.log('CONTEXT:', JSON.stringify(src.slice(Math.max(0, cur.start - 90), cur.start)) +
  ' >>> ' + JSON.stringify(src.slice(cur.end, cur.end + 90)));
