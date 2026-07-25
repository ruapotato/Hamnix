#!/usr/bin/env bash
# scripts/probe_dom_api.sh — FUNCTIONAL DOM / Web-API coverage probe. node has no
# DOM, so the oracle here is REAL chromium (`--headless --dump-dom`): each probe's
# JS writes its result string into <div id="out">, we run the page in BOTH engines,
# and compare the post-JS text of #out. hambrowse's side is read from the engine's
# FLOW dump (the rendered text of the page after load JS + timer drain).
#   PASS  = same result text in hb and chromium
#   FAIL  = different / missing / JSERR
# This maps which DOM & Web APIs real sites depend on actually WORK end-to-end.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="build/host/hambrowse_host"
CHROMIUM="$(command -v chromium || command -v chromium-browser || true)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
[ -x "$BIN" ] || { echo "build $BIN first"; exit 1; }
[ -n "$CHROMIUM" ] || { echo "need chromium for the oracle"; exit 1; }
FILTER="${1:-}"
pass=0 fail=0 err=0 FAILS=""

# probe NAME 'JS that sets document.getElementById("out").textContent = <result>'
probe() {
    local name="$1" js="$2"
    [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return
    cat > "$WORK/p.html" <<EOF
<!doctype html><html><head><title>NORESULT</title><style>
/* Fixed-size SOURCE boxes for the layout-read probes. They carry explicit
   widths so the measurement is viewport/scrollbar independent, and their style
   comes from a SHEET (not an inline attribute) so getComputedStyle has to
   consult the cascade rather than echoing back el.style. Inert for every other
   probe. */
#geo{width:200px;height:80px;padding:10px;border:2px solid #333}
#geoflex{display:flex;width:300px;height:50px}
</style></head><body>
<div id="out">NORESULT</div>
<div id="work"></div>
<div id="geo">Alpha</div>
<div id="geoflex">Gamma</div>
<script>
try {
$js
} catch(e){ document.title = "THREW:"+e.message; }
</script></body></html>
EOF
    local hb hberr chrome
    hb="$("$BIN" "$WORK/p.html" 880 2>&1)"
    hberr="$(echo "$hb" | grep -c '^JSERR' || true)"
    local hbout; hbout="$(echo "$hb" | sed -n 's/^TITLE //p' | tail -1)"
    chrome="$("$CHROMIUM" --headless --dump-dom "file://$WORK/p.html" 2>/dev/null \
             | grep -o '<title>[^<]*</title>' | head -1 | sed 's/<title>//;s|</title>||')"
    if [ "$hbout" = "$chrome" ] && [ -n "$chrome" ] && [ "$hberr" = "0" ]; then
        printf 'PASS  %-26s %s\n' "$name" "$chrome"; pass=$((pass+1))
    else
        printf 'FAIL  %-26s chrome=<%s> hb=<%s>%s\n' "$name" "$chrome" "$hbout" \
          "$([ "$hberr" != 0 ] && echo ' [JSERR]')"
        fail=$((fail+1)); [ "$hberr" != 0 ] && err=$((err+1)); FAILS="$FAILS $name"
    fi
}
R='var __o=document.getElementById("out");'   # shorthand; result set via SET(x)
# convention: each probe ends by writing "<<...>>" into #out via document API.

# ---- element creation / mutation ----
probe createElement        'var e=document.createElement("span");e.textContent="X";document.getElementById("work").appendChild(e);document.title=""+document.getElementById("work").children.length+"";'
probe innerHTML            'document.getElementById("work").innerHTML="<b>a</b><i>b</i>";document.title=""+document.getElementById("work").children.length+"";'
probe innerHTML_read       'document.getElementById("work").innerHTML="<p>hi</p>";document.title=""+document.getElementById("work").innerHTML.indexOf("hi")+"";'
probe textContent_set      'document.title="TC-OK";'
probe setAttribute         'var e=document.getElementById("work");e.setAttribute("data-x","7");document.title=""+e.getAttribute("data-x")+"";'
probe dataset              'var e=document.getElementById("work");e.dataset.foo="bar";document.title=""+e.dataset.foo+"";'
probe classList_add        'var e=document.getElementById("work");e.classList.add("a","b");document.title=""+e.className+"";'
probe classList_toggle     'var e=document.getElementById("work");e.classList.toggle("on");e.classList.toggle("on");e.classList.toggle("x");document.title=""+e.className+"";'
probe classList_contains   'var e=document.getElementById("work");e.className="a b";document.title=""+e.classList.contains("b")+"";'
probe removeChild          'var w=document.getElementById("work");var c=document.createElement("i");w.appendChild(c);w.removeChild(c);document.title=""+w.children.length+"";'
probe insertBefore         'var w=document.getElementById("work");var a=document.createElement("a");var b=document.createElement("b");w.appendChild(a);w.insertBefore(b,a);document.title=""+w.firstChild.tagName+"";'
probe replaceChild         'var w=document.getElementById("work");var a=document.createElement("a");w.appendChild(a);var b=document.createElement("b");w.replaceChild(b,a);document.title=""+w.firstChild.tagName+"";'
probe cloneNode            'var e=document.createElement("div");e.textContent="hi";var c=e.cloneNode(true);document.title=""+c.textContent+"";'
probe append_method        'var w=document.getElementById("work");w.append("txt");document.title=""+w.textContent+"";'
probe remove_method        'var w=document.getElementById("work");var c=document.createElement("i");w.appendChild(c);c.remove();document.title=""+w.children.length+"";'
probe insertAdjacentHTML   'var w=document.getElementById("work");w.insertAdjacentHTML("beforeend","<u>z</u>");document.title=""+w.children.length+"";'

