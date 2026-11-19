// Spoken notifications (voice spike): drives the real emitEvent path in
// notifications.js against a fake speechSynthesis, and checks gating, template
// rendering, voice-replaces-chime, chime-before-voice, dedup and burst coalescing.
const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

const epilogue = `
;globalThis.__t = {
  setSessions(list) { sessions = list; },
  setSelected(id) { selectedId = id; },
  setNotifications(raw) { uiConfig.notifications = parseNotificationSettings(raw); },
  emit(ev, key, detail) { emitEvent(ev, key, detail); },
  flush() { flushVoiceQueue(); },
  render(tpl, ev, key, detail) { return renderVoiceTemplate(tpl, voiceContext(ev, key, detail)); },
  spyChime(fn) { crowSound.play = fn; },
  setDefaults(events) { setVoiceDefaults(events); },
};
`;

function load() {
  const dom = new JSDOM('<!doctype html><html><body></body></html>',
    { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' });
  const { window } = dom;
  const spoken = [];
  window.SpeechSynthesisUtterance = function (text) { this.text = text; };
  const synth = window.speechSynthesis = {
    paused: false,
    getVoices() {
      return [{ name: 'Samantha', lang: 'en-US', default: true }, { name: 'Fred', lang: 'en-US' }];
    },
    addEventListener() {},
    speak(u) { spoken.push(u); if (u.onend) u.onend(); },
    cancel() {},
    resume() {},
  };
  window.WebSocket = function () {
    return { send() {}, close() {},
      set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
  };
  window.setInterval = () => 0;
  window.setTimeout = () => 1; // timers never fire; the test flushes the voice queue itself
  window.requestAnimationFrame = () => 0;
  window.document.hasFocus = () => true;
  const realGet = window.document.getElementById.bind(window.document);
  window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');
  window.localStorage.clear();
  const ctx = dom.getInternalVMContext();
  try {
    vm.runInContext(loadClientSource() + epilogue, ctx, { filename: 'app.js' });
  } catch (e) {
    console.log('[load warn]', e.message);
  }
  const T = ctx.__t;
  if (!T) throw new Error('epilogue did not run');
  const chimes = [];
  T.spyChime((name) => chimes.push(name));
  T.setSessions([
    { id: 's1', name: 'crow-1078-fix-tab', repo: 'crow' },
    { id: 's2', name: 'api-12', repo: 'acme-api' },
    { id: 's3', name: 'web-3', repo: 'acme-web' },
  ]);
  T.setSelected('none');
  return { T, spoken, chimes, synth };
}

let pass = 0;
let fail = 0;
const check = (name, cond, extra) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (extra !== undefined ? ' — got ' + JSON.stringify(extra) : '')); }
};

console.log('voice: off by default');
{
  const { T, spoken, chimes } = load();
  T.setNotifications({});
  T.emit('agentWaiting', 's1');
  T.flush();
  check('nothing spoken when voiceEnabled is absent', spoken.length === 0, spoken.map((u) => u.text));
  check('the chime still plays', chimes.length === 1, chimes);
}

console.log('voice: speaks the default template and replaces the chime');
{
  const { T, spoken, chimes } = load();
  T.setNotifications({ voiceEnabled: true, voiceName: 'Fred', voiceRate: 1.5, voiceVolume: 0.4 });
  T.emit('agentWaiting', 's1');
  T.flush();
  check('one utterance', spoken.length === 1, spoken.length);
  check('session slug read as words', spoken[0] && spoken[0].text === 'crow 1078 fix tab needs you', spoken[0] && spoken[0].text);
  check('configured voice picked', spoken[0] && spoken[0].voice && spoken[0].voice.name === 'Fred');
  check('rate and volume applied', spoken[0] && spoken[0].rate === 1.5 && spoken[0].volume === 0.4);
  check('chime suppressed (voice replaces it)', chimes.length === 0, chimes);
}

