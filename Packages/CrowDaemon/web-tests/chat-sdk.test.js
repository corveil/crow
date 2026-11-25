const { JSDOM } = require('jsdom');
const vm = require('vm');
const fs = require('fs');
const { loadClientSource, WEB } = require('./load-client');

// Chat view, Agent SDK spike mode (chat-sdk.js, CROW-1524 / ADR 0033): the
// third toggle segment, streamed deltas, the approval and question cards
// answered through `sdk-chat-input`, and push ordering. Throwaway with the spike.
const epilogue = `
;globalThis.__t = {
  newChatState, ensureChatDom, buildChatMarkdown, chatToggleControl, sendChatMessage, renderChatStatus,
  probeSdkChat, applySdkChatPage, onSdkChatEvent, sdkAnswers, setSdkChatMode, sdkChatShown,
  get sdkChatEnabled(){ return sdkChatEnabled; },
  set sdkChatEnabled(v){ sdkChatEnabled = v; },
  set chatMd(v){ chatMd = v; },
  set selectedId(v){ selectedId = v; },
  set sessions(v){ sessions = v; },
  set chatState(v){ chatState = v; },
  get chatState(){ return chatState; },
  set chatViewFlag(v){ uiConfig.chatViewEnabled = v; },
  setChatViewActive,
  set rpc(v){ rpc = v; },
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
    'chat-menu', 'chat-meta', 'chat-header-meter'].includes(id)
    ? null : window.document.createElement('div'));

const ctx = dom.getInternalVMContext();
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

const SID = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';
const calls = [];
let reply = () => ({});
T.rpc = async (method, params) => { calls.push({ method, params }); return reply(method, params); };
const tick = () => new Promise((r) => setImmediate(r));
const labels = (wrap) => Array.from(wrap.querySelectorAll('.view-toggle-btn')).map((b) => b.textContent);

(async () => {
  T.chatViewFlag = true;
  T.sessions = [];
  T.selectedId = SID;
  T.chatMd = T.buildChatMarkdown();

  console.log('toggle');
  check('two segments before the probe', labels(T.chatToggleControl()).join('|') === 'Terminal|Chat');
  reply = (m) => (m === 'get-sdk-chat-events' ? { enabled: false } : {});
  await T.probeSdkChat();
  check('spike off: still two segments', T.sdkChatEnabled === false
    && labels(T.chatToggleControl()).join('|') === 'Terminal|Chat');
  check('probe asked without a session', calls[0].method === 'get-sdk-chat-events' && !calls[0].params.session_id);
  T.sdkChatEnabled = null;
  reply = (m) => (m === 'get-sdk-chat-events' ? { enabled: true } : {});
  await T.probeSdkChat();
  check('spike on: an SDK segment', labels(T.chatToggleControl()).join('|') === 'Terminal|Chat|SDK');
  T.setChatViewActive(true);
  T.setSdkChatMode(true);
  const active = T.chatToggleControl().querySelector('.view-toggle-btn.active');
  check('SDK segment is the active one', active && active.textContent === 'SDK' && T.sdkChatShown());

  console.log('events');
  T.ensureChatDom();
  const doc = window.document;
  const log = doc.getElementById('chat-log');
  const st = T.newChatState(SID, true);
  T.chatState = st;
  T.applySdkChatPage(st, { enabled: true, reset: true, cursor: 0, running: false, events: [] });
  check('empty conversation explains itself', !!log.querySelector('.sdk-chat-intro'));
  check('composer enabled without a terminal', doc.getElementById('chat-send').disabled === false);

  T.applySdkChatPage(st, {
    enabled: true, reset: true, cursor: 2, running: true, sdk_session_id: 'sdk-1',
    events: [
      { seq: 1, kind: 'user', text: 'paint it' },
      { seq: 2, kind: 'ready', sdk_session_id: 'sdk-1234567890', model: 'claude-opus-5-5',
        claude_code_version: '2.1.332', permission_mode: 'default' },
    ],
  });
  check('reset drops the intro', !log.querySelector('.sdk-chat-intro'));
  const ready = log.querySelector('.sdk-chat-ready');
  check('ready notice names the conversation', ready && ready.textContent.includes('sdk-1234')
    && ready.textContent.includes('claude-opus-5-5') && ready.title.includes('claude --resume sdk-1234567890'));

  // Streaming: deltas tagged with the current cursor grow one live bubble.
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'delta', seq: 2, text: 'Hel' } });
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'delta', seq: 2, text: 'lo **x**' } });
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'delta', seq: 1, text: 'stale' } });
  T.onSdkChatEvent({ session_id: 'other', event: { kind: 'delta', seq: 2, text: 'other session' } });
  const live = log.querySelector('.sdk-streaming');
  check('deltas stream into one bubble', live && live.textContent === 'Hello **x**');
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'assistant', seq: 3, text: 'Hello **x**' } });
  check('assistant replaces the streamed bubble', !log.querySelector('.sdk-streaming')
    && log.querySelectorAll('.chat-assistant').length === 1
    && log.querySelector('.chat-assistant strong').textContent === 'x');
  check('cursor advanced', st.cursor === 3);
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'assistant', seq: 3, text: 'dup' } });
  check('a duplicate push is ignored', log.querySelectorAll('.chat-assistant').length === 1);
  // A poll page that was in flight while seq 3 was pushed repeats it.
  T.applySdkChatPage(st, { enabled: true, reset: false, cursor: 3, running: true,
    events: [{ seq: 3, kind: 'assistant', text: 'Hello **x**' }] });
  check('an overlapping page is deduped', log.querySelectorAll('.chat-assistant').length === 1 && st.cursor === 3);

  console.log('approval card');
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'tool_call', seq: 4, tool_id: 't1', tool_name: 'Write', text: '/w/color.txt' } });
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'permission', seq: 5, request_id: 'r1', tool_id: 't1',
    tool_name: 'Write', text: '/w/color.txt' } });
  const approval = log.querySelector('.sdk-approval');
  check('approval card shows the tool and input', approval && approval.textContent.includes('Allow Write?')
    && approval.querySelector('.sdk-approval-input').textContent === '/w/color.txt');
  check('status waits on the operator', doc.getElementById('chat-status').classList.contains('waiting'));
  calls.length = 0;
  reply = () => ({ ok: true });
  approval.querySelector('.chat-question-submit').click();
  await tick();
  check('Allow sends respond', calls.length === 1 && calls[0].method === 'sdk-chat-input'
    && calls[0].params.op === 'respond' && calls[0].params.request_id === 'r1'
    && calls[0].params.behavior === 'allow' && calls[0].params.session_id === SID);
  check('card locks until resolved', approval.classList.contains('locked'));
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'resolved', seq: 6, request_id: 'r1', behavior: 'allow' } });
  check('resolved card reads Allowed', approval.classList.contains('answered')
    && approval.querySelector('.chat-question-state').textContent === 'Allowed');
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'tool_result', seq: 7, tool_id: 't1', text: 'File created' } });
  check('result nests in its tool row', log.querySelector('details.chat-tool .chat-tool-result').textContent === 'File created');

  console.log('question card');
  const questions = [
    { question: 'Which color?', header: 'Color', multi_select: false,
      options: [{ label: 'red', description: 'warm' }, { label: 'blue', description: 'cool' }] },
    { question: 'Extras?', header: 'Extras', multi_select: true,
      options: [{ label: 'stripes', description: '' }, { label: 'dots', description: '' }] },
  ];
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'tool_call', seq: 8, tool_id: 't2', tool_name: 'AskUserQuestion', text: 'Which color?', questions } });
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'question', seq: 9, request_id: 'r2', tool_id: 't2', questions } });
  const qcard = log.querySelector('.sdk-card:not(.sdk-approval)');
  check('AskUserQuestion draws a card, not a tool row', qcard
    && Array.from(log.querySelectorAll('.chat-tool-name')).every((n) => n.textContent !== 'AskUserQuestion'));
  const submit = qcard.querySelector('.chat-question-submit');
  check('Submit waits for every answer', submit.disabled === true);
  const radios = qcard.querySelectorAll('fieldset')[0].querySelectorAll('input[type=radio]');
  radios[1].checked = true; radios[1].onchange();
  const boxes = qcard.querySelectorAll('fieldset')[1].querySelectorAll('input[type=checkbox]');
  boxes[0].checked = true; boxes[0].onchange();
  boxes[1].checked = true; boxes[1].onchange();
  check('Submit enabled once answered', submit.disabled === false);
  calls.length = 0;
  submit.click();
  await tick();
  const sent = calls[0] && calls[0].params;
  check('answers map to labels', sent && sent.op === 'respond' && sent.request_id === 'r2' && sent.behavior === 'allow'
    && sent.answers['Which color?'] === 'blue' && sent.answers['Extras?'] === 'stripes, dots');
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'resolved', seq: 10, request_id: 'r2', behavior: 'allow',
    answers: { 'Which color?': 'blue', 'Extras?': 'stripes, dots' } } });
  check('answered card shows the answers', qcard.querySelector('.chat-question-state').textContent === 'Answered'
    && qcard.textContent.includes('→ blue') && qcard.textContent.includes('→ stripes, dots'));
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'tool_result', seq: 11, tool_id: 't2', text: 'answered' } });
  check('the question tool_result draws nothing', !Array.from(log.querySelectorAll('.chat-tool-result'))
    .some((n) => n.textContent === 'answered'));
  check('Other text joins the labels', T.sdkAnswers([questions[1]], [{ selected: [1], other: 'plaid' }])['Extras?'] === 'dots, plaid');

  console.log('turn end, gaps, stop');
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'turn_end', seq: 12, duration_ms: 4073, cost_usd: 0.2927 } });
  check('turn end shows duration and cost', log.querySelector('.chat-turn-end').textContent === 'Done · 4s · $0.293');
  calls.length = 0;
  reply = () => ({ enabled: true, cursor: 12, events: [] });
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'notice', seq: 15, text: 'skipped ahead' } });
  await tick();
  check('a gap refetches from the cursor', calls.length === 1 && calls[0].method === 'get-sdk-chat-events'
    && calls[0].params.cursor === 12 && !log.textContent.includes('skipped ahead'));

  T.onSdkChatEvent({ session_id: SID, event: { kind: 'permission', seq: 13, request_id: 'r3', tool_name: 'Bash', text: 'ls' } });
  T.onSdkChatEvent({ session_id: SID, event: { kind: 'stopped', seq: 14, status: 1 } });
  const r3 = Array.from(log.querySelectorAll('.sdk-approval')).pop();
  check('stop cancels a waiting card', r3.querySelector('.chat-question-state').textContent === 'Cancelled');
  check('stop is announced', log.textContent.includes('The SDK sidecar stopped (exit 1)'));
  check('idle after stop', !doc.getElementById('chat-status').classList.contains('busy') && st.sdkRunning === false);

  console.log('send');
  calls.length = 0;
  reply = () => ({ ok: true });
  const input = doc.getElementById('chat-input');
  input.value = 'next please';
  await T.sendChatMessage();
  check('composer sends to the sidecar, not the terminal', calls.length === 1
    && calls[0].method === 'sdk-chat-input' && calls[0].params.op === 'message'
    && calls[0].params.text === 'next please' && input.value === '');

  console.log(failed ? `\n${failed} FAILED` : '\nall passed');
  process.exit(failed ? 1 : 0);
})();