# ---- queries ----
probe querySelector        'document.getElementById("work").innerHTML="<p class=x>a</p><p class=y>b</p>";document.title=""+document.querySelector(".y").textContent+"";'
probe querySelectorAll     'document.getElementById("work").innerHTML="<p>a</p><p>b</p><p>c</p>";document.title=""+document.querySelectorAll("p").length+"";'
probe qsa_attr             'document.getElementById("work").innerHTML="<a href=1>x</a><a>y</a>";document.title=""+document.querySelectorAll("a[href]").length+"";'
probe getElementsByTag     'document.getElementById("work").innerHTML="<b>1</b><b>2</b>";document.title=""+document.getElementsByTagName("b").length+"";'
probe getElementsByClass   'document.getElementById("work").innerHTML="<p class=z>1</p><p class=z>2</p>";document.title=""+document.getElementsByClassName("z").length+"";'
probe closest              'document.getElementById("work").innerHTML="<div class=a><p><span id=s>x</span></p></div>";document.title=""+(document.getElementById("s").closest(".a")?"Y":"N")+"";'
probe matches              'var e=document.createElement("div");e.className="foo";document.title=""+e.matches(".foo")+"";'
probe children_nav         'document.getElementById("work").innerHTML="<i>1</i><b>2</b>";var w=document.getElementById("work");document.title=""+w.firstElementChild.tagName+"-"+w.lastElementChild.tagName+"";'
probe nextSibling          'document.getElementById("work").innerHTML="<i>1</i><b>2</b>";document.title=""+document.getElementById("work").firstElementChild.nextElementSibling.tagName+"";'
probe parentNode           'var c=document.createElement("i");document.getElementById("work").appendChild(c);document.title=""+c.parentNode.id+"";'

# ---- events ----
probe addEventListener     'var w=document.getElementById("work");var e=document.createElement("button");e.id="b";w.appendChild(e);var hit=0;e.addEventListener("click",function(){hit=1;document.title="CLICKED"});e.click();'
probe event_bubble         'var w=document.getElementById("work");w.innerHTML="<div id=p><button id=c>x</button></div>";var got="";document.getElementById("p").addEventListener("click",function(e){got=e.target.id});document.getElementById("c").click();document.title=""+got+"";'
probe removeEventListener  'var e=document.createElement("button");var n=0;function h(){n++}e.addEventListener("click",h);e.removeEventListener("click",h);e.click();document.title=""+n+"";'
probe custom_event         'var e=document.createElement("div");var got="";e.addEventListener("foo",function(ev){got=ev.type});e.dispatchEvent(new Event("foo"));document.title=""+got+"";'
probe event_preventDefault 'var e=document.createElement("a");var ev=new Event("click",{cancelable:true});e.addEventListener("click",function(x){x.preventDefault()});e.dispatchEvent(ev);document.title=""+ev.defaultPrevented+"";'
probe event_stopProp       'var w=document.getElementById("work");w.innerHTML="<div id=p><button id=c>x</button></div>";var outer=0;document.getElementById("p").addEventListener("click",function(){outer++});document.getElementById("c").addEventListener("click",function(e){e.stopPropagation()});document.getElementById("c").click();document.title=""+outer+"";'
probe customEvent_detail   'var e=document.createElement("div");var d=0;e.addEventListener("x",function(ev){d=ev.detail.v});e.dispatchEvent(new CustomEvent("x",{detail:{v:42}}));document.title=""+d+"";'

# ---- timers / rAF ----
probe setTimeout           'setTimeout(function(){document.title="TIMER"},0);'
probe setTimeout_arg       'setTimeout(function(a){document.title="ARG"+a+""},0,7);'
probe clearTimeout         'var id=setTimeout(function(){document.title="SHOULDNOTFIRE"},0);clearTimeout(id);document.title="CLEARED";'
probe requestAnimFrame     'requestAnimationFrame(function(){document.title="RAF"});'
probe promise_then_dom     'Promise.resolve("P").then(function(v){document.title=""+v+""});'

