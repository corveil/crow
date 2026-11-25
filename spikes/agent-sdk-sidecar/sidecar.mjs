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
import { createBridge, sidecarOptions } from './bridge.mjs';

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

const options = sidecarOptions({
  cwd: args.cwd, claude: args.claude, resume: args.resume, model: args.model, env: process.env,
});
options.stderr = (data) => process.stderr.write(data);

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
  // Wait for the query, so its `claude` has exited before we do (crowd waits
  // for our exit before resuming the same SDK session).
  if (done) await Promise.race([done, new Promise((r) => setTimeout(r, 5000))]);
  process.exit(code);
}
rl.on('close', () => shutdown(0));
process.on('SIGTERM', () => shutdown(0));
process.on('SIGINT', () => shutdown(0));
