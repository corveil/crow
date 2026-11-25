// THROWAWAY SPIKE (CROW-1524, ADR 0033). Not product code.
//
// The bridge between one Claude Agent SDK `query()` and crowd. It owns the
// three things a terminal can't give Crow:
//
//   1. Streaming: `stream_event` text deltas become `delta` events.
//   2. Tool approval: `canUseTool` becomes a `permission` event, and the call
//      waits until crowd answers it (`respond`).
//   3. Questions: an `AskUserQuestion` call reaches `canUseTool` too; it becomes
//      a `question` event and the answers go back as `updatedInput.answers`.
//
// Everything else is translated into Web Chat's existing event vocabulary
// (`user`, `assistant`, `tool_call`, `tool_result`, `turn_end`, `notice`), so
// crowd relays lines without knowing a single SDK message type. SDK churn stays
// in this file.
//
// `query` is injected so the tests can drive the bridge with a fake.

import { randomUUID } from 'node:crypto';

const MAX_TOOL_INPUT = 300;   // ChatTranscript.maxToolInputChars
const MAX_TOOL_RESULT = 2000; // ChatTranscript.maxToolResultChars

// crowd may itself run under a Claude Code session (a developer running a dev
// build from an agent). These name *that* session; the child CLI must not
// think it is nested inside it.
export const INHERITED_SESSION_VARS = [
  'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_CHILD_NOTES_DIR', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
  'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_EXECPATH', 'CLAUDE_PID',
];

/**
 * The `query()` options for one Crow session (the bridge adds `canUseTool`
 * and `includePartialMessages`).
 *
 * - The terminal agent's prompt, settings, CLAUDE.md and skills: the
 *   `claude_code` preset and the user/project/local sources. `local` is what
 *   carries Crow's gateway env (`env` in .claude/settings.local.json).
 * - **No hooks.** `local` also carries Crow's hooks, which name the Crow
 *   session; `hook-event` would record this SDK conversation's id as the
 *   session's `harnessConversationID` (latest wins) and repoint Chat, Manager
 *   resume and handoff at it. `disableAllHooks` in the flag-settings tier (the
 *   CLI's `--settings`, above local) turns off user, project and local hooks
 *   for this run only. Managed-policy hooks still run.
 * - `permissionMode: 'default'`: omitted, the SDK starts in the settings'
 *   `defaultMode` or `auto`, which would approve most calls without asking.
 * - The operator's own `claude` instead of the SDK's ~384 MB per-platform
 *   binary (the SDK is installed with --omit=optional).
 */
export function sidecarOptions({ cwd, claude, resume, model, env }) {
  const childEnv = { ...env };
  for (const k of INHERITED_SESSION_VARS) delete childEnv[k];
  const options = {
    cwd,
    env: childEnv,
    systemPrompt: { type: 'preset', preset: 'claude_code' },
    settingSources: ['user', 'project', 'local'],
    settings: { disableAllHooks: true },
    permissionMode: 'default',
  };
  if (claude) options.pathToClaudeCodeExecutable = claude;
  if (resume) options.resume = resume;
  if (model) options.model = model;
  return options;
}

/** A single-consumer async queue: the SDK's streaming-input prompt. */
export function createInputQueue() {
  const items = [];
  let wake = null;
  let closed = false;
  return {
    push(item) {
      if (closed) return;
      items.push(item);
      if (wake) { wake(); wake = null; }
    },
    close() {
      closed = true;
      if (wake) { wake(); wake = null; }
    },
    async *[Symbol.asyncIterator]() {
      for (;;) {
        while (items.length) yield items.shift();
        if (closed) return;
        await new Promise((resolve) => { wake = resolve; });
      }
    },
  };
}

export function clip(s, limit) {
  const str = String(s == null ? '' : s);
  return str.length > limit ? str.slice(0, limit) + '…' : str;
}

function firstLine(s) {
  const t = String(s).trim();
  const i = t.indexOf('\n');
  return i < 0 ? t : t.slice(0, i);
}

/** One-line summary of a tool's input — mirrors ChatTranscript.toolInputSummary. */
export function toolInputSummary(input) {
  if (typeof input === 'string') return clip(firstLine(input), MAX_TOOL_INPUT);
  if (!input || typeof input !== 'object') return '';
  const preferred = ['command', 'cmd', 'file_path', 'path', 'pattern', 'url', 'query',
    'description', 'prompt', 'skill', 'notebook_path'];
  for (const key of preferred) {
    const v = input[key];
    if (typeof v === 'string' && v) return clip(v, MAX_TOOL_INPUT);
    if (Array.isArray(v) && v.every((x) => typeof x === 'string')) return clip(v.join(' '), MAX_TOOL_INPUT);
  }
  try {
    const sorted = Object.keys(input).sort().reduce((o, k) => { o[k] = input[k]; return o; }, {});
    return clip(JSON.stringify(sorted), MAX_TOOL_INPUT);
  } catch (_) {
    return '';
  }
}

