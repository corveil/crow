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
  updateChatMenu, chatMenuKeydown, filterChatCommands, formatChatModel, formatChatTokens,
  set chatMd(v){ chatMd = v; },
  set selectedId(v){ selectedId = v; },
  set chatState(v){ chatState = v; },
  set rpc(v){ rpc = v; },
};
`;

const dom = new JSDOM(
  `<!doctype html><html><body>
     <div id="app"></div><div id="sidebar"></div>
     <main id="detail"><header id="detail-header"></header><div id="tabbar"></div>
     <div id="terminal-wrap"></div></main>
     <div id="board"></div>
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
  || (['chat-view', 'chat-log', 'chat-status', 'chat-driver', 'chat-send', 'chat-input', 'chat-jump',
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

console.log('headless driver');
const calls = [];
const RUNNING = { supported: true, reset: false, cursor: 1, terminal_id: 'TERM', driver_enabled: true,
  driver: { running: true, conversation_id: 'c1', pending: [] }, events: [] };
T.rpc = async (m, p) => { calls.push([m, p]); return m === 'get-session-transcript' ? RUNNING : {}; };
const st3 = T.newChatState(SID);
T.chatState = st3;
T.applyChatPage(st3, { supported: true, reset: true, cursor: 1, path: '/d.jsonl', terminal_id: 'TERM',
  driver_enabled: true, driver: null, events: [] });
const startBtn = doc.querySelector('#chat-driver .chat-driver-btn');
check('offers Start headless when enabled', startBtn && startBtn.textContent === 'Start headless');
T.applyChatPage(st3, { supported: true, reset: false, cursor: 1, terminal_id: 'TERM', driver_enabled: true,
  driver: { running: true, conversation_id: 'c1',
    pending: [{ request_id: 'req-1', tool_name: 'Write', summary: '/w/a.txt' }] },
  events: [] });
const card = doc.querySelector('.chat-permission');
check('permission card shows the tool', card && card.textContent.includes('Write') && card.textContent.includes('/w/a.txt'));
check('status says waiting on approval', doc.getElementById('chat-status').textContent.includes('approval'));
card.querySelector('.chat-driver-btn.primary').click();
check('Allow answers that request', calls.some(([m, p]) => m === 'chat-driver-permission'
  && p.request_id === 'req-1' && p.allow === true && p.session_id === SID));
(async () => {
  calls.length = 0;
  st3.driverBusy = false;
  doc.getElementById('chat-input').value = 'hello';
  await T.sendChatMessage();
  await new Promise((r) => setImmediate(r));
  const sends = calls.filter(([m]) => m === 'chat-driver-send' || m === 'send');
  check('composer routes to the driver, not the TUI', sends.length === 1 && sends[0][0] === 'chat-driver-send'
    && sends[0][1].text === 'hello');

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

  console.log('context meter');
  const meta = doc.getElementById('chat-meta');
  const st6 = T.newChatState(SID);
  T.chatState = st6;
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
    usage: { used_tokens: 190000, max_tokens: 200000, model: 'claude-sonnet-4-5', cost_usd: 1.234 } });
  check('red above 90%', meta.querySelector('.chat-meter').classList.contains('over'));
  check('driver cost shows in the detail', meta.querySelector('.chat-meter-detail').textContent === '190k / 200k tokens · $1.23');
  T.applyChatPage(st6, { supported: true, reset: false, cursor: 5, events: [],
    usage: { used_tokens: 51234, max_tokens: null, model: 'mystery-model' } });
  check('unknown window → token count, no percent', !meta.querySelector('.chat-meter-ring')
    && meta.querySelector('.chat-meter-pct').textContent === '51k tokens');
  meta.querySelector('.chat-meter').click();
  T.applyChatPage(st6, { supported: true, reset: false, cursor: 6, events: [] });
  check('a tapped-open detail survives the next poll', meta.querySelector('.chat-meter').classList.contains('open'));
  meta.querySelector('.chat-meter').click();
  check('tapping again closes it', !meta.querySelector('.chat-meter').classList.contains('open'));
  check('model names', T.formatChatModel('claude-haiku-5-5') === 'Haiku 5.5' && T.formatChatModel('gpt-5.5') === 'gpt-5.5');
  check('token formatting', T.formatChatTokens(999) === '999' && T.formatChatTokens(1500) === '1.5k' && T.formatChatTokens(1000000) === '1M');

  if (failed) { console.log(failed + ' failed'); process.exit(1); }
  console.log('all passed');
})();
