# Agent Traffic Light

一个 macOS 悬浮 Agent 状态灯，支持多 Agent（Codex、Claude、CodeBuddy 等）独立状态显示。

## 快速开始

### 方式一：安装 .app

```bash
cd agent-traffic-light
make install   # 构建并安装到 /Applications
```

然后双击 `/Applications/AgentTrafficLight.app` 即可运行。

### 方式二：源码运行（开发者）

```bash
cd agent-traffic-light
swift run AgentTrafficLight
```

### 方式三：仅构建不分发

```bash
make build    # 构建 .app
make run      # 构建并启动
make dist     # 构建并打包 .zip
```

> 当前构建默认是 Apple Silicon / arm64，且没有签名/公证。自用或小范围测试可以，正式发给别人前建议做 universal2 构建、Developer ID 签名和 notarization，否则 macOS Gatekeeper 可能拦截。

## 给别人使用的推荐流程

1. 构建分发包：

```bash
make dist
```

产物在 `.build/release/AgentTrafficLight.zip`。

2. 对方解压后把 `AgentTrafficLight.app` 拖到 `/Applications`，首次打开 app。

3. 右键悬浮灯 → **Settings…**，确认自动识别到的 Agent 列表符合预期。

4. 右键悬浮灯 → **Install Hooks…**，显式写入 Codex / Claude / CodeBuddy hooks。

5. 如果使用 Codex，安装后在 Codex 里执行 `/hooks`，review/trust 新增 hook。

6. 发一条新 prompt 验证：

- 开始工作时应变绿
- 需要权限或人工输入时应变黄
- 正常结束后应变红/空闲
- 额度不足、rate limit、429 等错误应变为异常红色

## 配置

### 自动检测

首次启动会自动扫描系统已安装的 Agent（CodeBuddy、Claude、Codex、Gemini、Cursor 等），写入 `~/.agent-traffic-light/config.json`，开箱即用。

启动时只会初始化本工具自己的配置，不会静默改写 Claude / Codex / CodeBuddy 的配置。

### 可视化设置

右键悬浮灯 → **Settings…**（⌘,），可以：
- 查看/编辑 Agent 列表
- **Rescan** 重新扫描系统
- **Add/Remove** 增减 Agent
- 双击修改显示名称，保存即时生效

### 手动编辑

配置文件 `~/.agent-traffic-light/config.json`：

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

你可以自由修改：
- `port`：HTTP 服务端口（改后重启生效）
- `installHooksOnLaunch`：是否启动时自动安装 hooks，默认 `false`
- `agents`：要监控的 Agent 列表，`id` 是 API 中使用的标识，`displayName` 是 UI 显示名
- 新增 Agent 只需加一条 `{"id": "...", "displayName": "..."}`

## 更新状态

```bash
# 使用便捷脚本（自动读取配置端口）
./bin/agent-light-update working codex prompt "Codex started"
./bin/agent-light-update blocked claude permission "Claude needs approval"
./bin/agent-light-update idle codebuddy stop "CodeBuddy stopped"

# 直接 curl
curl -s -X POST http://127.0.0.1:17361/status \
  -H 'Content-Type: application/json' \
  -d '{"state":"working","agent":"my-agent","reason":"prompt","message":"Processing..."}'

# Demo 路由
curl -s http://127.0.0.1:17361/demo/working
```

## 四状态 / 三颜色

| 状态 | 颜色 | 含义 |
|---|---|---|
| `idle` | 🔴 红 | Agent 停止或空闲 |
| `working` | 🟢 绿 | Agent 正在工作 |
| `blocked` | 🟡 黄 | 需要人工介入 |
| `error` | 红（脉冲） | 异常状态 |

## 交互

- 拖动悬浮灯可移动，松手吸附屏幕边缘
- 鼠标悬停展开详情（Agent 列表、状态、工作目录）
- 双击 Agent 内容区可打开对应终端/应用
- 右键菜单：Pin/Unpin、手动切状态、退出

## 多 Agent 聚合规则

- 每个 Agent 独立保存状态，互不覆盖
- 聚合灯优先级：`error/blocked` > `working` > `idle`
- 任意 Agent `blocked/error` 显示黄/异常，任意 `working` 显示绿，全部 `idle` 显示红

## 集成到 Agent Hooks

显式安装 hooks：

```bash
swift run AgentTrafficLight --install-hooks
```

安装后会修改已配置 agent 的 hook 文件，并创建备份：

- Codex：`~/.codex/hooks.json`
- Claude：`~/.claude/settings.json`
- CodeBuddy：`~/.codebuddy/settings.json`

Codex 安装后需要在 Codex 里执行 `/hooks` review/trust 新 hook，否则 Codex 会跳过未信任 hook。

以 CodeBuddy 为例，在 `~/.codebuddy/settings.json` 中配置 hooks：

```json
{
  "hooks": {
    "UserPromptSubmit": [{
      "hooks": [{
        "command": "/path/to/agent-light-update working codebuddy prompt 'User submitted'",
        "timeout": 10,
        "type": "command"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "command": "/path/to/agent-light-update idle codebuddy stop 'Processing done'",
        "timeout": 10,
        "type": "command"
      }]
    }]
  }
}
```

## 系统要求

- macOS 14.0+
- Swift 6.0（仅构建需要，运行不需要）

## License

MIT
