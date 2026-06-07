# Agent Traffic Light

一个 macOS 悬浮状态灯，用红 / 黄 / 绿显示 Codex、Claude、CodeBuddy 等 Coding Agent 的实时工作状态。

当 agent 正在跑，灯是绿色；需要你批准权限或继续输入，灯变黄色；停止、空闲或异常时，灯会回到红色系。它适合同时开多个 coding agent、经常被“agent 其实已经卡住了”打断节奏的人。

![Agent Traffic Light compact preview](assets/preview-compact.png)

## Preview

悬浮灯可以保持紧凑，也可以悬停展开查看每个 agent 的独立状态。

![Agent Traffic Light overview](assets/preview-overview.png)

单个 agent 的详情页会显示状态、原因、消息和当前工作目录。

![Agent Traffic Light agent detail](assets/preview-agent.png)

## What It Does

- Tracks multiple agents independently: Codex, Claude, CodeBuddy, Gemini, Cursor, Windsurf and custom agents.
- Aggregates all agents into one floating traffic light.
- Shows three practical states: working, needs input, idle/error.
- Installs lifecycle hooks for supported agents.
- Opens the related agent app when you choose **Open Agent**.
- Detects quota/rate-limit style failures and marks them as error instead of staying green forever.

## Status Colors

| Color | State | Meaning |
|---|---|---|
| Red | `idle` | Agent is stopped or waiting. |
| Green | `working` | Agent is actively working. |
| Yellow | `blocked` | Human input, approval, or permission is needed. |
| Red pulse | `error` | Error, quota limit, rate limit, or abnormal state. |

Aggregation rule:

```text
error / blocked > working > idle
```

If any agent needs attention, the main light tells you immediately.

## Quick Start

Build and install the app:

```bash
make install
```

Then open:

```text
/Applications/AgentTrafficLight.app
```

For development:

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

> Current builds are arm64-only and unsigned. This is fine for local use or small trials, but public distribution should use a universal2 build, Developer ID signing, and notarization.

## First-Time Setup

1. Open `AgentTrafficLight.app`.
2. Right-click the floating light and choose **Settings…**.
3. Confirm the detected agents.
4. Right-click the floating light and choose **Install Hooks…**.
5. If using Codex, run `/hooks` inside Codex and trust the new hook.
6. Send a fresh prompt to your agent and verify the light changes.

Expected behavior:

- New prompt starts: green.
- Permission or input needed: yellow.
- Work finished: red/idle.
- Quota, 429, rate limit, or usage limit: error red.

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

## License

MIT
