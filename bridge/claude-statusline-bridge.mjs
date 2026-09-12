#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const args = new Set(process.argv.slice(2));
const refreshOnly = args.has('--refresh-only');
const printSummary = args.has('--print-summary');
const debugEnabled = process.env.USAGE_MONITOR_DEBUG === '1';
let rawInput = '';

const CLAUDE_CODE_CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const CLAUDE_SCOPES = [
  'user:profile',
  'user:inference',
  'user:sessions:claude_code',
  'user:mcp_servers',
  'user:file_upload'
];
const TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const REFRESH_SKEW_MS = 5 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 5000;

function parseInput(input) {
  try {
    return input.trim() ? JSON.parse(input) : {};
  } catch {
    return {};
  }
}

function debugError(label, error) {
  if (!debugEnabled) return;
  const body = error?.body && typeof error.body === 'object' ? error.body : null;
  const safe = {
    label,
    message: error instanceof Error ? error.message : String(error),
    status: error?.status ?? null,
    bodyKeys: body ? Object.keys(body).sort() : []
  };
  process.stderr.write(`${JSON.stringify(safe)}\n`);
}

function finiteNumber(value) {
  if (typeof value !== 'number' && typeof value !== 'string') return null;
  if (typeof value === 'string' && value.trim() === '') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function clampPercent(value) {
  const number = finiteNumber(value);
  if (number === null) return null;
  return Math.max(0, Math.min(100, number));
}

function resetSeconds(value) {
  const number = finiteNumber(value);
  if (number !== null) return number > 0 ? number : null;
  if (typeof value !== 'string' || value.trim() === '') return null;
  const millis = Date.parse(value);
  if (!Number.isFinite(millis) || millis <= 0) return null;
  return millis / 1000;
}

function normalizeStatusLineWindow(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const used = clampPercent(raw.used_percentage);
  const reset = resetSeconds(raw.resets_at);
  if (used === null && reset === null) return null;
  return {
    usedPercent: used,
    remainingPercent: used === null ? null : clampPercent(100 - used),
    resetsAt: reset
  };
}

function normalizeOAuthWindow(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const used = clampPercent(raw.utilization ?? raw.used_percentage ?? raw.used_percent);
  const reset = resetSeconds(raw.resets_at);
  if (used === null && reset === null) return null;
  return {
    usedPercent: used,
    remainingPercent: used === null ? null : clampPercent(100 - used),
    resetsAt: reset
  };
}

function normalizeContext(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const used = clampPercent(raw.used_percentage);
  const remaining = clampPercent(raw.remaining_percentage);
  const totalInput = finiteNumber(raw.total_input_tokens) ?? 0;
  const totalOutput = finiteNumber(raw.total_output_tokens) ?? 0;
  const tokens = totalInput + totalOutput;
  if (used === null && remaining === null && tokens <= 0) return null;
  return {
    usedPercent: used,
    remainingPercent: remaining,
    tokens: tokens > 0 ? Math.round(tokens) : null
  };
}

function normalizeFableWindow(usage) {
  const raw = Array.isArray(usage?.limits) ? usage.limits.find(limit =>
    limit?.kind === 'weekly_scoped' &&
    typeof limit.scope?.model?.display_name === 'string' &&
    limit.scope.model.display_name.toLowerCase() === 'fable'
  ) : null;
  if (!raw) return null;
  const window = normalizeOAuthWindow({ utilization: raw.percent, resets_at: raw.resets_at });
  return window?.usedPercent == null ? null : window;
}

function snapshotHasUsage(snapshot) {
  return Boolean(
    snapshot?.fiveHour?.remainingPercent !== null && snapshot?.fiveHour?.remainingPercent !== undefined ||
    snapshot?.sevenDay?.remainingPercent !== null && snapshot?.sevenDay?.remainingPercent !== undefined ||
    snapshot?.fableWeekly?.remainingPercent !== null && snapshot?.fableWeekly?.remainingPercent !== undefined ||
    snapshot?.context?.tokens !== null && snapshot?.context?.tokens !== undefined
  );
}

function usageMonitorRoot() {
  return process.env.USAGE_MONITOR_HOME || path.join(os.homedir(), '.usage-monitor');
}

function writeAtomicJSON(destination, value, mode = 0o600) {
  const temporary = path.join(path.dirname(destination), `.${path.basename(destination)}.tmp-${process.pid}-${Date.now()}`);
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode });
  fs.renameSync(temporary, destination);
  try {
    fs.chmodSync(destination, mode);
  } catch {
    // Best effort only.
  }
}

function writeSnapshot(snapshot) {
  writeAtomicJSON(path.join(usageMonitorRoot(), 'claude-status.json'), snapshot);
}

function credentialsPath() {
  return process.env.CLAUDE_CREDENTIALS_PATH || path.join(os.homedir(), '.claude', '.credentials.json');
}

function claudeConfigDir() {
  return process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
}

function oauthFileSuffix() {
  return process.env.CLAUDE_CODE_CUSTOM_OAUTH_URL ? '-custom-oauth' : '';
}

