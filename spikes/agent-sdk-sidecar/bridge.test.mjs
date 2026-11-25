// node --test — the bridge against a fake `query()`; no network, no CLI.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createBridge, createInputQueue, toolInputSummary, normalizeQuestions, validateAnswers, contentText,
  sidecarOptions, INHERITED_SESSION_VARS,
} from './bridge.mjs';

const QUESTION_INPUT = {
  questions: [{
    question: 'Which color?',
    header: 'Color',
    multiSelect: false,
    options: [{ label: 'Red', description: 'warm' }, { label: 'Blue', description: 'cool' }],
  }],
};

// A scripted turn: init, streamed text, a Bash call that needs approval, an
// AskUserQuestion, then the result. `seen` records what canUseTool returned.
function fakeQuery(seen) {
  return ({ prompt, options }) => {
    let interrupted = false;
    const gen = (async function* () {
      for await (const userMsg of prompt) {
        seen.prompts.push(userMsg.message.content);
        yield { type: 'system', subtype: 'init', session_id: 'sdk-1', model: 'claude-opus-5-5',
          cwd: options.cwd, permissionMode: options.permissionMode, claude_code_version: '2.1.332' };
        yield { type: 'user', message: { role: 'user', content: userMsg.message.content } }; // echo: ignored
        yield { type: 'stream_event', parent_tool_use_id: null,
          event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Hel' } } };
        yield { type: 'stream_event', parent_tool_use_id: null,
          event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'lo' } } };
        yield { type: 'stream_event', parent_tool_use_id: null,
          event: { type: 'content_block_delta', index: 1, delta: { type: 'thinking_delta', thinking: 'x' } } };
        yield { type: 'assistant', parent_tool_use_id: null, message: { content: [{ type: 'text', text: 'Hello' }] } };

        const bash = { command: 'rm -rf build' };
        yield { type: 'assistant', parent_tool_use_id: null,
          message: { content: [{ type: 'tool_use', id: 'tu1', name: 'Bash', input: bash }] } };
        seen.results.push(await options.canUseTool('Bash', bash, { signal: new AbortController().signal, toolUseID: 'tu1' }));
        yield { type: 'user', parent_tool_use_id: null,
          message: { content: [{ type: 'tool_result', tool_use_id: 'tu1', content: [{ type: 'text', text: 'ok' }] }] } };

        yield { type: 'assistant', parent_tool_use_id: null,
          message: { content: [{ type: 'tool_use', id: 'tu2', name: 'AskUserQuestion', input: QUESTION_INPUT }] } };
        seen.results.push(await options.canUseTool('AskUserQuestion', QUESTION_INPUT,
          { signal: new AbortController().signal, toolUseID: 'tu2' }));

        yield { type: 'result', subtype: 'success', is_error: false, duration_ms: 1234, total_cost_usd: 0.01 };
        if (interrupted) return;
      }
    })();
    gen.interrupt = async () => { interrupted = true; };
    gen.close = () => {};
    return gen;
  };
}

// Wait until `pred(events)` holds (the fake runs on microtasks/ticks).
async function until(events, pred) {
  for (let i = 0; i < 200; i++) {
    if (pred(events)) return;
    await new Promise((r) => setTimeout(r, 1));
  }
  assert.fail('timed out; events: ' + JSON.stringify(events.map((e) => e.kind)));
}

