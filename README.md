# Agent Traffic Light

[![CI](https://github.com/chenyueling/agent-traffic-light/actions/workflows/ci.yml/badge.svg)](https://github.com/chenyueling/agent-traffic-light/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-blue.svg)](Package.swift)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)

[简体中文](README.zh-CN.md)

A floating macOS traffic light for Codex, Claude, CodeBuddy, and other coding agents.

When an agent is working, the light turns green. When it needs your approval or input, it turns yellow. When it is idle, stopped, or in an error state, it returns to the red family. It is built for people who run multiple coding agents and want to know, at a glance, whether something is still working or quietly waiting for them.

![Agent Traffic Light demo](assets/demo.gif)

## Download

Download the latest app zip from GitHub Releases:

[Download AgentTrafficLight.zip](https://github.com/chenyueling/agent-traffic-light/releases/latest/download/AgentTrafficLight.zip)

Install it like a normal macOS app:

1. Unzip `AgentTrafficLight.zip`.
2. Move `AgentTrafficLight.app` to `/Applications`.
3. Open the app.
4. Right-click the floating light and choose **Install Hooks…**.

If macOS blocks the app, right-click `AgentTrafficLight.app`, choose **Open**, and confirm once. Current releases are ad-hoc signed but not notarized yet, so this is expected until Developer ID signed releases are available.

If macOS says the app is "damaged", delete the old app and zip, download the latest release again, and move it to `/Applications`. If it is still blocked by quarantine, run:

```bash
xattr -dr com.apple.quarantine /Applications/AgentTrafficLight.app
open /Applications/AgentTrafficLight.app
```

## Preview

The widget can stay compact, or expand on hover to show each agent independently.

![Agent Traffic Light compact preview](assets/preview-compact.png)

![Agent Traffic Light overview](assets/preview-overview.png)

The detail view shows the selected agent's state, reason, message, and working directory.

![Agent Traffic Light agent detail](assets/preview-agent.png)

## Features

- Tracks multiple agents independently: Codex, Claude, CodeBuddy, Gemini, Cursor, Windsurf, and custom agents.
- Aggregates all agents into one floating traffic light.
- Uses practical states: working, needs input, idle, and error.
- Installs lifecycle hooks for supported agents.
- Opens the related agent app from the widget when available.
- Detects quota, rate-limit, and 429-style failures, marking them as error instead of staying green forever.

## Status Colors

| Color | State | Meaning |
|---|---|---|
| Red | `idle` | The agent is stopped or waiting. |
| Green | `working` | The agent is actively working. |
| Yellow | `blocked` | Human input, approval, or permission is needed. |
| Red pulse | `error` | Error, quota limit, rate limit, or abnormal state. |

Aggregation rule:

```text
error / blocked > working > idle
```

If any agent needs attention, the main light shows it immediately.

## Quick Start

For most users:

1. Download [AgentTrafficLight.zip](https://github.com/chenyueling/agent-traffic-light/releases/latest/download/AgentTrafficLight.zip).
2. Unzip it and move `AgentTrafficLight.app` to `/Applications`.
3. Open the app. If macOS blocks it, right-click the app and choose **Open**.
4. Right-click the floating light and choose **Install Hooks…**.
5. If you use Codex, run `/hooks` inside Codex and trust the new hook.
6. Send a fresh prompt to your agent and verify the light changes.

Expected behavior:

- New prompt starts: green.
- Permission or input needed: yellow.
- Work finished: red/idle.
- Quota, 429, rate limit, or usage limit: error red.

If the light does not move, right-click it and choose **Diagnostics…**. You can also run:

```bash
/Applications/AgentTrafficLight.app/Contents/MacOS/AgentTrafficLight --diagnostics
```

## Developer Setup

Build and install from source:

```bash
make install
```

Then open:

```text
/Applications/AgentTrafficLight.app
```

Run from source during development:

```bash
swift run AgentTrafficLight
```

Create a distributable zip:

```bash
make dist
```

The zip is created at:

```text
.build/release/AgentTrafficLight.zip
```

> Current builds are arm64-only and ad-hoc signed. They are fine for local use or small trials. Public distribution should use a universal2 build, Developer ID signing, and notarization.

To publish a GitHub Release, push a version tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow will build and upload `AgentTrafficLight.zip`.

## Supported Integrations

The app installs hooks for configured agents:

| Agent | Hook file |
|---|---|
| Codex | `~/.codex/hooks.json` |
| Claude | `~/.claude/settings.json` |
| CodeBuddy | `~/.codebuddy/settings.json` |

Hook installation is explicit. The app does not silently modify these files on launch.

You can also install hooks from the command line:

```bash
swift run AgentTrafficLight --install-hooks
```

To remove hooks installed by Agent Traffic Light:

```bash
swift run AgentTrafficLight --uninstall-hooks
```

Or right-click the floating light and choose **Uninstall Hooks…**.

The installer and uninstaller create timestamped `.traffic-light.*.bak` backups before changing agent settings.

## Diagnostics

Use **Diagnostics…** when a signal does not arrive. The report checks:

- Local server and port.
- Config file.
- Hook script.
- Hook files for Codex, Claude, and CodeBuddy.
- Whether hooks are installed.
- Last known state and last signal time for each agent.

Click **Copy Report** in the diagnostics window when opening an issue.

## Manual Status Updates

Use the helper script:

```bash
./bin/agent-light-update working codex prompt "Codex started"
./bin/agent-light-update blocked claude permission "Claude needs approval"
./bin/agent-light-update idle codebuddy stop "CodeBuddy stopped"
```

Or post directly to the local HTTP server:

```bash
curl -s -X POST http://127.0.0.1:17361/status \
  -H 'Content-Type: application/json' \
  -d '{"state":"working","agent":"my-agent","reason":"prompt","message":"Processing..."}'
```

Read the current state:

```bash
curl -s http://127.0.0.1:17361/status
```

## Configuration

On first launch, the app creates:

```text
~/.agent-traffic-light/config.json
```

Example:

```json
{
  "port": 17361,
  "installHooksOnLaunch": false,
  "agents": [
    { "id": "codex", "displayName": "Codex" },
    { "id": "claude", "displayName": "Claude" },
    { "id": "codebuddy", "displayName": "CodeBuddy" }
  ]
}
```

Fields:

| Field | Meaning |
|---|---|
| `port` | Local HTTP server port. Restart after changing. |
| `installHooksOnLaunch` | Whether hooks should be installed on app launch. Default is `false`. |
| `agents` | Agents shown in the UI and accepted by the API. |

You can add a custom agent by adding a new `{ "id": "...", "displayName": "..." }` entry and posting updates with that `id`.

## Interaction

- Drag the compact light to move it.
- Release near an edge to snap it into place.
- Hover to expand details.
- Use tabs to inspect individual agents.
- Right-click for settings, hook installation, pinning, manual state changes, and quit.
- Choose **Open Agent** to open the related app when available.

## How It Works

Agent Traffic Light runs a tiny local server:

```text
http://127.0.0.1:17361/status
```

Agent hooks call a small shell script, which posts lifecycle events to that local server. The app keeps one state per agent and renders an aggregate traffic light.

```text
Agent hook -> traffic-light-hook.sh -> local HTTP server -> floating macOS UI
```

## System Requirements

- macOS 14.0+
- Swift 6.0 for building from source

## Roadmap

- Signed and notarized releases.
- Universal2 release builds.
- Homebrew cask.
- Tests for hook installation and status aggregation.

## License

MIT