console.log('voice: chimeBeforeVoice keeps the chime');
{
  const { T, spoken, chimes } = load();
  T.setNotifications({ voiceEnabled: true, chimeBeforeVoice: true });
  T.emit('taskComplete', 's2');
  T.flush();
  check('chime played', chimes.length === 1, chimes);
  check('then spoken', spoken.length === 1 && spoken[0].text === 'api 12 is done', spoken.map((u) => u.text));
}

console.log('voice: per-event override and gating');
{
  const { T, spoken, chimes } = load();
  T.setNotifications({
    voiceEnabled: true,
    eventSettings: [
      'taskComplete', { soundName: 'Glass', voiceEnabled: false },
      'checksFailing', { soundName: 'Sosumi', voiceTemplate: 'Build broke on {repo}, PR {pr}' },
    ],
  });
  T.emit('taskComplete', 's1');
  T.emit('checksFailing', 's3', { title: '', body: 'PR #42 failing' });
  T.emit('configReloaded', 'config'); // default voice-off event
  T.flush();
  check('per-event voiceEnabled:false silences speech', !spoken.some((u) => /done/.test(u.text)));
  check('custom template rendered', spoken.length === 1 && spoken[0].text === 'Build broke on acme web, PR 42', spoken.map((u) => u.text));
  check('voice-off events still chime', chimes.length === 2, chimes);
}

console.log('voice: globalMute and focus rule');
{
  const { T, spoken } = load();
  T.setNotifications({ voiceEnabled: true, globalMute: true });
  T.emit('agentWaiting', 's1');
  T.flush();
  check('globalMute silences voice', spoken.length === 0);
  T.setNotifications({ voiceEnabled: true });
  T.setSelected('s1');
  T.emit('agentWaiting', 's1');
  T.flush();
  check('focused+selected session is not announced', spoken.length === 0, spoken.map((u) => u.text));
}

console.log('voice: dedup and burst coalescing');
{
  const { T, spoken } = load();
  T.setNotifications({ voiceEnabled: true });
  T.emit('taskComplete', 's1');
  T.emit('taskComplete', 's1'); // within 2s — deduped
  T.flush();
  check('2s dedup per (key,event)', spoken.length === 1, spoken.map((u) => u.text));
  spoken.length = 0;
  T.emit('agentWaiting', 's1');
  T.emit('agentWaiting', 's2');
  T.emit('agentWaiting', 's3');
  T.flush();
  check('3+ of one event become a count', spoken.length === 1 && spoken[0].text === '3 sessions need you', spoken.map((u) => u.text));
}

console.log('voice: daemon-supplied defaults win');
{
  const { T, spoken } = load();
  T.setDefaults({ taskComplete: { default_voice_enabled: true, default_voice_template: '{session} finished' } });
  T.setNotifications({ voiceEnabled: true });
  T.emit('taskComplete', 's2');
  T.flush();
  check('server default template used', spoken[0] && spoken[0].text === 'api 12 finished', spoken.map((u) => u.text));
  check('automation title is spoken readably',
    T.render('{title}', 'autoWorkspaceCreated', 'https://x/1', { title: 'Auto-creating workspace — corveil/crow', body: '#1: x' })
      === 'Auto creating workspace, corveil crow');
}

console.log('voice: a refused utterance falls back to the chime');
{
  const { T, spoken, chimes, synth } = load();
  synth.speak = (u) => { spoken.push(u); if (u.onerror) u.onerror({ error: 'not-allowed' }); };
  T.setNotifications({ voiceEnabled: true });
  T.emit('agentWaiting', 's1');
  T.flush();
  check('chime played instead of silence', chimes.length === 1 && chimes[0] === 'Funk', chimes);
  T.emit('taskComplete', 's2');
  T.flush();
  check('while blocked, later events chime without trying to speak', spoken.length === 1 && chimes.length === 2, { spoken: spoken.length, chimes });
}