test('a turn streams, asks for approval, asks a question, and ends', async () => {
  const events = [];
  const seen = { prompts: [], results: [] };
  const bridge = createBridge({ query: fakeQuery(seen), emit: (e) => events.push(e), options: { cwd: '/w', permissionMode: 'default' } });

  assert.equal(bridge.handle({ op: 'message', text: 'hi' }), null);
  await until(events, (es) => es.some((e) => e.kind === 'permission'));

  const kinds = events.map((e) => e.kind);
  assert.deepEqual(kinds, ['user', 'ready', 'delta', 'delta', 'assistant', 'tool_call', 'permission']);
  assert.equal(events[1].sdk_session_id, 'sdk-1');
  assert.equal(events[1].permission_mode, 'default');
  assert.deepEqual(events.filter((e) => e.kind === 'delta').map((e) => e.text), ['Hel', 'lo']);
  const perm = events[6];
  assert.equal(perm.tool_name, 'Bash');
  assert.equal(perm.tool_id, 'tu1');
  assert.equal(perm.text, 'rm -rf build');
  assert.equal(bridge.pendingCount, 1);

  assert.equal(bridge.handle({ op: 'respond', request_id: perm.request_id, behavior: 'allow' }), null);
  await until(events, (es) => es.some((e) => e.kind === 'question'));
  assert.deepEqual(seen.results[0], { behavior: 'allow', updatedInput: { command: 'rm -rf build' } });

  const q = events.find((e) => e.kind === 'question');
  assert.equal(q.tool_id, 'tu2');
  assert.deepEqual(q.questions[0].options.map((o) => o.label), ['Red', 'Blue']);
  // The AskUserQuestion tool_call carries the questions too, like the transcript.
  const call = events.find((e) => e.kind === 'tool_call' && e.tool_name === 'AskUserQuestion');
  assert.equal(call.questions[0].question, 'Which color?');

  assert.match(bridge.handle({ op: 'respond', request_id: q.request_id, behavior: 'allow', answers: {} }), /unanswered/);
  assert.equal(bridge.handle({ op: 'respond', request_id: q.request_id, behavior: 'allow',
    answers: { 'Which color?': 'Blue' } }), null);
  await until(events, (es) => es.some((e) => e.kind === 'turn_end'));

  assert.deepEqual(seen.results[1], {
    behavior: 'allow',
    updatedInput: Object.assign({}, QUESTION_INPUT, { answers: { 'Which color?': 'Blue' } }),
  });
  const resolved = events.filter((e) => e.kind === 'resolved');
  assert.deepEqual(resolved.map((e) => e.behavior), ['allow', 'allow']);
  assert.deepEqual(resolved[1].answers, { 'Which color?': 'Blue' });
  const end = events.find((e) => e.kind === 'turn_end');
  assert.equal(end.duration_ms, 1234);
  assert.equal(end.cost_usd, 0.01);
  assert.equal(events.find((e) => e.kind === 'tool_result').text, 'ok');
  assert.equal(bridge.pendingCount, 0);
  bridge.close();
});

test('deny reaches the SDK with a message, and a stale request id is an error', async () => {
  const events = [];
  const seen = { prompts: [], results: [] };
  const bridge = createBridge({ query: fakeQuery(seen), emit: (e) => events.push(e) });
  bridge.handle({ op: 'message', text: 'go' });
  await until(events, (es) => es.some((e) => e.kind === 'permission'));
  const perm = events.find((e) => e.kind === 'permission');
  assert.equal(bridge.handle({ op: 'respond', request_id: perm.request_id, behavior: 'deny', message: 'not that' }), null);
  await until(events, (es) => es.some((e) => e.kind === 'question'));
  assert.deepEqual(seen.results[0], { behavior: 'deny', message: 'not that' });
  assert.match(bridge.handle({ op: 'respond', request_id: perm.request_id, behavior: 'allow' }), /no pending request/);
  const q = events.find((e) => e.kind === 'question');
  bridge.handle({ op: 'respond', request_id: q.request_id, behavior: 'deny' });
  await until(events, (es) => es.some((e) => e.kind === 'turn_end'));
  assert.deepEqual(seen.results[1], { behavior: 'deny', message: 'The user declined to answer.' });
  bridge.close();
});

test('bad commands are refused without starting a turn', () => {
  const bridge = createBridge({ query: () => { throw new Error('must not start'); }, emit: () => {} });
  assert.match(bridge.handle({ op: 'message', text: '   ' }), /text required/);
  assert.match(bridge.handle({ op: 'bogus' }), /unknown op/);
  assert.match(bridge.handle(null), /object/);
  assert.equal(bridge.done, null);
});

test('an aborted call is resolved as cancelled', async () => {
  const events = [];
  const ac = new AbortController();
  let result = null;
  const query = ({ prompt, options }) => (async function* () {
    for await (const _ of prompt) {
      result = await options.canUseTool('Write', { file_path: '/w/a' }, { signal: ac.signal, toolUseID: 't' });
      return;
    }
  })();
  const bridge = createBridge({ query, emit: (e) => events.push(e) });
  bridge.handle({ op: 'message', text: 'x' });
  await until(events, (es) => es.some((e) => e.kind === 'permission'));
  ac.abort();
  await until(events, (es) => es.some((e) => e.kind === 'exit'));
  assert.deepEqual(result, { behavior: 'deny', message: 'Interrupted.' });
  assert.equal(events.find((e) => e.kind === 'resolved').behavior, 'cancelled');
});

