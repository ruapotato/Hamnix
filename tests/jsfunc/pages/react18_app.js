// tests/jsfunc/pages/react18_app.js — the APPLICATION half of the real-React-18
// gate. The other half is the UNMODIFIED upstream react/react-dom UMD bundles in
// tests/jsfunc/vendor/; scripts/test_react18_host.sh concatenates the three into
// one page (the engine has no <script src> loader) and runs it on the host.
//
// Deliberately no JSX and no build step: this is plain React.createElement, so
// what the gate exercises is the REAL reconciler, the REAL scheduler and the
// REAL synthetic-event system — not a mini-React stand-in.
//
// Everything the app computes is published into #log as one flat line, so the
// same page can be replayed in `chromium --headless` and the two answers
// compared BYTE-FOR-BYTE (scripts/test_react18_host.sh does exactly that).
var e = React.createElement;
var useState = React.useState;
var useEffect = React.useEffect;
var useReducer = React.useReducer;
var useMemo = React.useMemo;
var useCallback = React.useCallback;
var useRef = React.useRef;

var Ctx = React.createContext('CTX-DEFAULT');

// A memo()'d child: proves React.memo and the keyed-list diff both work.
function Row(props) {
  return e('li', { className: 'row', id: 'row-' + props.id }, props.text);
}
var MemoRow = React.memo(Row);

// useContext through a Provider several levels down.
function Deep() {
  return e('span', { id: 'ctx' }, React.useContext(Ctx));
}

function reducer(state, action) {
  if (action.type === 'bump') { return { hits: state.hits + 1 }; }
  return state;
}

function App() {
  var st = useState(0);
  var n = st[0], setN = st[1];
  var rd = useReducer(reducer, { hits: 10 });
  var red = rd[0], dispatch = rd[1];
  var domRef = useRef(null);

  // useMemo recomputes only when n changes; useCallback keeps a stable handler.
  var rows = useMemo(function () {
    return ['alpha', 'beta', 'gamma'].map(function (name, i) {
      return { id: i, text: name + '-' + n };
    });
  }, [n]);
  var onInc = useCallback(function () {
    setN(function (prev) { return prev + 1; });   // functional update
    dispatch({ type: 'bump' });
  }, []);

  // Effect + cleanup ordering is part of the observable trace.
  useEffect(function () {
    trace('effect:' + n);
    return function () { trace('cleanup:' + n); };
  }, [n]);

  return e(Ctx.Provider, { value: 'CTX-PROVIDED' },
    e(React.Fragment, null,
      e('h1', { id: 'title', style: { color: 'red' } }, 'React ' + React.version),
      e('button', { id: 'inc', onClick: onInc }, 'Count: ' + n),
      e('ul', { id: 'rows' }, rows.map(function (r) {
        return e(MemoRow, { key: r.id, id: r.id, text: r.text });
      })),
      e('div', { id: 'reducer' }, 'hits=' + red.hits),
      // Conditional subtree: absent at n === 0, mounted from n === 1 on.
      n > 0 ? e('p', { id: 'cond' }, 'CONDITIONAL-SHOWN') : null,
      // An SVG host instance — React creates these through createElementNS and
      // tracks the namespace on its host-context stack.
      e('svg', { id: 'svg', width: '20', height: '20' },
        e('rect', { id: 'rect', width: '10', height: '10' })),
      e('div', { id: 'refd', ref: domRef }, 'ref-node'),
      e(Deep, null)));
}

// The observable trace. Effects push into it; report() flattens what React
// mounted beside them, and PRINTS the line (console.log) rather than writing it
// into the DOM: the engine's console is the readback both this gate and
// `chromium --headless` can be compared on, byte for byte.
var traced = [];
function trace(s) { traced.push(s); }
function txt(id) {
  var el = document.getElementById(id);
  return el ? el.textContent : '<missing:' + id + '>';
}
function report() {
  console.log('REACT18 ' + [
    'ver=' + React.version.split('-')[0],
    'title=' + txt('title'),
    'btn=' + txt('inc'),
    'row0=' + txt('row-0'),
    'row2=' + txt('row-2'),
    'reducer=' + txt('reducer'),
    'cond=' + (document.getElementById('cond') ? txt('cond') : 'ABSENT'),
    'ctx=' + txt('ctx'),
    'ref=' + txt('refd'),
    'svg=' + (document.getElementById('rect') ? 'RECT-OK' : 'RECT-MISSING'),
    'trace=' + traced.join(',')
  ].join(' | '));
}

var root = ReactDOM.createRoot(document.getElementById('root'));
root.render(React.createElement(App));
// createRoot().render() is CONCURRENT: React 18 defers the work to its scheduler
// (MessageChannel, else setTimeout), and passive effects flush on a LATER task
// still. Two nested macrotasks is the first point at which both engines have
// certainly committed AND flushed effects, so the two traces are comparable
// without either side encoding a scheduling accident.
setTimeout(function () { setTimeout(report, 0); }, 0);

// ...and again after any click, on the same two-macrotask delay, so the gate can
// read the POST-CLICK tree the same way in both engines. This listener is on
// `document` (outside React's root), so it observes the click without taking
// part in React's synthetic-event delegation.
document.addEventListener('click', function () {
  setTimeout(function () { setTimeout(report, 0); }, 0);
});