console.log('voice: a line refused by the backlog cap still chimes');
{
  const { T, spoken, chimes, synth } = load();
  synth.speak = (u) => { spoken.push(u); }; // never ends — utterances stay in flight
  T.setNotifications({ voiceEnabled: true });
  // Five different voice-on events in one flush = five lines; the cap is four.
  T.emit('agentWaiting', 's1');
  T.emit('taskComplete', 's2');
  T.emit('changesRequested', 's3');
  T.emit('checksFailing', 's1');
  T.emit('reviewRequested', 'r1');
  T.flush();
  check('four lines spoken', spoken.length === 4, spoken.map((u) => u.text));
  check('the refused fifth event chimes instead of going silent',
    chimes.length === 1 && chimes[0] === 'Glass', chimes);
}

// Settings: the voice list arrives late (voiceschanged). The one-shot repaint
// must not resurrect a Settings modal the user already closed (review of #1473).
async function settingsVoicesScenario() {
  console.log('voice: late voice list does not reopen a closed Settings');
  const { loadSettingsSource } = require('./load-client');
  const dom = new JSDOM(`<!doctype html><html><body><div id="app"><aside id="sidebar"></aside>
    <main id="detail"><header id="detail-header"></header><div id="tabbar"></div>
    <div id="board"></div><div id="detail-empty"><div class="empty-msg"></div></div></main></div></body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' });
  const { window } = dom;
  let voices = [];
  const changed = [];
  window.SpeechSynthesisUtterance = function (t) { this.text = t; };
  window.speechSynthesis = {
    getVoices: () => voices,
    addEventListener(type, fn) { if (type === 'voiceschanged') changed.push(fn); },
    speak() {}, cancel() {}, resume() {},
  };
  window.WebSocket = function () {
    return { send() {}, close() {}, set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
  };
  window.setInterval = () => 0;
  window.setTimeout = () => 0;
  window.requestAnimationFrame = () => 0;
  window.fetch = () => Promise.resolve({ ok: false, json: () => Promise.reject(new Error('n/a')) });
  const realGet = window.document.getElementById.bind(window.document);
  window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');
  const ctx = dom.getInternalVMContext();
  try {
    vm.runInContext(loadClientSource() + ';globalThis.__s={setRpc(f){rpc=f;}};' + loadSettingsSource(), ctx);
  } catch (e) { console.log('[load warn]', e.message); }
  ctx.__s.setRpc((m) => (m === 'get-config'
    ? Promise.resolve({ config: JSON.stringify({ notifications: { voiceEnabled: true } }), dev_root: '/d' })
    : m === 'list-agents' ? Promise.resolve({ agents: [] })
      : m === 'notifications-get' ? Promise.resolve({ notifications: { available_sounds: ['Glass'], custom_sounds: [] } })
        : Promise.reject(new Error('not stubbed: ' + m))));
  const drain = async () => { for (let i = 0; i < 100; i++) await Promise.resolve(); };
  const fireVoices = () => {
    voices = [{ name: 'Samantha', lang: 'en-US', default: true }];
    for (const fn of changed) fn();
  };
  const voiceOptions = () => [...window.document.querySelectorAll('option')].filter((o) => o.value === 'Samantha').length;

  await window.openSettings('notifications');
  await drain();
  check('Settings opened with an empty voice list', window.settingsIsOpen() && voiceOptions() === 0);
  await window.closeSettings(true);
  check('Settings closed', !window.settingsIsOpen());
  fireVoices();
  await drain();
  check('voiceschanged after close leaves Settings closed', !window.settingsIsOpen());

  await window.openSettings('notifications');
  await drain();
  check('reopening shows the voices that arrived meanwhile', window.settingsIsOpen() && voiceOptions() === 1);
  voices = voices.concat([{ name: 'Fred', lang: 'en-US' }]);
  for (const fn of changed) fn();
  await drain();
  check('a later voice-list change repaints the open modal',
    [...window.document.querySelectorAll('option')].some((o) => o.value === 'Fred'));
}

settingsVoicesScenario().catch((e) => { fail++; console.log('  ✗ settings scenario threw', e); }).then(() => {
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
});