test('a query that throws reports an error, and the next message resumes the session', async () => {
  const events = [];
  const starts = [];
  const query = ({ prompt, options }) => {
    starts.push(options.resume || null);
    return (async function* () {
      for await (const _ of prompt) {
        yield { type: 'system', subtype: 'init', session_id: 'sdk-9' };
        throw new Error('overloaded');
      }
    })();
  };
  const bridge = createBridge({ query, emit: (e) => events.push(e) });
  bridge.handle({ op: 'message', text: 'x' });
  await until(events, (es) => es.some((e) => e.kind === 'exit'));
  assert.deepEqual(events.slice(-2), [{ kind: 'error', text: 'overloaded' }, { kind: 'exit', reason: 'error' }]);
  await until(events, () => bridge.done === null);

  bridge.handle({ op: 'message', text: 'again' });
  await until(events, (es) => es.filter((e) => e.kind === 'exit').length === 2);
  assert.deepEqual(starts, [null, 'sdk-9']);
});

test('helpers match the transcript reader', async () => {
  assert.equal(toolInputSummary({ command: 'ls -la', description: 'x' }), 'ls -la');
  assert.equal(toolInputSummary({ file_path: '/a/b' }), '/a/b');
  assert.equal(toolInputSummary({ z: 1, a: 2 }), '{"a":2,"z":1}');
  assert.equal(toolInputSummary('line one\nline two'), 'line one');
  assert.equal(toolInputSummary({ command: 'x'.repeat(400) }).length, 301);
  assert.equal(contentText([{ type: 'text', text: 'a' }, { type: 'image' }]), 'a\n[image]');
  assert.deepEqual(normalizeQuestions(QUESTION_INPUT)[0].multi_select, false);
  assert.equal(validateAnswers(normalizeQuestions(QUESTION_INPUT), { 'Which color?': 'Red, Blue' }), null);
  assert.match(validateAnswers([], []), /object/);

  const q = createInputQueue();
  q.push(1); q.push(2); q.close(); q.push(3);
  const got = [];
  for await (const v of q) got.push(v);
  assert.deepEqual(got, [1, 2]);
});

test('the options match the terminal agent but run no hooks', () => {
  const env = { PATH: '/bin', ANTHROPIC_BASE_URL: 'https://gw', CLAUDE_CODE_SESSION_ID: 'parent', CLAUDECODE: '1' };
  const o = sidecarOptions({ cwd: '/w', claude: '/bin/claude', resume: 'sdk-1', env });
  assert.deepEqual(o.systemPrompt, { type: 'preset', preset: 'claude_code' });
  assert.deepEqual(o.settingSources, ['user', 'project', 'local']);
  // Crow's hooks (in settings.local.json) would repoint the session's
  // harnessConversationID at this conversation: off for the SDK child.
  assert.deepEqual(o.settings, { disableAllHooks: true });
  assert.equal(o.permissionMode, 'default');
  assert.equal(o.pathToClaudeCodeExecutable, '/bin/claude');
  assert.equal(o.resume, 'sdk-1');
  assert.equal(o.env.ANTHROPIC_BASE_URL, 'https://gw');
  for (const k of INHERITED_SESSION_VARS) assert.equal(k in o.env, false);
  assert.equal(env.CLAUDECODE, '1'); // the parent env is not mutated
  const bare = sidecarOptions({ cwd: '/w', env: {} });
  assert.equal('pathToClaudeCodeExecutable' in bare, false);
  assert.equal('resume' in bare, false);
});

test('request ids never repeat across sidecars', async () => {
  const ids = [];
  for (let i = 0; i < 2; i++) {
    const events = [];
    const query = ({ prompt, options }) => (async function* () {
      for await (const _ of prompt) {
        options.canUseTool('Write', { file_path: '/a' }, { signal: new AbortController().signal, toolUseID: 't' });
        yield { type: 'system', subtype: 'init', session_id: 's' };
        await new Promise(() => {}); // park, like a turn waiting on the operator
      }
    })();
    const bridge = createBridge({ query, emit: (e) => events.push(e) });
    bridge.handle({ op: 'message', text: 'x' });
    await until(events, (es) => es.some((e) => e.kind === 'permission'));
    ids.push(events.find((e) => e.kind === 'permission').request_id);
  }
  assert.notEqual(ids[0], ids[1]);
  assert.match(ids[0], /^[0-9a-f]{8}-1$/);
});
