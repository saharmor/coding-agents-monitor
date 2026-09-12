import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { snapshotFromOAuthUsage, snapshotFromStatusLine } from './claude-statusline-bridge.mjs';

const reset = '2026-09-13T10:59:59.898898+00:00';
const fable = (percent = 59) => ({
  kind: 'weekly_scoped', scope: { model: { display_name: 'Fable' } }, percent, resets_at: reset
});

test('keeps Fable separate from all-models and other model quotas', () => {
  const snapshot = snapshotFromOAuthUsage({
    five_hour: { utilization: 4, resets_at: reset },
    seven_day: { utilization: 98, resets_at: reset },
    limits: [{ ...fable(12), scope: { model: { display_name: 'Sonnet' } } }, fable()]
  });
  assert.equal(snapshot.fiveHour.usedPercent, 4);
  assert.equal(snapshot.sevenDay.usedPercent, 98);
  assert.equal(snapshot.fableWeekly.usedPercent, 59);
  assert.equal(snapshot.fableWeekly.remainingPercent, 41);
  assert.equal(snapshot.fableWeekly.resetsAt, Date.parse(reset) / 1000);
  assert.equal(snapshot.fableWeeklyUpdatedAt, snapshot.updatedAt);
});

test('zero is valid; missing, null, malformed, and other limits are not Fable zeroes', () => {
  assert.equal(snapshotFromOAuthUsage({ limits: [fable(0)] }).fableWeekly.usedPercent, 0);
  for (const limits of [undefined, null, {}, [], [null], [fable(null)], [fable('')],
    [fable('bad')], [fable(true)], [fable(Infinity)],
    [{ ...fable(), kind: 'weekly' }],
    [{ ...fable(), scope: { model: { display_name: 5 } } }]]) {
    const snapshot = snapshotFromOAuthUsage({ limits });
    assert.equal(snapshot.fableWeekly, null);
    assert.equal(snapshot.fableWeeklyUpdatedAt, null);
  }
});

test('reads a model quota when supplied with status-line usage', () => {
  const snapshot = snapshotFromStatusLine({ rate_limits: { limits: [fable()] } });
  assert.equal(snapshot.fableWeekly.usedPercent, 59);
});

test('status-line writes preserve Fable timestamp and sanitize retained data', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-fable-test-'));
  try {
    const file = path.join(root, 'claude-status.json');
    const oldTimestamp = '2026-01-01T00:00:00.000Z';
    fs.writeFileSync(file, JSON.stringify({
      provider: 'claude', fableWeekly: { usedPercent: 59, resetsAt: Date.parse(reset) / 1000, ignored: 'private' },
      fableWeeklyUpdatedAt: oldTimestamp, ignored: 'private'
    }));
    const input = JSON.stringify({
      rate_limits: { five_hour: { used_percentage: 5, resets_at: Date.parse(reset) / 1000 } },
      transcript: 'must not be stored'
    });
    const result = spawnSync(process.execPath,
      [fileURLToPath(new URL('./claude-statusline-bridge.mjs', import.meta.url))],
      { input, encoding: 'utf8', timeout: 5000, env: { ...process.env, USAGE_MONITOR_HOME: root } });
    assert.equal(result.status, 0, result.stderr);
    const cached = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(cached.fiveHour.usedPercent, 5);
    assert.equal(cached.fableWeekly.usedPercent, 59);
    assert.equal(cached.fableWeeklyUpdatedAt, oldTimestamp);
    assert.notEqual(cached.updatedAt, oldTimestamp);
    assert.equal(cached.ignored, undefined);
    assert.equal(cached.transcript, undefined);
    assert.equal(cached.fableWeekly.ignored, undefined);
    assert.deepEqual(fs.readdirSync(root), ['claude-status.json']);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('OAuth refresh writes Fable and clears it when the provider stops reporting it', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-fable-oauth-test-'));
  try {
    const credentials = path.join(root, 'credentials.json');
    fs.writeFileSync(credentials, JSON.stringify({ claudeAiOauth: {
      accessToken: 'test-only', expiresAt: Date.now() + 3600_000
    } }), { mode: 0o600 });
    for (const reported of [true, false]) {
      const usage = { five_hour: { utilization: 4 }, limits: reported ? [fable()] : [] };
      const code = `
        import { pathToFileURL } from 'node:url';
        globalThis.fetch = async () => ({ ok: true, json: async () => (${JSON.stringify(usage)}) });
        await import(pathToFileURL(process.argv[1]));
      `;
      const result = spawnSync(process.execPath, ['--input-type=module', '--eval', code,
        fileURLToPath(new URL('./claude-statusline-bridge.mjs', import.meta.url)), '--refresh-only'], {
        encoding: 'utf8', timeout: 5000,
        env: { ...process.env, USAGE_MONITOR_HOME: root, CLAUDE_CREDENTIALS_PATH: credentials }
      });
      assert.equal(result.status, 0, result.stderr);
      const cached = JSON.parse(fs.readFileSync(path.join(root, 'claude-status.json'), 'utf8'));
      assert.equal(cached.fiveHour.usedPercent, 4);
      assert.equal(cached.fableWeekly?.usedPercent ?? null, reported ? 59 : null);
      assert.equal(cached.fableWeeklyUpdatedAt, reported ? cached.updatedAt : null);
      assert.equal(JSON.stringify(cached).includes('test-only'), false);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
