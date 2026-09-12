<div align="center">

# Coding Agents Monitor

<img height="118" alt="image" src="https://github.com/user-attachments/assets/1d6aae87-6a07-4fbd-84c4-29b6b0dcc1b5" />



A tiny always-on-top macOS widget for keeping an eye on Claude Code and Codex usage before you run out mid-flow.

**Privacy Note**: Codex account limits are fetched through your installed Codex CLI and its existing login. Claude uses its local bridge. Prompts, transcripts, OAuth tokens, and raw provider API responses are not stored by the widget.

<p>
<a href="https://www.linkedin.com/in/sahar-mor/" target="_blank"><img src="https://img.shields.io/badge/LinkedIn-Connect-blue" alt="LinkedIn"></a>
<a href="https://x.com/theaievangelist" target="_blank"><img src="https://img.shields.io/twitter/follow/:theaievangelist" alt="X"></a>
<a href="http://aitidbits.ai/" target="_blank"><img src="https://github.com/saharmor/saharmor.github.io/blob/main/images/ai%20tidbits%20logo.png?raw=true" alt="Stay updated on AI" width="20" height="20" style="vertical-align: middle;"> Stay updated on AI</a>
</p>

</div>

## Features

- **Claude first**: Claude Code appears first because it is usually the daily driver.
- **Usage at a glance**: See consumed 5-hour usage and its reset time, falling back to the 7-day limit when no 5-hour limit is reported.
- **Fable weekly at a glance**: Claude's compact reading includes Fable weekly usage in parentheses, for example `4%(59%) 2h`. The time remains the main window's reset countdown. Fable gets its own row in the expanded weekly view and its own freshness timestamp; stale model readings show `--`, never a guessed zero.
- **Weekly view on demand**: Click the calendar button to expand the less-important 7-day windows.
- **Fresh Codex account limits**: A quota-only account request runs on launch, once per minute, on wake, and when expanding the widget (throttled to at most once every 10 seconds).
- **Claude cache fallback**: The tiny Claude cache file is checked every 15 seconds, and only parsed if its size or modified time changed.
- **Actual Claude refresh**: Claude usage is refreshed through the installed bridge once per minute so the widget matches Claude Code's Account & Usage panel.
- **Resets without chat activity**: Codex account resets are detected without waiting for a new conversation or reading session history. A known reset also schedules a refresh near its deadline.
- **Lightweight clock tick**: Reset labels update every 30 seconds without rereading token logs.
- **Launches at login**: The app registers a small LaunchAgent so the widget comes back after restart/login.
- **Honest stale states**: Readings older than two minutes or past their reset are hidden and marked stale. Failed account checks time out after 15 seconds and retry with backoff up to five minutes; only one request can run at a time.

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

- **Codex**: Opens a short-lived `codex app-server` connection and calls [`account/rateLimits/read`](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt). It selects the `codex` bucket by ID and maps windows by duration. Each request exits afterward; no model turn is created and no session tree is scanned. Old logs cannot overwrite an account reset.
- **Claude Code**: Installs a status-line bridge at `~/.usage-monitor/claude-statusline-bridge.mjs`, which writes sanitized usage data to `~/.usage-monitor/claude-status.json`.
- **Actual usage refresh**: On launch and then once per minute, the app asks the bridge to refresh Claude usage from Claude Code's OAuth usage endpoint.
- **Missed-event recovery**: Claude's cache is checked on the next 15-second check if macOS drops an event. Codex refreshes directly from its account service, including usage from other sessions or devices, as reported by the service.
- **No transcript storage**: The app stores only usage percentages, reset timestamps, context token counts, and update times.

## Requirements

- macOS 13 or newer
- Swift toolchain or Xcode Command Line Tools
- Node.js available at `/usr/bin/env node`
- Claude Code already logged in with Claude.ai if Claude usage should appear immediately
- Codex CLI installed and signed in with ChatGPT. PATH, Homebrew, `~/.local/bin`, nvm installations, and the standard Codex app bundle are checked. Set `USAGE_MONITOR_CODEX_PATH` to an executable path for a custom installation.

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
node --test bridge/claude-statusline-bridge.test.mjs
bash -n scripts/build_app.sh
"outputs/Usage Monitor.app/Contents/MacOS/UsageMonitor" --check-codex-usage
```

## Coding Agent Prompt

Copy-paste this prompt into Claude Code, Codex, Cursor, or any coding agent to install the monitor end-to-end on a Mac:

```text
You are installing Coding Agents Monitor from a freshly cloned repository on macOS.

Goal: build, install, launch, and verify the native floating widget for Claude Code and Codex usage. Do not ask the user for choices unless a required prerequisite is missing or a macOS security prompt requires the user's manual approval.

Steps:
1. Confirm the machine is macOS and that `swift`, `node`, and Codex CLI are available. Codex must already be logged in with ChatGPT. Do not install package managers. If a prerequisite is missing, report the exact prerequisite.
2. From the repository root, run `swift test`.
3. Run `node --check bridge/claude-statusline-bridge.mjs`.
4. Run `bash -n scripts/build_app.sh`.
5. Run `scripts/build_app.sh`.
6. Run `"outputs/Usage Monitor.app/Contents/MacOS/UsageMonitor" --install-bridge-only` to install or update the Claude Code status-line bridge. This may write `~/.usage-monitor/claude-statusline-bridge.mjs`, `~/.usage-monitor/claude-status.json`, and `~/.claude/settings.json`; preserve backups created by the installer.
7. Launch the widget with `open "outputs/Usage Monitor.app"`.
8. Run `"outputs/Usage Monitor.app/Contents/MacOS/UsageMonitor" --check-codex-usage` to verify a live Codex account reading (sanitized usage fields only). Verify the running widget shows Claude above Codex, provider logos, and consumed usage with reset times. A weekly-only account must show `7d`. Wait for a minute to verify an automatic account refresh without creating a chat. If GUI inspection is unavailable, report that limit and verify the diagnostic command and Claude cache instead.
9. Leave the widget running in compact mode. Summarize the installed bridge path, app path, and verification results.

Safety rules:
- Do not store or print OAuth tokens, prompts, transcripts, or raw provider API responses.
- Do not overwrite a user's existing Claude Code status-line command; rely on the installer wrapper.
- Do not delete user files or build caches outside this repository.
- If Claude usage is unavailable, verify Codex still works and report that Claude Code must be logged in with Claude.ai.
```

## Connect

Built by [Sahar Mor](https://www.linkedin.com/in/sahar-mor/) • Follow [@theaievangelist](https://x.com/theaievangelist) • [Stay updated on AI](http://aitidbits.ai/)