function keychainServiceName() {
  const configSuffix = process.env.CLAUDE_CONFIG_DIR
    ? `-${crypto.createHash('sha256').update(claudeConfigDir()).digest('hex').slice(0, 8)}`
    : '';
  return `Claude Code${oauthFileSuffix()}-credentials${configSuffix}`;
}

function keychainAccountName() {
  try {
    return process.env.USER || os.userInfo().username;
  } catch {
    return process.env.USER || 'claude-code-user';
  }
}

function readKeychainCredentials() {
  if (process.platform !== 'darwin' || process.env.CLAUDE_CREDENTIALS_PATH) return null;
  const account = keychainAccountName();
  const service = keychainServiceName();
  const result = spawnSync(
    'security',
    ['find-generic-password', '-a', account, '-w', '-s', service],
    { encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024 }
  );
  if (result.status !== 0 || !result.stdout.trim()) return null;
  return {
    storage: 'keychain',
    account,
    service,
    value: JSON.parse(result.stdout.trim())
  };
}

function saveKeychainCredentials(credentialsRecord, credentials) {
  const payload = JSON.stringify(credentials);
  const hex = Buffer.from(payload, 'utf8').toString('hex');
  const result = spawnSync(
    'security',
    ['add-generic-password', '-U', '-a', credentialsRecord.account, '-s', credentialsRecord.service, '-X', hex],
    { encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024 }
  );
  if (result.status !== 0) {
    throw new Error('Failed to update Claude credentials in Keychain');
  }
}

function readCredentials() {
  const keychain = readKeychainCredentials();
  if (keychain) return keychain;

  const file = credentialsPath();
  const data = fs.readFileSync(file, 'utf8');
  return { storage: 'plaintext', file, value: JSON.parse(data) };
}

function saveCredentials(credentialsRecord, credentials) {
  if (credentialsRecord.storage === 'keychain') {
    saveKeychainCredentials(credentialsRecord, credentials);
  } else {
    writeAtomicJSON(credentialsRecord.file, credentials);
  }
}

function tokenExpiresSoon(expiresAt) {
  const expiry = finiteNumber(expiresAt);
  return expiry === null || Date.now() + REFRESH_SKEW_MS >= expiry;
}

async function requestJSON(url, options) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    let body = null;
    try {
      body = await response.json();
    } catch {
      body = null;
    }
    if (!response.ok) {
      const error = new Error(`HTTP ${response.status}`);
      error.status = response.status;
      error.body = body;
      throw error;
    }
    return body;
  } finally {
    clearTimeout(timeout);
  }
}

async function refreshOAuthToken(credentialsRecord) {
  const credentials = credentialsRecord.value;
  const oauth = credentials.claudeAiOauth;
  if (!oauth?.refreshToken) {
    throw new Error('No Claude refresh token available');
  }

  const body = {
    grant_type: 'refresh_token',
    refresh_token: oauth.refreshToken,
    client_id: CLAUDE_CODE_CLIENT_ID,
    scope: CLAUDE_SCOPES.join(' ')
  };

  const data = await requestJSON(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });

  if (!data?.access_token || !data?.expires_in) {
    throw new Error('Claude token refresh response was incomplete');
  }

  oauth.accessToken = data.access_token;
  oauth.refreshToken = data.refresh_token || oauth.refreshToken;
  oauth.expiresAt = Date.now() + Number(data.expires_in) * 1000;
  if (typeof data.scope === 'string') {
    oauth.scopes = data.scope.split(/\s+/).filter(Boolean);
  }
  if (data.organization?.uuid && !credentials.organizationUuid) {
    credentials.organizationUuid = data.organization.uuid;
  }

  saveCredentials(credentialsRecord, credentials);
  return oauth.accessToken;
}

async function freshAccessToken(forceRefresh = false) {
  const credentialsRecord = readCredentials();
  const oauth = credentialsRecord.value.claudeAiOauth;
  if (!oauth?.accessToken && !oauth?.refreshToken) {
    throw new Error('Claude OAuth credentials are unavailable');
  }
  if (!forceRefresh && oauth.accessToken && !tokenExpiresSoon(oauth.expiresAt)) {
    return oauth.accessToken;
  }
  return await refreshOAuthToken(credentialsRecord);
}

async function fetchClaudeUsageWithToken(accessToken) {
  return await requestJSON(USAGE_URL, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      'User-Agent': 'usage-monitor/1.0',
      'anthropic-beta': 'oauth-2025-04-20'
    }
  });
}

async function fetchClaudeUsage() {
  let accessToken = await freshAccessToken(false);
  try {
    return await fetchClaudeUsageWithToken(accessToken);
  } catch (error) {
    if (error.status !== 401) throw error;
    accessToken = await freshAccessToken(true);
    return await fetchClaudeUsageWithToken(accessToken);
  }
}