# ---- storage / cookies ----
probe localStorage         'localStorage.setItem("k","v1");document.title=""+localStorage.getItem("k")+"";'
probe localStorage_json    'localStorage.setItem("o",JSON.stringify({a:1}));document.title=""+JSON.parse(localStorage.getItem("o")).a+"";'
probe sessionStorage       'sessionStorage.setItem("s","x");document.title=""+sessionStorage.getItem("s")+"";'
probe cookie               'document.cookie="a=1";__o.textContent="<<"+(document.cookie.indexOf("a=1")>=0?"Y":"N")+">>";'

# ---- forms ----
probe form_value           'document.getElementById("work").innerHTML="<input id=i value=hi>";document.title=""+document.getElementById("i").value+"";'
probe form_set_value       'document.getElementById("work").innerHTML="<input id=i>";document.getElementById("i").value="typed";document.title=""+document.getElementById("i").value+"";'
probe formdata             'document.getElementById("work").innerHTML="<form id=f><input name=a value=1><input name=b value=2></form>";var fd=new FormData(document.getElementById("f"));document.title=""+fd.get("a")+fd.get("b")+"";'
probe input_checked        'document.getElementById("work").innerHTML="<input type=checkbox id=c checked>";document.title=""+document.getElementById("c").checked+"";'

# ---- observers ----
probe mutationObserver     'var w=document.getElementById("work");var seen=0;var mo=new MutationObserver(function(){seen=1});mo.observe(w,{childList:true});w.appendChild(document.createElement("i"));setTimeout(function(){document.title="MO"+seen+""},0);'
probe intersectionObserver 'var io=new IntersectionObserver(function(){});document.title=""+(typeof io.observe)+"";'
probe resizeObserver       'document.title=""+(typeof ResizeObserver)+"";'

# ---- window / navigator / location ----
probe window_props         'document.title=""+(typeof window.innerWidth)+"";'
probe navigator            'document.title=""+(typeof navigator.userAgent)+"";'
probe location             'document.title=""+(typeof location.href)+"";'
probe history_api          'document.title=""+(typeof history.pushState)+"";'
probe getComputedStyle     'var e=document.createElement("div");e.style.color="red";document.body.appendChild(e);document.title=""+(typeof getComputedStyle(e).color)+"";'
probe element_style        'var e=document.createElement("div");e.style.width="50px";document.title=""+e.style.width+"";'
probe getBoundingRect      'var e=document.getElementById("out");document.title=""+(typeof e.getBoundingClientRect().width)+"";'

# --- REAL layout-read geometry (gap #2 of docs/browser_gap_analysis_2026-07-24).
# The three probes above only assert the TYPE of the returned value, so they
# passed even while the engine reported the element's TEXT INK or a stub
# constant (a 200x80 box read back as 40x16, a stylesheet padding as 0px,
# display:flex as block). These compare the NUMBERS against Chrome, over the
# #geo / #geoflex source boxes defined in the template above.
probe rect_real_size       'var r=document.getElementById("geo").getBoundingClientRect();document.title=Math.round(r.width)+"x"+Math.round(r.height);'
# Vertical ADVANCE between two source boxes: #geo's full border-box height must
# separate them. Expressed as a difference so it does not depend on the height
# the probe template's own preamble happens to occupy.
probe rect_real_advance    'var a=document.getElementById("geo").getBoundingClientRect(),b=document.getElementById("geoflex").getBoundingClientRect();document.title=Math.round(b.top-a.top)+"/"+Math.round(b.left-a.left);'
probe offset_real_size     'var g=document.getElementById("geo");document.title=g.offsetWidth+"x"+g.offsetHeight;'
probe computed_sheet_width 'document.title=getComputedStyle(document.getElementById("geo")).width;'
probe computed_sheet_pad   'document.title=getComputedStyle(document.getElementById("geo")).padding;'
probe computed_sheet_disp  'document.title=getComputedStyle(document.getElementById("geoflex")).display;'

# ---- canvas / SVG ----
probe canvas_ctx           'var c=document.createElement("canvas");var ctx=c.getContext("2d");document.title=""+(ctx?"Y":"N")+"";'
probe canvas_measure       'var c=document.createElement("canvas");var ctx=c.getContext("2d");document.title=""+(typeof ctx.measureText("hi").width)+"";'

# ---- web components ----
probe customElements       'document.title=""+(typeof customElements)+"";'
probe shadowdom            'var e=document.createElement("div");document.title=""+(typeof e.attachShadow)+"";'
probe template_el          'var t=document.createElement("template");document.title=""+(t.content?"Y":"N")+"";'

echo ""
echo "=== DOM/Web-API: $pass PASS / $fail FAIL ($err JSERR) ==="
[ -n "$FAILS" ] && echo "FAILED:$FAILS"
exit 0