/** Tool-result `content` is a string or an array of `{type: text|image}`. */
export function contentText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.map((b) => {
    if (b && typeof b.text === 'string') return b.text;
    if (b && b.type === 'image') return '[image]';
    return '';
  }).filter(Boolean).join('\n');
}

/** AskUserQuestion input → Web Chat's question shape (ChatQuestion). */
export function normalizeQuestions(input) {
  const qs = input && Array.isArray(input.questions) ? input.questions : [];
  return qs.map((q) => ({
    question: String(q.question || ''),
    header: String(q.header || ''),
    multi_select: !!q.multiSelect,
    options: (Array.isArray(q.options) ? q.options : []).map((o) => ({
      label: String((o && o.label) || ''),
      description: String((o && o.description) || ''),
    })),
  }));
}

/**
 * Check a `respond` for a question: every question answered, keyed by its
 * text. A value is a label, several labels joined with ", ", or free text
 * (the card's Other field) — the SDK takes all three.
 */
export function validateAnswers(questions, answers) {
  if (!answers || typeof answers !== 'object' || Array.isArray(answers)) return 'answers must be an object';
  for (const q of questions) {
    const v = answers[q.question];
    if (typeof v !== 'string' || !v.trim()) return 'unanswered: ' + q.question;
  }
  return null;
}

/**
 * @param {object} deps
 * @param {Function} deps.query  The SDK's `query` (or a fake).
 * @param {Function} deps.emit   Called with one plain event object per line.
 * @param {object}   deps.options  `query` options (cwd, resume, …) — the
 *   bridge adds `canUseTool`, `includePartialMessages` and the input queue.
 */
