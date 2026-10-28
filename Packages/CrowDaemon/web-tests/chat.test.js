const { JSDOM } = require('jsdom');
const vm = require('vm');
const fs = require('fs');
const { loadClientSource, WEB } = require('./load-client');

// Chat view: #/sessions/:id/chat routing, and the transcript renderer
// that turns `get-session-transcript` pages into bubbles + collapsed tool rows.
const epilogue = `
;globalThis.__t = {
  parseRoute, routeToHash,
  newChatState, applyChatPage, ensureChatDom, sendChatMessage, buildChatMarkdown,
  updateChatMenu, chatMenuKeydown, chatHistoryKeydown, filterChatCommands, formatChatModel, formatChatTokens,
  set chatMd(v){ chatMd = v; },
  set selectedId(v){ selectedId = v; },
  set chatState(v){ chatState = v; },
  get chatState(){ return chatState; },
  applyChatView, setChatViewActive, chatHeaderMeter, chatToggleControl, onChatConfigLoaded,
  insertChatText, chatDrafts,
  set chatViewFlag(v){ uiConfig.chatViewEnabled = v; },
  set rpc(v){ rpc = v; },
  set copyToClipboard(v){ copyToClipboard = v; },
};
`;

const dom = new JSDOM(
  `<!doctype html><html><body>
     <div id="app"></div><div id="sidebar"></div>
     <main id="detail"><header id="detail-header"></header><div id="tabbar"></div>
     <div id="terminal-wrap"></div></main>
     <div id="board"></div>
     <div id="session-switcher" hidden></div>
   </body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;
window.WebSocket = function () {
  return { send() {}, close() {},
    set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
};
window.setInterval = () => 0;
window.setTimeout = () => 0;
window.requestAnimationFrame = () => 0;
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id)
  || (['chat-view', 'chat-log', 'chat-status', 'chat-send', 'chat-input', 'chat-jump',
    'chat-menu', 'chat-meta'].includes(id)
    ? null : window.document.createElement('div'));

const ctx = dom.getInternalVMContext();
// chat.js loads markdown-it lazily via a <script> tag, which jsdom's
// outside-only mode won't execute — evaluate the vendored file directly.
vm.runInContext(fs.readFileSync(WEB + 'markdown-it.min.js', 'utf8'), ctx, { filename: 'markdown-it.min.js' });
try { vm.runInContext(loadClientSource() + epilogue, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run'); process.exit(2); }

let failed = 0;
function check(name, ok) {
  if (ok) console.log('  ok  ' + name);
  else { failed++; console.log('  FAIL ' + name); }
}

const SID = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA';

console.log('chat route');
const r = T.parseRoute('#/sessions/' + SID + '/chat');
check('parses /chat', r && r.view === 'session' && r.sessionId === SID && r.chat === true);
check('round-trips', T.routeToHash(r) === '#/sessions/' + SID + '/chat');
check('chat wins over a terminal id', T.routeToHash({ view: 'session', sessionId: SID, terminalId: 'T', chat: true })
  === '#/sessions/' + SID + '/chat');
check('plain session route unchanged', T.routeToHash({ view: 'session', sessionId: SID }) === '#/sessions/' + SID);

console.log('renderer');
T.chatMd = T.buildChatMarkdown();
check('markdown-it loaded', !!window.markdownit);
T.selectedId = SID;
T.ensureChatDom();
const doc = window.document;
const log = doc.getElementById('chat-log');
const st = T.newChatState(SID);
T.applyChatPage(st, {
  supported: true, reset: true, cursor: 100, path: '/p.jsonl', terminal_id: 'TERM',
  events: [
    { kind: 'user', text: 'Fix it <img src=x onerror=alert(1)>' },
    { kind: 'assistant', text: 'Running **tests** with `swift test`.\n\n```sh\nswift test\n```' },
    { kind: 'tool_call', tool_name: 'Bash', tool_id: 't1', text: 'swift test' },
  ],
});
check('user + assistant bubbles', log.querySelectorAll('.chat-user').length === 1
  && log.querySelectorAll('.chat-assistant').length === 1);
check('no HTML injection', log.querySelector('img') === null
  && log.querySelector('.chat-user').textContent.includes('<img'));
check('inline code + bold', log.querySelector('.chat-assistant code').textContent === 'swift test'
  && log.querySelector('.chat-assistant strong').textContent === 'tests');
check('fenced block renders as code', log.querySelector('.chat-assistant pre code').textContent === 'swift test\n');
const tool = log.querySelector('details.chat-tool');
check('tool call is collapsed', tool && !tool.open && tool.querySelector('.chat-tool-name').textContent === 'Bash');
check('cursor + terminal captured', st.cursor === 100 && st.terminalId === 'TERM' && st.path === '/p.jsonl');
check('mid-turn reads as busy', doc.getElementById('chat-status').classList.contains('busy'));

// Incremental page: the result lands inside the earlier call, not as a new row.
T.applyChatPage(st, {
  supported: true, reset: false, cursor: 200,
  events: [
    { kind: 'tool_result', tool_id: 't1', text: 'FAIL', is_error: true },
    { kind: 'assistant', text: 'Fixed.' },
    { kind: 'turn_end', duration_ms: 65000 },
    { kind: 'turn_end' },
  ],
});
check('result nests in its call', tool.querySelector('.chat-tool-result').textContent === 'FAIL'
  && log.querySelectorAll('details.chat-tool').length === 1);
check('error marks the call', tool.classList.contains('error'));
check('appended, not replaced', log.querySelectorAll('.chat-assistant').length === 2);
check('duplicate turn end collapses', log.querySelectorAll('.chat-turn-end').length === 1);
check('turn duration formatted', log.querySelector('.chat-turn-end').textContent === 'Done · 1m 5s');
check('idle after turn end', !doc.getElementById('chat-status').classList.contains('busy'));
check('composer enabled with a terminal', doc.getElementById('chat-send').disabled === false);

// A reset (new transcript file) clears the log.
T.applyChatPage(st, { supported: true, reset: true, truncated: true, cursor: 5, path: '/q.jsonl',
  events: [{ kind: 'user', text: 'hi' }] });
check('reset clears the log', log.querySelectorAll('.chat-msg').length === 1);
check('truncated tail says so', /terminal history/.test(log.querySelector('.chat-notice').textContent));

// Unsupported harness.
const st2 = T.newChatState(SID);
T.applyChatPage(st2, { supported: false, reason: 'Chat view is not supported for cursor yet.', events: [] });
check('unsupported shows the reason', doc.getElementById('chat-status').textContent.includes('cursor'));
check('no terminal → composer disabled', doc.getElementById('chat-send').disabled === true);

console.log('markdown + links');
T.applyChatPage(st, { supported: true, reset: true, cursor: 9, path: '/m.jsonl', events: [
  { kind: 'assistant', text: '## Plan\n\n- one\n- two\n\nSee [the PR](https://github.com/corveil/crow/pull/1) or https://example.com/x.\n\n[bad](javascript:alert(1)) <script>alert(1)</script> ![pic](https://example.com/p.png)' },
  { kind: 'tool_call', tool_name: 'Bash', tool_id: 't9', text: 'gh pr create' },
  { kind: 'tool_result', tool_id: 't9', text: 'Created https://github.com/corveil/crow/pull/2 ok' },
  { kind: 'notice', text: 'Docs: https://example.com/d' },
] });
const mdB = log.querySelector('.chat-assistant');
check('heading + list render', mdB.querySelector('h2') && mdB.querySelectorAll('li').length === 2);
const links = [...mdB.querySelectorAll('a')];
check('markdown link is clickable in a new tab', links.some((a) => a.href === 'https://github.com/corveil/crow/pull/1'
  && a.target === '_blank' && /noopener/.test(a.rel)));
check('bare URL is linkified', links.some((a) => a.href === 'https://example.com/x'));
check('javascript: link is not a link', !links.some((a) => /^javascript:/i.test(a.getAttribute('href') || ''))
  && mdB.textContent.includes('[bad]'));
check('raw HTML stays text', !mdB.querySelector('script') && mdB.textContent.includes('<script>'));
check('image becomes a link, not an <img>', !mdB.querySelector('img') && links.some((a) => a.href === 'https://example.com/p.png'));
const resA = log.querySelector('.chat-tool-result a');
check('URL in tool output is clickable', resA && resA.href === 'https://github.com/corveil/crow/pull/2'
  && log.querySelector('.chat-tool-result').textContent === 'Created https://github.com/corveil/crow/pull/2 ok');
check('URL in a notice is clickable', log.querySelector('.chat-notice a').href === 'https://example.com/d');

console.log('copy as markdown');
const copied = [];
T.copyToClipboard = (t) => copied.push(t);
const SRC = '# Title\n\n- **one**\n- two\n\n```swift\nlet x = 1\nprint(x)\n```\n\nDone.';
T.applyChatPage(st, { supported: true, reset: true, cursor: 3, path: '/c.jsonl', events: [
  { kind: 'assistant', text: SRC },
  { kind: 'user', text: 'Use `rg`' },
] });
const cB = log.querySelector('.chat-assistant');
const msgCopy = cB.querySelector(':scope > .chat-msg-copy');
check('each bubble has a message Copy', msgCopy && log.querySelector('.chat-user > .chat-msg-copy'));
msgCopy.click();
check('message Copy puts the exact source markdown on the clipboard', copied.pop() === SRC);
check('button reads Copied after a click', msgCopy.classList.contains('copied')
  && msgCopy.getAttribute('aria-label') === 'Copied');
log.querySelector('.chat-user > .chat-msg-copy').click();
check('user message copies its source too', copied.pop() === 'Use `rg`');
const codeCopy = cB.querySelector('.chat-code-block > .chat-code-copy');
check('fenced block gets its own Copy', codeCopy && cB.querySelectorAll('.chat-code-copy').length === 1);
codeCopy.click();
check('code Copy copies only the block body (no fences, no lang, no trailing newline)',
  copied.pop() === 'let x = 1\nprint(x)');
check('copy controls add no text to the message', !/Copy/.test(cB.textContent)
  && cB.querySelector('.chat-msg-body').textContent === cB.textContent);
check('rendered markdown still lives in the body', cB.querySelector('.chat-msg-body.md h1')
  && cB.querySelector('.chat-msg-body pre code').textContent === 'let x = 1\nprint(x)\n');
cB.dispatchEvent(new window.MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 5, clientY: 5 }));
const ctxItems = [...doc.querySelectorAll('.ctx-menu .ctx-item')];
check('right-click offers Copy as markdown (no Copy without a selection)',
  ctxItems.length === 1 && ctxItems[0].textContent === 'Copy as markdown');
ctxItems[0].click();
check('Copy as markdown copies the source', copied.pop() === SRC && !doc.querySelector('.ctx-menu'));

// markdown-it failed to load: the fallback renderer gets the same controls.
T.chatMd = null;
T.applyChatPage(st, { supported: true, reset: true, cursor: 4, path: '/f.jsonl', events: [
  { kind: 'assistant', text: 'Run **this**:\n\n```sh\nmake test\n```' },
] });
const fB = log.querySelector('.chat-assistant');
check('fallback renders without markdown-it', !fB.querySelector('.md') && fB.querySelector('pre.chat-code'));
fB.querySelector('.chat-msg-copy').click();
check('fallback message Copy is the source', copied.pop() === 'Run **this**:\n\n```sh\nmake test\n```');
fB.querySelector('.chat-code-copy').click();
check('fallback code Copy is the block body', copied.pop() === 'make test');
T.chatMd = T.buildChatMarkdown();

console.log('sending');
const calls = [];
T.rpc = async (m, p) => { calls.push([m, p]); return {}; };
const st3 = T.newChatState(SID);
T.chatState = st3;
T.applyChatPage(st3, { supported: true, reset: true, cursor: 1, path: '/d.jsonl', terminal_id: 'TERM', events: [] });
check('no driver UI is rendered', !doc.querySelector('#chat-driver') && !doc.querySelector('.chat-permission'));
(async () => {
  calls.length = 0;
  doc.getElementById('chat-input').value = 'hello';
  await T.sendChatMessage();
  await new Promise((r) => setImmediate(r));
  const sends = calls.filter(([m]) => m === 'send' || m.startsWith('chat-driver'));
  check('composer types into the agent terminal via send (Enter appended)', sends.length === 1
    && sends[0][0] === 'send' && sends[0][1].terminal_id === 'TERM' && sends[0][1].text === 'hello\n');

  console.log('slash menu');
  const COMMANDS = [
    { name: 'clear', description: 'Start a new conversation', kind: 'builtin', scope: 'builtin' },
    { name: 'compact', description: 'Summarize the conversation', kind: 'builtin', scope: 'builtin' },
    { name: 'review-pr', description: 'Review a pull request', kind: 'skill', scope: 'project' },
    { name: 'ship', description: 'Compact and ship it', kind: 'command', scope: 'user' },
  ];
  let listCalls = 0;
  T.rpc = async (m) => {
    if (m === 'list-chat-commands') { listCalls++; return { supported: true, commands: COMMANDS }; }
    return {};
  };
  const st4 = T.newChatState(SID);
  T.chatState = st4;
  T.applyChatPage(st4, { supported: true, reset: true, cursor: 1, path: '/s.jsonl', terminal_id: 'TERM',
    agent_kind: 'claude-code', events: [] });
  const input = doc.getElementById('chat-input');
  const menu = doc.getElementById('chat-menu');
  const key = (k) => {
    const e = new window.KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true });
    return T.chatMenuKeydown(e);
  };
  input.value = 'hello /review'; T.updateChatMenu();
  check('no menu unless / leads the message', menu.hidden);
  input.value = '/'; input.setSelectionRange(1, 1); T.updateChatMenu();
  await new Promise((r) => setImmediate(r));
  check('commands fetched once, on the first /', listCalls === 1);
  check('menu lists every command for a bare /', !menu.hidden && menu.querySelectorAll('.chat-menu-item').length === 4);
  input.value = '/comp'; input.setSelectionRange(5, 5); T.updateChatMenu();
  const names = () => [...menu.querySelectorAll('.chat-menu-name')].map((n) => n.textContent);
  check('prefix matches rank before description matches', names().join(',') === '/compact,/ship');
  check('ArrowDown moves the selection', key('ArrowDown') && menu.querySelector('.active .chat-menu-name').textContent === '/ship');
  check('ArrowDown wraps', key('ArrowDown') && menu.querySelector('.active .chat-menu-name').textContent === '/compact');
  check('Enter picks the item', key('Enter') && input.value === '/compact ' && menu.hidden);
  input.value = '/rev extra words'; input.setSelectionRange(4, 4); T.updateChatMenu();
  check('Tab picks and keeps the arguments', key('Tab') && input.value === '/review-pr extra words');
  input.value = '/cl'; input.setSelectionRange(3, 3); T.updateChatMenu();
  check('Escape closes without picking', key('Escape') && menu.hidden && input.value === '/cl');
  check('keys pass through when the menu is closed', key('Enter') === false);
  input.value = '/r'; input.setSelectionRange(2, 2); T.updateChatMenu();
  menu.querySelector('.chat-menu-item').dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
  check('tapping an item picks it', input.value === '/review-pr ');
  check('filter ignores case', T.filterChatCommands(COMMANDS, 'REV').length === 1);
  const st5 = T.newChatState(SID);
  T.chatState = st5;
  T.applyChatPage(st5, { supported: true, reset: true, cursor: 1, path: '/c.jsonl', terminal_id: 'TERM',
    agent_kind: 'codex', events: [] });
  input.value = '/'; input.setSelectionRange(1, 1); T.updateChatMenu();
  check('no menu for non-Claude sessions', menu.hidden && listCalls === 1);

  // A daemon without the RPC: one request, a message, and no retry loop.
  let failCalls = 0;
  T.rpc = async (m) => { if (m === 'list-chat-commands') { failCalls++; throw new Error('Unknown method'); } return {}; };
  const st7 = T.newChatState(SID);
  T.chatState = st7;
  T.applyChatPage(st7, { supported: true, reset: true, cursor: 1, path: '/f.jsonl', terminal_id: 'TERM',
    agent_kind: 'claude-code', events: [] });
  input.value = '/'; input.setSelectionRange(1, 1); T.updateChatMenu();
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
  T.updateChatMenu();
  check('a failed command fetch is not retried in a loop', failCalls === 1);
  check('…and says commands are unavailable', !menu.hidden && menu.textContent.includes('unavailable'));

  console.log('focus on session switch');
  const pending = () => new Promise(() => {}); // RPCs never answer; pages are applied by hand
  T.rpc = pending;
  T.setChatViewActive(true);
  input.blur();
  const pageFor = (sid) => ({ supported: true, reset: true, cursor: 1, path: '/' + sid, terminal_id: 'TERM-' + sid,
    agent_kind: 'claude-code', events: [] });
  T.selectedId = 'S-A';
  T.applyChatView();
  check('no focus while the composer is still disabled', doc.activeElement !== input);
  T.applyChatPage(T.chatState, pageFor('S-A'));
  check('focuses the composer once it is enabled', doc.activeElement === input);
  input.blur();
  T.applyChatPage(T.chatState, { supported: true, reset: false, cursor: 2, events: [] });
  check('a later poll does not grab focus back', doc.activeElement !== input);

  const other = doc.createElement('input');
  doc.body.appendChild(other);
  T.selectedId = 'S-B';
  T.applyChatView();
  other.focus();
  T.applyChatPage(T.chatState, pageFor('S-B'));
  check('another focused text field keeps focus', doc.activeElement === other);
  other.remove();

  window.matchMedia = (q) => ({ matches: /coarse/.test(q) });
  T.selectedId = 'S-C';
  T.applyChatView();
  T.applyChatPage(T.chatState, pageFor('S-C'));
  check('no auto-focus on touch devices (no surprise keyboard)', doc.activeElement !== input);
  delete window.matchMedia;

  console.log('prompt history');
  T.rpc = pending;
  T.selectedId = 'H-1';
  T.applyChatView();
  T.applyChatPage(T.chatState, { supported: true, reset: true, cursor: 1, path: '/h', terminal_id: 'T-H',
    agent_kind: 'claude-code', events: [
      { kind: 'user', text: 'first' }, { kind: 'assistant', text: 'a' },
      { kind: 'user', text: 'second' }, { kind: 'user', text: 'second' },
      { kind: 'user', text: 'line one\nline two' },
    ] });
  const hk = (k, mods) => T.chatHistoryKeydown(new window.KeyboardEvent('keydown',
    Object.assign({ key: k, bubbles: true, cancelable: true }, mods || {})), input);
  input.value = '';
  check('↑ on an empty composer recalls the newest prompt', hk('ArrowUp') && input.value === 'line one\nline two');
  input.setSelectionRange(input.value.length, input.value.length);
  check('↑ with the caret below line one moves the caret, not history', hk('ArrowUp') === false);
  input.setSelectionRange(0, 0);
  check('↑ from the first line steps back (repeats collapsed)', hk('ArrowUp') && input.value === 'second');
  check('↑ again', hk('ArrowUp') && input.value === 'first');
  check('↑ at the oldest stays put', hk('ArrowUp') && input.value === 'first');
  check('↓ steps forward', hk('ArrowDown') && input.value === 'second');
  hk('ArrowDown');
  input.setSelectionRange(input.value.length, input.value.length);
  check('↓ past the newest clears the composer', hk('ArrowDown') && input.value === '');
  input.value = 'my draft';
  check('a draft is never overwritten by ↑', hk('ArrowUp') === false && input.value === 'my draft');
  input.value = '';
  check('modified arrows are left alone', hk('ArrowUp', { shiftKey: true }) === false);
  hk('ArrowUp');
  input.value = input.value + ' edited';
  check('an edited recall counts as a draft', hk('ArrowDown') === false && hk('ArrowUp') === false);

  console.log('per-session drafts');
  T.selectedId = 'D-A';
  T.applyChatView();
  input.value = 'half-typed for A';
  T.selectedId = 'D-B';
  T.applyChatView();
  check('switching sessions does not carry the draft over', input.value === '');
  input.value = 'for B';
  T.selectedId = 'D-A';
  T.applyChatView();
  check('switching back restores that session\'s draft', input.value === 'half-typed for A');
  T.selectedId = 'D-B';
  T.applyChatView();
  check('and the other one', input.value === 'for B');
  input.value = '';

  console.log('context meter (header Agent row)');
  const st6 = T.newChatState(SID);
  T.chatState = st6;
  const agentRow = doc.createElement('div');
  agentRow.className = 'meta';
  agentRow.textContent = 'Agent: Claude Code';
  let handoffOpened = false;
  agentRow.onclick = () => { handoffOpened = true; };
  agentRow.appendChild(T.chatHeaderMeter(SID));
  doc.body.appendChild(agentRow);
  const meta = doc.getElementById('chat-header-meter');
  check('meter slot sits in the Agent row', meta && meta.parentNode === agentRow);
  T.applyChatPage(st6, { supported: true, reset: true, cursor: 1, path: '/u.jsonl', terminal_id: 'TERM',
    agent_kind: 'claude-code', events: [] });
  check('meter hidden until usage arrives', meta.hidden);
  T.applyChatPage(st6, { supported: true, reset: false, cursor: 2, events: [],
    usage: { used_tokens: 84000, max_tokens: 1000000, model: 'claude-opus-5-5', max_source: 'model_table' } });
  check('meter shows model + percent', !meta.hidden && meta.querySelector('.chat-meta-model').textContent === 'Opus 5.5'
    && meta.querySelector('.chat-meter-pct').textContent === '8.4%');
  check('detail has used / max', meta.querySelector('.chat-meter-detail').textContent === '84k / 1M tokens');
  T.applyChatPage(st6, { supported: true, reset: false, cursor: 3, events: [{ kind: 'user', text: 'x' }] });
  check('a page without usage keeps the last value', meta.querySelector('.chat-meter-pct').textContent === '8.4%');
  T.applyChatPage(st6, { supported: true, reset: false, cursor: 4, events: [],
    usage: { used_tokens: 190000, max_tokens: 200000, model: 'claude-sonnet-4-5' } });
  check('red above 90%', meta.querySelector('.chat-meter').classList.contains('over'));
  check('detail shows used / max', meta.querySelector('.chat-meter-detail').textContent === '190k / 200k tokens');
  T.applyChatPage(st6, { supported: true, reset: false, cursor: 5, events: [],
    usage: { used_tokens: 51234, max_tokens: null, model: 'mystery-model' } });
  check('unknown window → token count, no percent', !meta.querySelector('.chat-meter-ring')
    && meta.querySelector('.chat-meter-pct').textContent === '51k tokens');
  meta.querySelector('.chat-meter').click();
  check('clicking the meter does not open the handoff menu', handoffOpened === false);
  T.applyChatPage(st6, { supported: true, reset: false, cursor: 6, events: [] });
  check('a tapped-open detail survives the next poll', meta.querySelector('.chat-meter').classList.contains('open'));
  meta.querySelector('.chat-meter').click();
  check('tapping again closes it', !meta.querySelector('.chat-meter').classList.contains('open'));
  // A header rebuilt for another session, or in terminal mode, shows no meter.
  const otherSlot = T.chatHeaderMeter('OTHER-SESSION');
  check('no meter for a session other than the chat one', otherSlot.hidden && !otherSlot.textContent);
  T.setChatViewActive(false);
  const term = T.chatHeaderMeter(SID);
  check('no meter in terminal mode', term.hidden && !term.textContent);
  T.setChatViewActive(true);
  const rebuilt = T.chatHeaderMeter(SID);
  check('a rebuilt header refills the meter from chat state', !rebuilt.hidden && rebuilt.textContent.includes('tokens'));
  check('model names', T.formatChatModel('claude-haiku-5-5') === 'Haiku 5.5' && T.formatChatModel('gpt-5.5') === 'gpt-5.5');
  check('token formatting', T.formatChatTokens(999) === '999' && T.formatChatTokens(1500) === '1.5k' && T.formatChatTokens(1000000) === '1M');

  console.log('file drop into the composer (#1390)');
  const uploads = [];
  window.fetch = async (url, opts) => {
    uploads.push({ url, name: decodeURIComponent(opts.headers['X-Filename']), type: opts.headers['Content-Type'] });
    const name = decodeURIComponent(opts.headers['X-Filename']);
    if (name === 'bad.bin') return { ok: false, json: async () => ({}) };
    return { ok: true, json: async () => ({ path: '/art/' + name }) };
  };
  const flush = async () => { for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r)); };
  const view = doc.getElementById('chat-view');
  const fileEvent = (type, files, types) => {
    const ev = new window.Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(ev, 'dataTransfer', { value: {
      files, types: types || (files.length ? ['Files'] : ['text/plain']), dropEffect: 'none' } });
    return ev;
  };
  const dropOn = (node, files, types) => { const ev = fileEvent('drop', files, types); node.dispatchEvent(ev); return ev; };
  const png = { name: 'shot.png', type: 'image/png' };
  const md = { name: 'notes.md', type: '' };

  T.selectedId = 'FD-1';
  T.applyChatView();
  T.applyChatPage(T.chatState, { supported: true, reset: true, cursor: 1, path: '/fd', terminal_id: 'T-FD',
    agent_kind: 'claude-code', events: [] });
  const over = fileEvent('dragover', []);
  over.dataTransfer.types = ['Files'];
  view.dispatchEvent(over);
  check('dragover accepts a file drag', over.defaultPrevented && over.dataTransfer.dropEffect === 'copy');
  check('dragover highlights the view', view.classList.contains('drop-target'));
  input.value = 'look at  please';
  input.setSelectionRange(8, 8);
  const ev1 = dropOn(log, [png, md]);
  check('a drop on the log is caught (no navigation)', ev1.defaultPrevented);
  check('drop clears the highlight', !view.classList.contains('drop-target'));
  await flush();
  check('each file is uploaded to the session artifacts', uploads.length === 2
    && uploads[0].url === '/artifacts/FD-1' && uploads[1].type === 'application/octet-stream');
  check('paths insert at the caret, not sent', input.value === 'look at /art/shot.png /art/notes.md please');
  check('caret lands after the inserted paths', input.selectionStart === 'look at /art/shot.png /art/notes.md'.length);
  check('the draft is updated', T.chatDrafts.get('FD-1') === input.value);

  input.value = 'see';
  input.setSelectionRange(3, 3);
  uploads.length = 0;
  dropOn(view, [{ name: 'bad.bin', type: '' }, { name: 'my file.txt', type: 'text/plain' }]);
  await flush();
  check('failed uploads are skipped; paths are shell-escaped, spaced, trailing space', input.value === 'see /art/my\\ file.txt ');

  const textDrop = dropOn(view, [], ['text/plain']);
  check('a non-file drop is left to the browser', !textDrop.defaultPrevented);

  // No target terminal: composer disabled → still swallowed, nothing uploaded.
  T.selectedId = 'FD-2';
  T.applyChatView();
  input.value = '';
  uploads.length = 0;
  const over2 = fileEvent('dragover', []);
  over2.dataTransfer.types = ['Files'];
  view.dispatchEvent(over2);
  check('no terminal: dragover still blocks navigation, shows no-drop', over2.defaultPrevented
    && over2.dataTransfer.dropEffect === 'none' && !view.classList.contains('drop-target'));
  const ev2 = dropOn(view, [png]);
  await flush();
  check('no terminal: drop is prevented but nothing uploads or inserts', ev2.defaultPrevented
    && uploads.length === 0 && input.value === '');

  // Paste a screenshot (image file, no text) → uploaded; a text paste stays native.
  T.applyChatPage(T.chatState, { supported: true, reset: true, cursor: 1, path: '/fd2', terminal_id: 'T-FD2',
    agent_kind: 'claude-code', events: [] });
  const pasteEvent = (files, types) => {
    const ev = new window.Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(ev, 'clipboardData', { value: { files, types } });
    return ev;
  };
  const p1 = pasteEvent([png], ['Files']);
  input.dispatchEvent(p1);
  await flush();
  check('pasting an image uploads and inserts it', p1.defaultPrevented && input.value === '/art/shot.png ');
  const p2 = pasteEvent([png], ['text/plain', 'Files']);
  input.dispatchEvent(p2);
  check('a paste with text stays native', !p2.defaultPrevented);

  // Session switched mid-upload: the path goes to the uploading session's draft.
  let release;
  window.fetch = () => new Promise((r) => { release = () => r({ ok: true, json: async () => ({ path: '/art/late.png' }) }); });
  input.value = 'mine';
  dropOn(view, [png]);
  await flush();
  T.selectedId = 'FD-3';
  T.applyChatView();
  release();
  await flush();
  check('a mid-upload switch does not insert into the other session', input.value === '');
  check('…the path lands in the uploading session\'s draft', T.chatDrafts.get('FD-2') === 'mine /art/late.png ');

  check('insertChatText: empty composer', T.insertChatText('', 0, 0, '/a').value === '/a ');
  check('insertChatText: after a newline adds no leading space', T.insertChatText('x\n', 2, 2, '/a').value === 'x\n/a ');
  check('insertChatText: replaces a selection', T.insertChatText('a SEL b', 2, 5, '/p').value === 'a /p b');
  delete window.fetch;

  console.log('chat view flag (crow ui set --chat-view)');
  const app = doc.getElementById('app');
  T.rpc = pending;
  T.selectedId = 'F-1';
  T.setChatViewActive(true);
  T.chatViewFlag = null; // config not loaded yet
  check('no toggle before the config says it is on', T.chatToggleControl() === null);
  T.applyChatView();
  check('a sticky Chat mode still applies while the config loads', app.classList.contains('chat-active'));
  T.chatViewFlag = true;
  const tog = T.chatToggleControl();
  check('toggle shows when enabled', tog && tog.textContent.includes('Chat') && tog.textContent.includes('Terminal'));
  T.chatViewFlag = false;
  check('no toggle when disabled', T.chatToggleControl() === null);
  T.onChatConfigLoaded();
  check('turning the flag off sends Chat back to the terminal', !app.classList.contains('chat-active'));
  T.applyChatView();
  check('a sticky Chat mode is ignored while disabled', !app.classList.contains('chat-active'));
  const slotOff = T.chatHeaderMeter('F-1');
  check('no header meter while disabled', slotOff.hidden && !slotOff.textContent);
  T.chatViewFlag = true;
  T.onChatConfigLoaded();
  check('turning it back on restores the sticky Chat mode', app.classList.contains('chat-active'));

  if (failed) { console.log(failed + ' failed'); process.exit(1); }
  console.log('all passed');
})();
