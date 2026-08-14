const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-1020: the terminal's history scrollbar. xterm 6 scrolls through a VS Code
// scrollable element built with `vertical: ScrollbarVisibility.Auto`, so its
// thumb fades out whenever the pointer leaves the grid; app.css pins it visible
// while `#terminal-wrap` carries `.has-scrollback`, and `updateTerminalScrollbar`
// is what puts that class on and takes it off.
//
// The gate is the load-bearing part, so that is what this drives. With nothing
// to scroll xterm sizes the slider to the WHOLE track, so a class that stuck on
// would paint a permanent stripe down every empty terminal — "off when there is
// no history" is as much of a requirement as "on when there is".
//
// `scrollbarTheme` is driven too: xterm paints its slider from JS theme options,
// so a token that never reaches them is a bar that is pinned visible in exactly
// the colour that made it invisible.
const epilogue = `
;globalThis.__t = {
  updateTerminalScrollbar(){ return updateTerminalScrollbar(); },
  scrollbarTheme(){ return scrollbarTheme(); },
  set term(v){ term = v; },
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

const dom = new JSDOM(
  `<!doctype html><html><body><div id="terminal-wrap"><div id="terminal"></div></div></body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;
window.WebSocket = function () {
  return { send() {}, close() {},
    set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
};
window.WebSocket.OPEN = 1;
window.TextEncoder = TextEncoder;
window.setInterval = () => 0;
window.setTimeout = () => 0;
window.requestAnimationFrame = () => 0;

// Unlike the other harnesses this one does NOT stub getElementById away, because
// the class lands on a real `#terminal-wrap` and the assertions read it back. Any
// other id app.js reaches for during load still has to resolve, though.
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) =>
  realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run (app.js threw before it)'); process.exit(2); }

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };

const wrap = window.document.getElementById('terminal-wrap');
const shown = () => wrap.classList.contains('has-scrollback');

// `baseY` is how many lines have scrolled off the top — xterm's own test for
// whether the bar is needed, and 0 in the alternate screen.
function setTerm(baseY) {
  T.term = baseY === null ? null : { buffer: { active: { baseY, viewportY: 0 } } };
}

console.log('terminal scrollbar (CROW-1020)');

{
  setTerm(0);
  T.updateTerminalScrollbar();
  check('an empty buffer gets no bar', !shown());
}
{
  setTerm(1);
  T.updateTerminalScrollbar();
  check('one line of history is enough to show it', shown());
}
{
  setTerm(19949);
  T.updateTerminalScrollbar();
  check('a deep buffer keeps it shown', shown());
}
{
  // Switching to an alt-buffer agent (Claude Code) or clearing the screen drops
  // baseY back to 0. The class has to come off, or the pinned slider — sized to
  // the full track when it is not needed — becomes a permanent stripe.
  setTerm(500);
  T.updateTerminalScrollbar();
  setTerm(0);
  T.updateTerminalScrollbar();
  check('dropping back to no history hides it again', !shown());
}
{
  // Belt and braces: `has-scrollback` is not the only class on this element
  // (#677's `.loading`, #687's `.reconnecting`), so the toggle must not clobber
  // its neighbours.
  wrap.classList.add('loading');
  setTerm(300);
  T.updateTerminalScrollbar();
  check('toggling it leaves the skeleton/reconnect classes alone',
    shown() && wrap.classList.contains('loading'));
  wrap.classList.remove('loading');
}

console.log('\n  before a terminal exists');
{
  setTerm(400);
  T.updateTerminalScrollbar();
  setTerm(null);
  T.updateTerminalScrollbar();
  check('no terminal hides the bar rather than throwing', !shown());
}
{
  // A Terminal that has been constructed but not opened has no buffer yet; the
  // #668 pill reads the same fields and this path runs on the same events.
  T.term = {};
  T.updateTerminalScrollbar();
  check('a terminal with no buffer yet does not throw', !shown());
}

console.log('\n  theme handoff');
{
  // No tokens in this document yet, so every one reads empty — and an empty
  // token must OMIT its key rather than send xterm an empty colour string, which
  // css.toColor rejects by THROWING ("Unsupported css format") and would take
  // the whole terminal down at construction.
  const theme = T.scrollbarTheme();
  check('missing tokens yield no keys at all (xterm keeps its own default)',
    theme && Object.keys(theme).length === 0);
  check('  ... and never an empty colour string xterm would throw on',
    !Object.values(theme).some((v) => !v));
}
{
  // Now with the tokens defined, as app.css defines them. Distinct values per
  // token on purpose: equal ones would let the three keys be transposed — hover
  // wired to the resting colour, say — with every assertion still green.
  const style = window.document.createElement('style');
  style.textContent = ':root {'
    + ' --scroll-thumb: rgba(221, 196, 130, 0.50);'
    + ' --scroll-thumb-hover: rgba(221, 196, 130, 0.72);'
    + ' --scroll-thumb-active: rgba(221, 196, 130, 0.90);'
    + ' }';
  window.document.head.appendChild(style);

  const theme = T.scrollbarTheme();
  check('the resting thumb comes from --scroll-thumb',
    theme.scrollbarSliderBackground === 'rgba(221, 196, 130, 0.50)');
  check('the hover thumb comes from --scroll-thumb-hover',
    theme.scrollbarSliderHoverBackground === 'rgba(221, 196, 130, 0.72)');
  check('the drag thumb comes from --scroll-thumb-active',
    theme.scrollbarSliderActiveBackground === 'rgba(221, 196, 130, 0.90)');
  check('and nothing else is smuggled into the theme', Object.keys(theme).length === 3);

  // `rgba(r, g, b, a)` is one of the forms xterm's css.toColor parses, so the
  // token text can go over verbatim. Guard the shape here rather than trusting
  // it: an unparseable colour throws at Terminal construction.
  const rgba = /^rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*(,\s*(0|1|\d?\.\d+)\s*)?\)$/;
  check('  ... in a form xterm can parse',
    Object.values(theme).every((v) => rgba.test(v)));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