export function createBridge({ query, emit, options = {} }) {
  // The live query's prompt. A query ends only on an error or close; the next
  // message then starts a new one that resumes the same SDK session.
  let input = null;
  // request_id → { resolve, kind, input, questions }
  const pending = new Map();
  // Request ids are unique per bridge, so an answer meant for a sidecar that
  // has since been replaced can never match its successor's request.
  const requestPrefix = randomUUID().slice(0, 8);
  let nextRequest = 1;
  let q = null;
  let turnStartedAt = null;
  let sessionId = null;
  let running = null;

  function resolvePending(requestId, result, event) {
    const p = pending.get(requestId);
    if (!p) return false;
    pending.delete(requestId);
    emit(Object.assign({ kind: 'resolved', request_id: requestId }, event));
    p.resolve(result);
    return true;
  }

  async function canUseTool(toolName, toolInput, opts = {}) {
    const requestId = requestPrefix + '-' + (nextRequest++);
    const toolId = opts.toolUseID || null;
    return new Promise((resolve) => {
      if (toolName === 'AskUserQuestion') {
        const questions = normalizeQuestions(toolInput);
        pending.set(requestId, { resolve, kind: 'question', input: toolInput, questions });
        emit({ kind: 'question', request_id: requestId, tool_id: toolId, questions });
      } else {
        pending.set(requestId, { resolve, kind: 'permission', input: toolInput });
        emit({
          kind: 'permission',
          request_id: requestId,
          tool_id: toolId,
          tool_name: toolName,
          text: toolInputSummary(toolInput),
          reason: opts.decisionReason || null,
          blocked_path: opts.blockedPath || null,
        });
      }
      // The SDK aborts a pending call when the turn is interrupted.
      if (opts.signal) {
        opts.signal.addEventListener('abort', () => {
          resolvePending(requestId, { behavior: 'deny', message: 'Interrupted.' }, { behavior: 'cancelled' });
        }, { once: true });
      }
    });
  }

  /** One SDK message → zero or more Crow chat events. */
  function translate(msg) {
    if (!msg || typeof msg !== 'object') return;
    switch (msg.type) {
      case 'system':
        if (msg.subtype === 'init') {
          sessionId = msg.session_id || sessionId;
          emit({
            kind: 'ready',
            sdk_session_id: msg.session_id || null,
            model: msg.model || null,
            cwd: msg.cwd || null,
            permission_mode: msg.permissionMode || null,
            claude_code_version: msg.claude_code_version || null,
            api_key_source: msg.apiKeySource || null,
          });
        } else if (msg.subtype === 'compact_boundary') {
          emit({ kind: 'notice', text: 'Conversation compacted.' });
        }
        return;
      case 'stream_event': {
        if (msg.parent_tool_use_id) return; // a subagent's stream: not the main bubble
        const ev = msg.event;
        if (ev && ev.type === 'content_block_delta' && ev.delta && ev.delta.type === 'text_delta') {
          emit({ kind: 'delta', text: ev.delta.text, index: ev.index });
        }
        return;
      }
      case 'assistant': {
        if (msg.parent_tool_use_id) return;
        const blocks = (msg.message && msg.message.content) || [];
        for (const b of blocks) {
          if (b.type === 'text' && b.text && b.text.trim()) {
            emit({ kind: 'assistant', text: b.text });
          } else if (b.type === 'tool_use') {
            const ev = { kind: 'tool_call', tool_id: b.id, tool_name: b.name, text: toolInputSummary(b.input) };
            if (b.name === 'AskUserQuestion') ev.questions = normalizeQuestions(b.input);
            emit(ev);
          }
        }
        return;
      }
      case 'user': {
        if (msg.parent_tool_use_id) return;
        const content = msg.message && msg.message.content;
        if (!Array.isArray(content)) return; // our own prompt echo; `user` was emitted on send
        for (const b of content) {
          if (b.type === 'tool_result') {
            emit({
              kind: 'tool_result',
              tool_id: b.tool_use_id,
              text: clip(contentText(b.content), MAX_TOOL_RESULT),
              is_error: !!b.is_error,
            });
          }
        }
        return;
      }
      case 'result': {
        const duration = typeof msg.duration_ms === 'number' ? msg.duration_ms
          : (turnStartedAt ? Date.now() - turnStartedAt : null);
        turnStartedAt = null;
        const ev = { kind: 'turn_end', duration_ms: duration, is_error: !!msg.is_error };
        if (typeof msg.total_cost_usd === 'number') ev.cost_usd = msg.total_cost_usd;
        if (msg.usage) ev.usage = msg.usage;
        if (msg.is_error && msg.subtype !== 'success') ev.text = msg.subtype;
        emit(ev);
        return;
      }
      default:
        return;
    }
  }

  async function run(prompt) {
    const opts = Object.assign({}, options, { canUseTool, includePartialMessages: true });
    if (sessionId) opts.resume = sessionId; // a restart after an error continues the conversation
    q = query({ prompt, options: opts });
    try {
      for await (const msg of q) translate(msg);
      emit({ kind: 'exit', reason: 'done' });
    } catch (e) {
      emit({ kind: 'error', text: String((e && e.message) || e) });
      emit({ kind: 'exit', reason: 'error' });
    } finally {
      // A turn that died mid-question can't be answered any more.
      for (const id of Array.from(pending.keys())) {
        resolvePending(id, { behavior: 'deny', message: 'The session ended.' }, { behavior: 'cancelled' });
      }
      q = null;
    }
  }

  function ensureRunning() {
    if (running) return;
    input = createInputQueue();
    running = run(input).finally(() => { running = null; input = null; });
  }

  /** One command line from crowd. Returns an error string, or null. */
  function handle(cmd) {
    if (!cmd || typeof cmd !== 'object') return 'command must be an object';
    switch (cmd.op) {
      case 'message': {
        const text = typeof cmd.text === 'string' ? cmd.text : '';
        if (!text.trim()) return 'text required';
        ensureRunning();
        turnStartedAt = Date.now();
        emit({ kind: 'user', text });
        input.push({
          type: 'user',
          message: { role: 'user', content: text },
          parent_tool_use_id: null,
          session_id: sessionId || '',
        });
        return null;
      }
      case 'respond': {
        const p = pending.get(cmd.request_id);
        if (!p) return 'no pending request ' + cmd.request_id;
        if (cmd.behavior === 'deny') {
          const message = (typeof cmd.message === 'string' && cmd.message.trim())
            || (p.kind === 'question' ? 'The user declined to answer.' : 'The user denied this tool call.');
          resolvePending(cmd.request_id, { behavior: 'deny', message }, { behavior: 'deny', message });
          return null;
        }
        if (cmd.behavior !== 'allow') return 'behavior must be allow or deny';
        if (p.kind === 'question') {
          const problem = validateAnswers(p.questions, cmd.answers);
          if (problem) return problem;
          const answers = {};
          for (const qq of p.questions) answers[qq.question] = cmd.answers[qq.question];
          resolvePending(cmd.request_id,
            { behavior: 'allow', updatedInput: Object.assign({}, p.input, { answers }) },
            { behavior: 'allow', answers });
          return null;
        }
        resolvePending(cmd.request_id, { behavior: 'allow', updatedInput: p.input }, { behavior: 'allow' });
        return null;
      }
      case 'interrupt':
        if (q && typeof q.interrupt === 'function') {
          q.interrupt().catch((e) => emit({ kind: 'notice', text: 'Interrupt failed: ' + ((e && e.message) || e) }));
          emit({ kind: 'notice', text: 'Interrupted.' });
        }
        return null;
      default:
        return 'unknown op ' + cmd.op;
    }
  }

  function close() {
    if (input) input.close();
    if (q && typeof q.close === 'function') q.close();
  }

  return { handle, close, get done() { return running; }, get pendingCount() { return pending.size; } };
}
