'use strict';
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const state = require('../scripts/ccr/state.cjs');
const context = require('../scripts/ccr/context.cjs');
const { spawnSync } = require('node:child_process');
let directory;
beforeEach(() => { directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dex-context-')); process.env.DEX_ROUTER_HOME = directory; });
afterEach(() => fs.rmSync(directory, { recursive: true, force: true }));
function transcript(rows) {
  const file = path.join(directory, 'conversation.jsonl');
  fs.writeFileSync(file, rows.map(row => JSON.stringify(row)).join('\n') + '\n', { mode: 0o600 });
  return file;
}
test('compaction reports the next real input and restored overhead without copying conversation text', async () => {
  const file = transcript([
    { type: 'system', subtype: 'compact_boundary', timestamp: '2026-09-18T09:41:05Z', compactMetadata: { preTokens: 219269, postTokens: 45122, durationMs: 149130 } },
    { type: 'attachment', attachment: { type: 'invoked_skills', skills: [{ name: 'dxplan', content: 'PRIVATE INSTRUCTIONS' }] } },
    { type: 'attachment', attachment: { type: 'prompt_snapshot', systemPrompt: ['PRIVATE SYSTEM'], tools: [{ name: 'Read', schema: { description: 'PRIVATE SCHEMA' } }, { name: 'mcp__vm__query', schema: {} }] } },
    { type: 'assistant', message: { id: 'one', model: 'fable', content: [{ type: 'text', text: 'PRIVATE ANSWER' }], usage: { input_tokens: 1, cache_read_input_tokens: 124360, cache_creation_input_tokens: 87332, output_tokens: 110 } } },
    { type: 'assistant', message: { id: 'one', model: 'fable', usage: { input_tokens: 1, cache_read_input_tokens: 124360, cache_creation_input_tokens: 87332, output_tokens: 120 } } },
    { type: 'user', message: { content: [{ type: 'tool_result', content: 'tiny result' }] } },
    { type: 'assistant', message: { model: '<synthetic>', content: [{ type: 'text', text: 'Autocompact is thrashing: the context refilled to the limit.' }] } }
  ]);
  const report = await context.readTranscript(file, 272000);
  assert.equal(report.compactions[0].next_input_tokens, 211693);
  assert.equal(report.compactions[0].post_tokens, 45122);
  assert.equal(report.tool_count, 2);
  assert.equal(report.restored_skill_characters, 20);
  assert.equal(report.recent_requests.length, 1);
  assert.equal(report.thrashing, true);
  assert.doesNotMatch(JSON.stringify(report), /PRIVATE/);
  const larger = await context.readTranscript(file, 800000);
  assert.equal(larger.near_limit_after_compact, false);
});
test('transcript inspection is bounded and tolerates a partially written final record', async () => {
  const file = transcript([{ type: 'system', subtype: 'compact_boundary', compactMetadata: { preTokens: 200000, postTokens: 20000 } }]);
  fs.appendFileSync(file, '{partial');
  const report = await context.readTranscript(file, 272000);
  assert.equal(report.incomplete_records, 1);
  assert.equal(report.compactions.length, 1);
  assert.equal(report.compactions[0].duration_ms, null, 'unknown timing is not reported as an instantaneous compact');
  const link = path.join(directory, 'link.jsonl'); fs.symlinkSync(file, link);
  await assert.rejects(context.readTranscript(link, 272000), /regular|safe|symlink/i);
});
test('doctor reports stale launch budgets for stopped sessions and excludes capabilities', async () => {
  state.write(state.stateFile('config'), { version: 1, enabled: true, models: [{ id: 'openai/test', context_window: 272000, max_context_window: 872000 }], phases: {}, default_model: 'openai/test', context_budget: 800000 });
  state.write(state.sessionFile('stopped'), { id: 'stopped', active: false, context_limit: 272000, current_model: 'openai/test', auth_hash: 'PRIVATE_CAPABILITY' });
  const report = await context.doctor({ session: 'stopped' });
  assert.equal(report.configured_budget, 800000);
  assert.equal(report.launch_budget, 272000);
  assert.equal(report.restart_required, true);
  assert.equal(report.models[0].maximum, 872000);
  assert.doesNotMatch(JSON.stringify(report), /PRIVATE/);
  await assert.rejects(context.doctor({ session: '../bad' }), /Invalid/);
});
test('public context commands persist a valid budget and reject unsafe increases atomically', async t => {
  const cli = require('../scripts/ccr/cli.cjs');
  state.write(state.stateFile('config'), { version: 1, enabled: true, models: [{ id: 'openai/test', provider: 'openai', context_window: 272000, max_context_window: 872000 }], phases: {}, default_model: 'openai/test' });
  const writes = []; t.mock.method(process.stdout, 'write', value => { writes.push(value); return true; });
  await cli.main(['context', 'budget', '800000']);
  assert.equal(state.config().context_budget, 800000);
  const before = state.config();
  await assert.rejects(cli.main(['context', 'budget', '1000000']), /capacity/);
  assert.deepEqual(state.config(), before);
  await assert.rejects(cli.main(['context', 'budget']), /arguments/);
  writes.length = 0;
  await cli.main(['context', 'doctor', '--json']);
  assert.equal(JSON.parse(writes.join('')).configured_budget, 800000);
});
test('context refresh updates only metadata and preserves manual limits without restarting a busy router', async t => {
  const cli = require('../scripts/ccr/cli.cjs');
  const onboarding = require('../scripts/ccr/onboarding.cjs');
  const config = { version: 1, enabled: true, models: [
    { id: 'openai/test', provider: 'openai', context_window: 272000, context_source: 'provider' },
    { id: 'openai/manual', provider: 'openai', context_window: 64000, context_source: 'user' }
  ], phases: {}, default_model: 'openai/test' };
  state.write(state.stateFile('config'), config); state.saveAccounts([{ id: 'one', provider: 'openai', enabled: true }]);
  t.mock.method(require('../scripts/ccr/adapter.cjs'), 'idle', () => { throw new Error('must not restart'); });
  t.mock.method(onboarding, 'discover', async () => onboarding.catalogue('openai', { models: [
    { slug: 'test', context_window: 272000, max_context_window: 872000 },
    { slug: 'manual', context_window: 272000, max_context_window: 872000 },
    { slug: 'new-model', context_window: 272000 }
  ] }));
  const result = await context.refresh(cli.configure);
  assert.deepEqual(result.updated, ['openai/test']);
  assert.equal(state.config().models.length, 2);
  assert.equal(state.config().models[0].max_context_window, 872000);
  assert.deepEqual(state.config().models[1], config.models[1]);
  const before = state.config();
  t.mock.method(onboarding, 'discover', async () => { throw new Error('PRIVATE TOKEN'); });
  await assert.rejects(context.refresh(cli.configure), /metadata unavailable/);
  assert.deepEqual(state.config(), before);
});
test('the stop detector distinguishes current thrashing from historical errors, quotes and bystanders', () => {
  const run = payload => spawnSync('python3', [path.resolve(__dirname, '../scripts/context-stop.py')], { input: JSON.stringify(payload), encoding: 'utf8' });
  assert.equal(run({ last_assistant_message: 'Autocompact is thrashing: the context refilled.' }).status, 0);
  assert.equal(run({ last_assistant_message: 'We discussed Autocompact is thrashing: earlier.' }).status, 1);
  const row = { type: 'assistant', sessionId: 'owner', message: { model: '<synthetic>', content: [{ type: 'text', text: 'Autocompact is thrashing: context refilled.' }] } };
  const file = transcript([row]);
  assert.equal(run({ session_id: 'owner', transcript_path: file }).status, 0);
  assert.equal(run({ session_id: 'bystander', transcript_path: file }).status, 1);
  fs.appendFileSync(file, JSON.stringify({ type: 'user', message: { content: 'Continue after recovery' } }) + '\n');
  assert.equal(run({ session_id: 'owner', transcript_path: file }).status, 1);
  const link = path.join(directory, 'unsafe.jsonl'); fs.symlinkSync(file, link);
  assert.equal(run({ session_id: 'owner', transcript_path: link }).status, 1);
});
test('frequently restored skill entrypoints stay small and point at their complete workflows', () => {
  const root = path.resolve(__dirname, '..');
  for (const name of ['dxplan', 'dximplement', 'dxpr', 'dxprreview', 'dxwatchpr']) {
    const entry = fs.readFileSync(path.join(root, 'skills', name, 'SKILL.md'), 'utf8');
    assert.ok(Buffer.byteLength(entry) < 1100, `${name} restored entrypoint exceeds its context budget`);
    assert.ok(entry.includes(`prompts/workflows/${name}.md`));
    const workflow = fs.readFileSync(path.join(root, 'prompts/workflows', `${name}.md`), 'utf8');
    assert.ok(workflow.includes(`# Skill: ${name}`));
    assert.ok(workflow.length > 5000, `${name} workflow must retain its full contract`);
  }
});

test('doctor names the installed client settings that predate this Dex', async () => {
  const claude_file = path.join(directory, 'claude-settings.json');
  state.write(state.stateFile('config'), { version: 1, enabled: true, models: [{ id: 'anthropic/test', context_window: 1000000 }],
    phases: {}, default_model: 'anthropic/test', context_budget: 800000,
    native: { enabled: true, claude_file, codex_file: path.join(directory, 'codex.toml') } });
  // The shape an install from before the long-context repair leaves behind.
  fs.writeFileSync(claude_file, JSON.stringify({ model: 'anthropic/test',
    env: { CLAUDE_CODE_MAX_CONTEXT_TOKENS: '800000', CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: '80' } }), { mode: 0o600 });
  const stale = (await context.doctor()).client_settings;
  assert.equal(stale.long_context, false);
  assert.equal(stale.auto_compact_window, null);
  assert.equal(stale.long_context_beta, false);
  assert.equal(stale.tool_search, false);
  assert.equal(stale.stale.length, 5, 'the marker, window, percentage, beta and tool search are each named');
  assert.match((await context.doctor()).advice.join(' '), /dx router native sync/);

  // A current install has nothing to report, and the section is absent when
  // Dex does not own the client's settings at all.
  fs.writeFileSync(claude_file, JSON.stringify({ model: 'anthropic/test[1m]',
    env: { CLAUDE_CODE_MAX_CONTEXT_TOKENS: '800000', CLAUDE_CODE_AUTO_COMPACT_WINDOW: '800000',
      ANTHROPIC_BETAS: 'context-1m-2025-08-07', ENABLE_TOOL_SEARCH: 'true' } }), { mode: 0o600 });
  assert.deepEqual((await context.doctor()).client_settings.stale, []);
  const config = state.config(); config.native.enabled = false; state.write(state.stateFile('config'), config);
  assert.equal((await context.doctor()).client_settings, null);
});
