// Regression cover for ES 7.1.1 ToPrimitive reaching BUILTIN objects.
// String(obj) requires a callable valueOf/toString on the prototype chain; when
// a builtin prototype lacked one (or had a null [[Prototype]]) the conversion
// threw "Cannot convert object to primitive value" and killed the whole script.
// Every expectation below is node v20 output, value for value.
function show(label, f) {
  var r;
  try { r = String(f()); } catch (e) { r = "THREW " + (e && e.name ? e.name : "?"); }
  console.log(label + " => " + r);
}
// Error.prototype.toString (ES 20.5.3.4): name/message defaults and the
// empty-name / empty-message branches.
show("err", function(){ return new Error("boom"); });
show("typeerr", function(){ return new TypeError("bad type"); });
show("noargs", function(){ return new Error(); });
show("rangeempty", function(){ return new RangeError(); });
show("renamed", function(){ var e = new Error("m"); e.name = "Custom"; return e; });
show("blankmsg", function(){ var e = new Error("m"); e.message = ""; return e; });
show("subclass", function(){
  function MyErr(m){ this.message = m; }
  MyErr.prototype = Object.create(Error.prototype);
  MyErr.prototype.name = "MyErr";
  return new MyErr("custom");
});
show("classext", function(){
  class E extends Error { constructor(m){ super(m); this.name = "E"; } }
  return new E("cm");
});
console.log("call-plain => " + Error.prototype.toString.call({name:"N", message:"M"}));
console.log("call-nomsg => " + Error.prototype.toString.call({name:"N"}));
console.log("call-noname => " + Error.prototype.toString.call({message:"M"}));
console.log("call-empty => " + Error.prototype.toString.call({}));
console.log("call-blankname => " + Error.prototype.toString.call({name:"", message:"M"}));
console.log("typeof-toString => " + typeof Error.prototype.toString);
// The other ToPrimitive entry points must agree with String().
var te = new TypeError("x");
console.log("template => " + `${te}`);
console.log("concat => " + ("" + te));
console.log("plus => " + (new Error("a") + "!"));
console.log("join => " + [new Error("j")].join(","));
// RegExp.prototype.toString (ES 22.2.6.13).
show("relit", function(){ return /a[b]c/gi; });
show("rector", function(){ return new RegExp("x+", "m"); });
console.log("re-call => " + RegExp.prototype.toString.call({source:"a", flags:"g"}));
// Builtins that inherit Object.prototype.toString: the @@toStringTag brand has
// to be found through the PROTOTYPE chain, not just as an own property.
show("map", function(){ return new Map(); });
show("set", function(){ return new Set([1,2]); });
show("promise", function(){ return Promise.resolve(1); });
show("math", function(){ return Math; });
show("json", function(){ return JSON; });
show("arraybuffer", function(){ return new ArrayBuffer(4); });
show("dataview", function(){ return new DataView(new ArrayBuffer(4)); });
show("generator", function(){ function* g(){ yield 1; } return g(); });
console.log("tag-error => " + Object.prototype.toString.call(new Error("x")));
console.log("tag-typeerror => " + Object.prototype.toString.call(new TypeError("x")));
console.log("tag-regexp => " + Object.prototype.toString.call(/a/));
console.log("tag-plain => " + Object.prototype.toString.call({}));
// Symbols are TAG_OBJ internally but primitive: String() yields the
// SymbolDescriptiveString (ES 20.4.3.3), not an object dump.
console.log("symbol => " + String(Symbol("s")));
console.log("symbol-nodesc => " + String(Symbol()));
console.log("symbol-method => " + Symbol("m").toString());
// Untouched paths, as a guard that the retro-linking did not disturb them.
show("array", function(){ return [1,2,3]; });
show("object", function(){ return {a:1}; });
show("numwrap", function(){ return new Number(5); });
show("strwrap", function(){ return new String("hi"); });
show("typedarray", function(){ return new Uint8Array([1,2,3]); });
console.log("done");
