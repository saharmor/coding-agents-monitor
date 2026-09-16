import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { snapshotFromOAuthUsage, snapshotFromStatusLine, scheduledRefresh, retryAfterMilliseconds } from './claude-statusline-bridge.mjs';

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
      fs.rmSync(path.join(root, 'claude-refresh-state.json'), { force: true });
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

test('background failures have exit codes, leave cache untouched, and keep status-line mode quiet', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-failure-test-'));
  try {
    const credentials = path.join(root, 'credentials.json');
    fs.writeFileSync(credentials, JSON.stringify({ claudeAiOauth: {
      accessToken: 'test-only', expiresAt: Date.now() + 3600_000
    } }), { mode: 0o600 });
    const cache = path.join(root, 'claude-status.json');
    fs.writeFileSync(cache, '{"updatedAt":"old"}');
    for (const [status, expected] of [[401, 2], [403, 2], [429, 3], [500, 5]]) {
      for (const background of [true, false]) {
        fs.rmSync(path.join(root, 'claude-refresh-state.json'), { force: true });
        const code = `
          import { pathToFileURL } from 'node:url';
          globalThis.fetch = async () => ({ ok: false, status: ${status}, json: async () => ({}) });
          await import(pathToFileURL(process.argv[1]));
        `;
        const result = spawnSync(process.execPath, ['--input-type=module', '--eval', code,
          fileURLToPath(new URL('./claude-statusline-bridge.mjs', import.meta.url)),
          ...(background ? ['--refresh-only'] : [])], {
          input: '{}', encoding: 'utf8', timeout: 5000,
          env: { ...process.env, USAGE_MONITOR_HOME: root, CLAUDE_CREDENTIALS_PATH: credentials, USAGE_MONITOR_DEBUG: '0' }
        });
        assert.equal(result.status, background ? expected : 0, result.stderr);
        assert.equal(result.stderr, '');
        assert.equal(result.stdout, '');
        assert.equal(fs.readFileSync(cache, 'utf8'), '{"updatedAt":"old"}');
      }
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('Retry-After supports seconds and HTTP dates without shortening server delays', () => {
  const now = Date.parse('2026-09-14T00:00:00Z');
  assert.equal(retryAfterMilliseconds('3600', now), 3_600_000);
  assert.equal(retryAfterMilliseconds('Mon, 14 Sep 2026 01:00:00 GMT', now), 3_600_000);
  for (const value of [null, '', 'garbage', '-1', 'Sun, 13 Sep 2026 00:00:00 GMT']) {
    assert.equal(retryAfterMilliseconds(value, now), 0);
  }
});

test('concurrent refreshes share one request and cooldown never rewrites cache timestamps', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-schedule-'));
  try {
    let time = Date.now();
    let calls = 0;
    let release;
    const pending = new Promise(resolve => { release = resolve; });
    const request = async () => { calls++; await pending; return { five_hour: { utilization: 4 } }; };
    const first = scheduledRefresh(request, root, () => time);
    assert.equal((await scheduledRefresh(request, root, () => time)).snapshot, null);
    assert.equal(calls, 1);
    release();
    await first;
    const file = path.join(root, 'claude-status.json');
    const cached = fs.readFileSync(file, 'utf8');
    time += 299_999;
    await scheduledRefresh(request, root, () => time);
    assert.equal(calls, 1);
    assert.equal(fs.readFileSync(file, 'utf8'), cached);
    time++;
    await scheduledRefresh(request, root, () => time);
    assert.equal(calls, 2);
    assert.equal(fs.existsSync(path.join(root, 'claude-refresh.lock')), false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('rate limits back off 15, 30, 60 minutes and retain slow polling after recovery', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-backoff-'));
  try {
    let time = Date.now();
    let calls = 0;
    let retryAfterMs = 0;
    const request = async () => { calls++; throw Object.assign(new Error('limited'), { status: 429, retryAfterMs }); };
    let lastRateLimit;
    for (const delay of [900_000, 1_800_000, 3_600_000, 3_600_000, 7_200_000]) {
      retryAfterMs = delay === 7_200_000 ? delay : 0;
      lastRateLimit = time;
      assert.equal((await scheduledRefresh(request, root, () => time)).failureCode, 3);
      const state = JSON.parse(fs.readFileSync(path.join(root, 'claude-refresh-state.json'), 'utf8'));
      assert.equal(state.nextAllowedAt, time + delay);
      const previousCalls = calls;
      time += delay - 1;
      assert.equal((await scheduledRefresh(request, root, () => time)).failureCode, 3);
      assert.equal(calls, previousCalls);
      time++;
    }
    await scheduledRefresh(async () => ({ five_hour: { utilization: 7 } }), root, () => time);
    const state = JSON.parse(fs.readFileSync(path.join(root, 'claude-refresh-state.json'), 'utf8'));
    assert.deepEqual(state, { nextAllowedAt: time + 900_000, failures: 0, failureCode: 0, rateLimitedAt: lastRateLimit, lastAttemptAt: time });
    time += 900_000;
    await scheduledRefresh(async () => ({ five_hour: { utilization: 8 } }), root, () => time);
    assert.equal(JSON.parse(fs.readFileSync(path.join(root, 'claude-refresh-state.json'))).nextAllowedAt, time + 900_000);
    time = lastRateLimit + 86_400_000;
    await scheduledRefresh(async () => ({ five_hour: { utilization: 9 } }), root, () => time);
    assert.equal(JSON.parse(fs.readFileSync(path.join(root, 'claude-refresh-state.json'))).nextAllowedAt, time + 300_000);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('cooldown survives separate processes and status-line callbacks never fetch or erase quotas', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-restart-'));
  try {
    const credentials = path.join(root, 'credentials.json');
    fs.writeFileSync(credentials, JSON.stringify({ claudeAiOauth: { accessToken: 'fake', expiresAt: Date.now() + 3_600_000 } }));
    const cache = path.join(root, 'claude-status.json');
    fs.writeFileSync(cache, '{"updatedAt":"old"}');
    const code = `
      import fs from 'node:fs';
      import path from 'node:path';
      import { pathToFileURL } from 'node:url';
      globalThis.fetch = async () => {
        fs.appendFileSync(path.join(process.env.USAGE_MONITOR_HOME, 'requests'), 'request\\n');
        return { ok: false, status: 429, headers: new Headers({ 'Retry-After': '3600' }), json: async () => ({}) };
      };
      await import(pathToFileURL(process.argv[1]));
    `;
    for (const background of [false, true, true, false]) {
      const result = spawnSync(process.execPath, ['--input-type=module', '--eval', code,
        fileURLToPath(new URL('./claude-statusline-bridge.mjs', import.meta.url)), ...(background ? ['--refresh-only'] : [])], {
        input: '{"context_window":{"total_input_tokens":500}}', encoding: 'utf8', timeout: 5000,
        env: { ...process.env, USAGE_MONITOR_HOME: root, CLAUDE_CREDENTIALS_PATH: credentials }
      });
      assert.equal(result.status, background ? 3 : 0, result.stderr);
      assert.equal(fs.readFileSync(cache, 'utf8'), '{"updatedAt":"old"}');
    }
    assert.equal(fs.readFileSync(path.join(root, 'requests'), 'utf8'), 'request\n');
    const state = JSON.parse(fs.readFileSync(path.join(root, 'claude-refresh-state.json'), 'utf8'));
    assert.ok(state.nextAllowedAt > Date.now() + 3_590_000);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('a dead process lock is reclaimed without issuing an immediate request', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-dead-lock-'));
  try {
    const lock = path.join(root, 'claude-refresh.lock');
    fs.mkdirSync(lock);
    fs.writeFileSync(path.join(lock, '2147483647-dead'), '');
    let calls = 0;
    const request = async () => { calls++; return { five_hour: { utilization: 4 } }; };
    await scheduledRefresh(request, root);
    assert.equal(calls, 0);
    assert.equal(fs.existsSync(lock), false);
    await scheduledRefresh(request, root);
    assert.equal(calls, 1);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('upgrading a legacy 429 cooldown extends it once without any network request', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-upgrade-'));
  try {
    const time = Date.now();
    const file = path.join(root, 'claude-refresh-state.json');
    fs.writeFileSync(file, JSON.stringify({ nextAllowedAt: time + 60_000, failures: 1, failureCode: 3 }));
    const request = async () => { assert.fail('must not probe during cooldown'); };
    assert.equal((await scheduledRefresh(request, root, () => time)).failureCode, 3);
    assert.equal(JSON.parse(fs.readFileSync(file)).nextAllowedAt, time + 900_000);
    await scheduledRefresh(request, root, () => time + 30_000);
    assert.equal(JSON.parse(fs.readFileSync(file)).nextAllowedAt, time + 900_000);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('manual refresh skips the normal interval but not the one-minute guard or error cooldown', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-manual-'));
  try {
    let time = Date.now();
    let calls = 0;
    let limited = false;
    const request = async () => {
      calls++;
      if (limited) throw Object.assign(new Error('limited'), { status: 429, retryAfterMs: 3_600_000 });
      return { five_hour: { utilization: calls } };
    };
    await scheduledRefresh(request, root, () => time);
    time += 59_999;
    assert.equal((await scheduledRefresh(request, root, () => time, true)).failureCode, 7);
    assert.equal(calls, 1);
    time++;
    assert.equal((await scheduledRefresh(request, root, () => time, true)).snapshot.fiveHour.usedPercent, 2);
    assert.equal(calls, 2);
    time += 60_000;
    limited = true;
    assert.equal((await scheduledRefresh(request, root, () => time, true)).failureCode, 3);
    const original = fs.readFileSync(path.join(root, 'claude-refresh-state.json'), 'utf8');
    time += 900_000;
    assert.equal((await scheduledRefresh(request, root, () => time, true)).failureCode, 3);
    assert.equal(calls, 3);
    assert.equal(fs.readFileSync(path.join(root, 'claude-refresh-state.json'), 'utf8'), original);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('manual refresh cannot overlap a live request', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-manual-lock-'));
  try {
    let release;
    const pending = new Promise(resolve => { release = resolve; });
    let calls = 0;
    const request = async () => { calls++; await pending; return { five_hour: { utilization: 4 } }; };
    const first = scheduledRefresh(request, root);
    assert.equal((await scheduledRefresh(request, root, Date.now, true)).failureCode, 7);
    release();
    await first;
    assert.equal(calls, 1);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
