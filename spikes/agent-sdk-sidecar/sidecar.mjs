#!/usr/bin/env node
// THROWAWAY SPIKE (CROW-1524, ADR 0033). Not product code.
//
// crowd spawns one of these per Crow session that opts into the SDK path:
//
//   node sidecar.mjs --cwd <worktree> [--claude <path>] [--resume <id>] [--model <m>]
//
// stdin:  one JSON command per line — {op:"message",text} | {op:"respond",
//         request_id, behavior:"allow"|"deny", message?, answers?} | {op:"interrupt"}
// stdout: one JSON event per line (bridge.mjs). Nothing else is ever written
//         to stdout; diagnostics go to stderr, which crowd logs.
//
// No API call is made until the first `message`. stdin EOF or SIGTERM ends it.

import { createInterface } from 'node:readline';
import { parseArgs } from 'node:util';
import { query } from '@anthropic-ai/claude-agent-sdk';
import { createBridge } from './bridge.mjs';

const { values: args } = parseArgs({
  options: {
    cwd: { type: 'string' },
    claude: { type: 'string' },
    resume: { type: 'string' },
    model: { type: 'string' },
  },
});

if (!args.cwd) {
  process.stderr.write('sidecar: --cwd is required\n');
  process.exit(2);
}

// crowd may itself run under a Claude Code session (a developer running a dev
// build from an agent). These name *that* session; the child CLI must not
// think it is nested inside it.
const INHERITED_SESSION_VARS = [
  'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_CHILD_NOTES_DIR', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
  'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_EXECPATH', 'CLAUDE_PID',
];
const env = { ...process.env };
for (const k of INHERITED_SESSION_VARS) delete env[k];

const options = {
  cwd: args.cwd,
  env,
  // The same prompt, settings, CLAUDE.md, skills and hooks the terminal agent
  // gets. `local` is what carries Crow's gateway env (ANTHROPIC_BASE_URL /
  // ANTHROPIC_CUSTOM_HEADERS in .claude/settings.local.json) — and Crow's hooks.
  systemPrompt: { type: 'preset', preset: 'claude_code' },
  settingSources: ['user', 'project', 'local'],
  // Omitted, the SDK starts in `auto` (or the settings' defaultMode), which
  // would approve most calls without asking. The spike wants to see the asks.
  permissionMode: 'default',
  stderr: (data) => process.stderr.write(data),
};
// Reuse the operator's own `claude` (Crow already requires it) instead of the
// SDK's ~384 MB per-platform native binary, installed with --omit=optional.
if (args.claude) options.pathToClaudeCodeExecutable = args.claude;
if (args.resume) options.resume = args.resume;
if (args.model) options.model = args.model;

function emit(event) {
  process.stdout.write(JSON.stringify(event) + '\n');
}

const bridge = createBridge({ query, emit, options });

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  if (!line.trim()) return;
  let cmd;
  try {
    cmd = JSON.parse(line);
  } catch (_) {
    emit({ kind: 'command_error', text: 'not JSON' });
    return;
  }
  const problem = bridge.handle(cmd);
  if (problem) emit({ kind: 'command_error', op: cmd && cmd.op, text: problem });
});

let closing = false;
async function shutdown(code) {
  if (closing) return;
  closing = true;
  bridge.close();
  const done = bridge.done;
  if (done) await Promise.race([done, new Promise((r) => setTimeout(r, 3000))]);
  process.exit(code);
}
rl.on('close', () => shutdown(0));
process.on('SIGTERM', () => shutdown(0));
process.on('SIGINT', () => shutdown(0));
