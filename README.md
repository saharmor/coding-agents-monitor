<div align="center">

# Coding Agents Monitor

A tiny always-on-top macOS widget for keeping an eye on Claude Code and Codex usage before you run out mid-flow.

**Privacy Note**: Usage is read from local Codex and Claude Code signals. Prompts, transcripts, OAuth tokens, and raw provider API responses are not stored by the widget.

<p>
<a href="https://www.linkedin.com/in/sahar-mor/" target="_blank"><img src="https://img.shields.io/badge/LinkedIn-Connect-blue" alt="LinkedIn"></a>
<a href="https://x.com/theaievangelist" target="_blank"><img src="https://img.shields.io/twitter/follow/:theaievangelist" alt="X"></a>
<a href="http://aitidbits.ai/" target="_blank"><img src="https://github.com/saharmor/saharmor.github.io/blob/main/images/ai%20tidbits%20logo.png?raw=true" alt="Stay updated on AI" width="20" height="20" style="vertical-align: middle;"> Stay updated on AI</a>
</p>

</div>

## Features

- **Claude first**: Claude Code appears first because it is usually the daily driver.
- **5-hour usage at a glance**: See consumed session usage and the next reset time.
- **Weekly view on demand**: Click the calendar button to expand the less-important 7-day windows.
- **Local-first updates**: Codex and Claude usage files are watched locally; the app does not poll providers on a loop.
- **Lightweight clock tick**: Reset labels update every 30 seconds without rereading token logs.
- **Launches at login**: The app registers a small LaunchAgent so the widget comes back after restart/login.
- **Honest stale states**: If a reset passes before a fresh local sample arrives, the row shows `waiting for update` instead of inventing a number.

## Quick Start

```bash
git clone https://github.com/saharmor/Coding-Agents-Monitor.git
cd Coding-Agents-Monitor
swift test
scripts/build_app.sh
open "outputs/Usage Monitor.app"
```

The widget stays above other windows, can be dragged around, and remembers its position locally.
When launched from the `.app`, it also registers itself to open at login.

## How It Works

- **Codex**: Watches `~/.codex/sessions/**/rollout-*.jsonl` and parses appended `payload.type == "token_count"` events.
- **Claude Code**: Installs a status-line bridge at `~/.usage-monitor/claude-statusline-bridge.mjs`, which writes sanitized usage data to `~/.usage-monitor/claude-status.json`.
- **Startup seed**: On launch, the app asks the bridge to seed Claude usage once from Claude Code's OAuth usage endpoint. After that, it relies on local file changes.
- **No transcript storage**: The app stores only usage percentages, reset timestamps, context token counts, and update times.

## Requirements

- macOS 13 or newer
- Swift toolchain or Xcode Command Line Tools
- Node.js available at `/usr/bin/env node`
- Claude Code already logged in with Claude.ai if Claude usage should appear immediately
- Codex session logs under `~/.codex/sessions` if Codex usage should appear

## Install Claude Bridge Only

The app installs or updates the Claude Code bridge on launch. To install it without opening the widget:

```bash
scripts/build_app.sh
"outputs/Usage Monitor.app/Contents/MacOS/UsageMonitor" --install-bridge-only
```

The installer updates `~/.claude/settings.json` and backs up any previous settings file before changing it. If a previous Claude Code `statusLine.command` exists, the bridge wraps and preserves it.

## Development Checks

```bash
swift test
node --check bridge/claude-statusline-bridge.mjs
bash -n scripts/build_app.sh
```

## Coding Agent Prompt

Copy-paste this prompt into Claude Code, Codex, Cursor, or any coding agent to install the monitor end-to-end on a Mac:

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

## Connect

Built by [Sahar Mor](https://www.linkedin.com/in/sahar-mor/) • Follow [@theaievangelist](https://x.com/theaievangelist) • [Stay updated on AI](http://aitidbits.ai/)