export function snapshotFromOAuthUsage(usage) {
  const now = new Date().toISOString();
  const fable = normalizeFableWindow(usage);
  return {
    provider: 'claude',
    fiveHour: normalizeOAuthWindow(usage?.five_hour),
    sevenDay: normalizeOAuthWindow(usage?.seven_day),
    fableWeekly: fable,
    fableWeeklyUpdatedAt: fable ? now : null,
    context: null,
    updatedAt: now,
    source: 'claude-statusline'
  };
}

export function snapshotFromStatusLine(input) {
  const now = new Date().toISOString();
  const fable = normalizeFableWindow(input.rate_limits);
  return {
    provider: 'claude',
    fiveHour: normalizeStatusLineWindow(input.rate_limits?.five_hour),
    sevenDay: normalizeStatusLineWindow(input.rate_limits?.seven_day),
    fableWeekly: fable,
    fableWeeklyUpdatedAt: fable ? now : null,
    context: normalizeContext(input.context_window),
    updatedAt: now,
    source: 'claude-statusline'
  };
}

function preserveCachedFable(snapshot) {
  if (snapshot.fableWeekly) return snapshot;
  try {
    const cached = JSON.parse(fs.readFileSync(path.join(usageMonitorRoot(), 'claude-status.json'), 'utf8'));
    const raw = cached.provider === 'claude' ? cached.fableWeekly : null;
    const window = normalizeOAuthWindow({ utilization: raw?.usedPercent, resets_at: raw?.resetsAt });
    const timestamp = Date.parse(cached.fableWeeklyUpdatedAt);
    // Status-line input may omit model quotas. Keep the sample, not a new timestamp.
    if (window?.usedPercent != null && Number.isFinite(timestamp) && timestamp <= Date.now()) {
      snapshot.fableWeekly = window;
      snapshot.fableWeeklyUpdatedAt = new Date(timestamp).toISOString();
    }
  } catch {
    // No usable cached model quota yet.
  }
  return snapshot;
}

function existingCommand() {
  const index = process.argv.indexOf('--existing-base64');
  if (index === -1 || !process.argv[index + 1]) return null;
  try {
    return Buffer.from(process.argv[index + 1], 'base64').toString('utf8');
  } catch {
    return null;
  }
}

function runExisting(command) {
  if (!command) return null;
  const result = spawnSync('/bin/zsh', ['-lc', command], {
    input: rawInput,
    encoding: 'utf8',
    timeout: 1500,
    maxBuffer: 1024 * 1024
  });
  if (result.error || result.status !== 0) return null;
  const output = result.stdout?.trimEnd();
  return output && output.length > 0 ? output : null;
}

function fallbackLine(snapshot) {
  const five = snapshot.fiveHour?.remainingPercent;
  const seven = snapshot.sevenDay?.remainingPercent;
  const parts = [];
  if (typeof five === 'number') parts.push(`5h ${Math.round(five)}% left`);
  if (typeof seven === 'number') parts.push(`7d ${Math.round(seven)}% left`);
  return parts.length ? `Claude ${parts.join(' | ')}` : '';
}

function summary(snapshot) {
  return JSON.stringify({
    fiveHourRemainingPercent: snapshot.fiveHour?.remainingPercent ?? null,
    sevenDayRemainingPercent: snapshot.sevenDay?.remainingPercent ?? null,
    fableWeeklyUsedPercent: snapshot.fableWeekly?.usedPercent ?? null,
    fableWeeklyResetsAt: snapshot.fableWeekly?.resetsAt ?? null,
    fiveHourResetsAt: snapshot.fiveHour?.resetsAt ?? null,
    sevenDayResetsAt: snapshot.sevenDay?.resetsAt ?? null,
    updatedAt: snapshot.updatedAt
  });
}

async function main() {
  rawInput = refreshOnly ? '' : fs.readFileSync(0, 'utf8');
  const input = parseInput(rawInput);
  let snapshot = refreshOnly ? null : snapshotFromStatusLine(input);
  const usesStatusLine = snapshotHasUsage(snapshot);

  if (!snapshotHasUsage(snapshot)) {
    try {
      snapshot = snapshotFromOAuthUsage(await fetchClaudeUsage());
    } catch (error) {
      debugError('claude-refresh', error);
      // Status-line commands must stay quiet on refresh failures.
    }
  }

  if (snapshotHasUsage(snapshot)) {
    try {
      if (usesStatusLine) snapshot = preserveCachedFable(snapshot);
      writeSnapshot(snapshot);
    } catch (error) {
      debugError('snapshot-write', error);
      // Status-line commands must stay quiet on write failures.
    }
  }

  if (refreshOnly) {
    if (printSummary && snapshotHasUsage(snapshot)) {
      process.stdout.write(`${summary(snapshot)}\n`);
    }
    return;
  }

  const preserved = runExisting(existingCommand());
  process.stdout.write(preserved ?? fallbackLine(snapshot ?? snapshotFromStatusLine(input)));
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => {
    debugError('bridge-main', error);
    if (!refreshOnly) process.stdout.write('');
  });
}
