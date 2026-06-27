# Coding Agents Monitor

Native macOS floating usage monitor for Claude Code and Codex.

The widget is intentionally small and always-on-top. It shows the current 5-hour/session usage consumed for Claude Code and Codex, with Claude first because it is usually the primary daily driver. A calendar button expands the widget to show the less-important 7-day windows.

## What It Shows

- Claude Code and Codex 5-hour/session usage consumed, with relative and clock reset times.
- Optional 7-day usage consumed and reset times from the calendar button.
- Green usage bars below 70%, orange from 70% to 89%, and red from 90% upward.
- Bundled transparent PNG logos from `assets/claude-logo.png` and `assets/codex-logo.png`.
- Missing or stale state when local usage sources are unavailable.

## How It Works

- Codex: watches `~/.codex/sessions/**/rollout-*.jsonl` and parses appended `payload.type == "token_count"` events.
- Claude Code: installs a status-line bridge at `~/.usage-monitor/claude-statusline-bridge.mjs`, which writes sanitized usage data to `~/.usage-monitor/claude-status.json`.
- On launch, the app asks the installed bridge to seed Claude usage once from Claude Code's OAuth usage endpoint. The bridge reads Claude Code's macOS Keychain credential first, then falls back to `~/.claude/.credentials.json`.

The app stores only percentages, reset timestamps, context token counts, and update times. It does not store prompts, transcript content, OAuth tokens, or raw provider API responses.

## Requirements

- macOS 13 or newer.
- Swift toolchain or Xcode Command Line Tools.
- Node.js available at `/usr/bin/env node`.
- Claude Code already logged in with Claude.ai if Claude usage should appear immediately.
- Codex session logs under `~/.codex/sessions` if Codex usage should appear.

## Build And Launch

```sh
swift test
scripts/build_app.sh
open "outputs/Usage Monitor.app"
```

The app stays above other windows, can be dragged around, and remembers its position locally.

## Install Claude Bridge Only

The app installs or updates the Claude Code bridge on launch. To install it without opening the widget:

```sh
scripts/build_app.sh
"outputs/Usage Monitor.app/Contents/MacOS/UsageMonitor" --install-bridge-only
```

The installer updates `~/.claude/settings.json` and backs up any previous settings file before changing it. If a previous Claude Code `statusLine.command` exists, the bridge wraps and preserves it.

## Coding Agent Prompt

Use this prompt with a coding agent to install the monitor end-to-end on a Mac without extra back-and-forth:

```text
You are installing Coding Agents Monitor from a freshly cloned repository on macOS.

Goal: build, install, launch, and verify the native floating widget for Claude Code and Codex usage. Do not ask the user for choices unless a required prerequisite is missing or a macOS security prompt requires the user's manual approval.

Steps:
1. Confirm the machine is macOS and that `swift`, `node`, and `gh` are available. Do not install package managers. If Swift or Node is missing, stop with the exact missing prerequisite.
2. From the repository root, run `swift test`.
3. Run `node --check bridge/claude-statusline-bridge.mjs`.
4. Run `bash -n scripts/build_app.sh`.
5. Run `scripts/build_app.sh`.
6. Run `"outputs/Usage Monitor.app/Contents/MacOS/UsageMonitor" --install-bridge-only` to install or update the Claude Code status-line bridge. This may write `~/.usage-monitor/claude-statusline-bridge.mjs`, `~/.usage-monitor/claude-status.json`, and `~/.claude/settings.json`; preserve backups created by the installer.
7. Launch the widget with `open "outputs/Usage Monitor.app"`.
8. Verify the app is running. If you have GUI inspection available, confirm the compact widget shows Claude above Codex, uses provider logos instead of row names, and displays consumed 5-hour usage percentages with `resets in ... (...)` copy. If GUI inspection is not available, confirm a `UsageMonitor` process is running and `~/.usage-monitor/claude-status.json` exists when Claude Code credentials are available.
9. Leave the widget running in compact mode. Summarize the installed bridge path, app path, and verification results.

Safety rules:
- Do not store or print OAuth tokens, prompts, transcripts, or raw provider API responses.
- Do not overwrite a user's existing Claude Code status-line command; rely on the installer wrapper.
- Do not delete user files or build caches outside this repository.
- If Claude usage is unavailable, verify Codex still works and report that Claude Code must be logged in with Claude.ai.
```

## Development Checks

```sh
swift test
node --check bridge/claude-statusline-bridge.mjs
bash -n scripts/build_app.sh
```
