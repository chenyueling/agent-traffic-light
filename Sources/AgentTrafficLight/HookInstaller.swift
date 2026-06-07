import Foundation

enum HookInstaller {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let hooksDir = "\(home)/.agent-traffic-light/hooks"
    private static let hookScriptPath = "\(hooksDir)/traffic-light-hook.sh"

    // MARK: - Agent Hook Configs

    struct AgentHookTarget {
        let settingsPath: String
        let agentId: String
    }

    static func targets() -> [String: AgentHookTarget] {
        [
            "codex": AgentHookTarget(
                settingsPath: "\(home)/.codex/hooks.json",
                agentId: "codex"
            ),
            "codebuddy": AgentHookTarget(
                settingsPath: "\(home)/.codebuddy/settings.json",
                agentId: "codebuddy"
            ),
            "claude": AgentHookTarget(
                settingsPath: "\(home)/.claude/settings.json",
                agentId: "claude"
            ),
        ]
    }

    // MARK: - Public API

    /// Install hooks for all detected agents that have settings files.
    /// Safe to call repeatedly (idempotent), but should only be called from explicit user action.
    static func installForDetectedAgents(_ detected: [DetectedAgent]) {
        ensureHookScript()
        var installed: [String] = []
        for agent in detected {
            guard let target = targets()[agent.id],
                  FileManager.default.fileExists(atPath: target.settingsPath) else { continue }
            if install(for: target) {
                installed.append(agent.displayName)
            }
        }
        if !installed.isEmpty {
            print("Traffic Light hooks installed for: \(installed.joined(separator: ", "))")
        }
    }

    static func installForAgentIDs(_ agentIDs: [String]) {
        ensureHookScript(force: true)
        var installed: [String] = []
        for agentID in agentIDs {
            guard let target = targets()[agentID] else { continue }
            ensureSettingsFileIfSupported(target)
            guard FileManager.default.fileExists(atPath: target.settingsPath) else { continue }
            if install(for: target) {
                installed.append(agentID)
            }
        }
        if !installed.isEmpty {
            print("Traffic Light hooks installed for: \(installed.joined(separator: ", "))")
        }
    }

    static func prepareHookScript() {
        ensureHookScript(force: true)
    }

    /// Check if hooks are already configured for a given agent.
    static func isInstalled(for agentId: String) -> Bool {
        guard let target = targets()[agentId],
              FileManager.default.fileExists(atPath: target.settingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        return hookEntryExists(in: hooks, event: "Stop", agentId: agentId) &&
               hookEntryExists(in: hooks, event: "UserPromptSubmit", agentId: agentId) &&
               hookEntryExists(in: hooks, event: "PermissionRequest", agentId: agentId)
    }

    // MARK: - Internal

    private static func install(for target: AgentHookTarget) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️  Cannot read \(target.settingsPath)")
            return false
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let events = hookEvents(for: target.agentId)

        var changed = false
        for spec in events {
            let event = spec.event
            var eventList = hooks[event] as? [[String: Any]] ?? []
            let command = hookCommand(for: target.agentId, spec: spec)
            if hasOnlyCanonicalTrafficEntry(in: eventList, agentId: target.agentId, command: command, matcher: spec.matcher) {
                continue
            }

            let cleaned = removeTrafficLightEntries(from: eventList, agentId: target.agentId)
            if cleaned.count != eventList.count {
                changed = true
            }

            let entry: [String: Any] = [
                "hooks": [
                    [
                        "command": command,
                        "timeout": 10,
                        "type": "command"
                    ]
                ]
            ]
            if let matcher = spec.matcher {
                var mutableEntry = entry
                mutableEntry["matcher"] = matcher
                eventList = cleaned
                eventList.append(mutableEntry)
                hooks[event] = eventList
                changed = true
                continue
            }

            eventList = cleaned
            eventList.append(entry)
            hooks[event] = eventList
            changed = true
        }

        guard changed else { return false }

        json["hooks"] = hooks

        // Backup original
        let backupPath = target.settingsPath + ".traffic-light.\(Int(Date().timeIntervalSince1970)).bak"
        try? data.write(to: URL(fileURLWithPath: backupPath))

        // Write updated
        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? newData.write(to: URL(fileURLWithPath: target.settingsPath), options: .atomic)
            print("✅ Hooks installed for \(target.agentId) → \(target.settingsPath)")
            return true
        }
        return false
    }

    private static func removeTrafficLightEntries(from list: [[String: Any]], agentId: String) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for group in list {
            guard let items = group["hooks"] as? [[String: Any]] else {
                result.append(group)
                continue
            }
            let filteredItems = items.filter { item in
                guard let cmd = item["command"] as? String else { return true }
                return !(cmd.contains(hookScriptPath) && cmd.contains(agentId))
            }
            if filteredItems.isEmpty { continue }
            var newGroup = group
            newGroup["hooks"] = filteredItems
            result.append(newGroup)
        }
        return result
    }

    private static func hasOnlyCanonicalTrafficEntry(in list: [[String: Any]], agentId: String, command: String, matcher: String?) -> Bool {
        var foundCanonical = false
        for group in list {
            let groupMatcher = group["matcher"] as? String
            guard groupMatcher == matcher else { continue }
            guard let items = group["hooks"] as? [[String: Any]] else { continue }
            for item in items {
                guard let cmd = item["command"] as? String else { continue }
                guard cmd.contains(hookScriptPath), cmd.contains(agentId) else { continue }
                if cmd == command {
                    foundCanonical = true
                } else {
                    return false
                }
            }
        }
        return foundCanonical
    }

    private static func hookCommand(for agentId: String, spec: HookEventSpec) -> String {
        [
            shellQuote(hookScriptPath),
            shellQuote(spec.state),
            shellQuote(agentId),
            shellQuote(spec.reason),
            shellQuote(spec.message),
        ].joined(separator: " ")
    }

    private static func hookEntryExists(in hooks: [String: Any], event: String, agentId: String) -> Bool {
        guard let list = hooks[event] as? [[String: Any]] else { return false }
        for group in list {
            guard let items = group["hooks"] as? [[String: Any]] else { continue }
            for item in items {
                if let cmd = item["command"] as? String,
                   cmd.contains(hookScriptPath),
                   cmd.contains(agentId) {
                    return true
                }
            }
        }
        return false
    }

    private struct HookEventSpec {
        let event: String
        let state: String
        let reason: String
        let message: String
        let matcher: String?
    }

    private static func hookEvents(for agentId: String) -> [HookEventSpec] {
        var events = [
            HookEventSpec(event: "UserPromptSubmit", state: "working", reason: "prompt", message: "User submitted prompt", matcher: nil),
            HookEventSpec(event: "PermissionRequest", state: "blocked", reason: "permission", message: "Permission required", matcher: "*"),
            HookEventSpec(event: "Stop", state: "idle", reason: "stop", message: "Processing done", matcher: nil),
        ]
        if agentId == "claude" || agentId == "codebuddy" {
            events.append(HookEventSpec(event: "Elicitation", state: "blocked", reason: "input", message: "Input required", matcher: nil))
        }
        if agentId == "codex" {
            events.append(HookEventSpec(event: "PreToolUse", state: "working", reason: "tool", message: "Tool running", matcher: "*"))
        }
        return events
    }

    private static func ensureSettingsFileIfSupported(_ target: AgentHookTarget) {
        guard target.agentId == "codex" else { return }
        let url = URL(fileURLWithPath: target.settingsPath)
        if FileManager.default.fileExists(atPath: target.settingsPath) { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let initial = ["hooks": [:]] as [String: Any]
        if let data = try? JSONSerialization.data(withJSONObject: initial, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Hook Script

    private static let hookScriptContent = """
    #!/usr/bin/env bash
    # Agent Traffic Light — generic hook script
    # Installed by AgentTrafficLight.app — do not edit manually
    set -euo pipefail

    STATE="${1:-working}"
    AGENT="${2:-agent}"
    REASON="${3:-hook}"
    MESSAGE="${4:-}"
    CWD_VALUE="${PWD:-}"
    if [ -t 0 ]; then
        HOOK_INPUT=""
    else
        HOOK_INPUT="$(cat || true)"
    fi

    CONFIG_FILE="$HOME/.agent-traffic-light/config.json"
    PORT=17361
    if [ -f "$CONFIG_FILE" ]; then
        PORT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('port',17361))" "$CONFIG_FILE" 2>/dev/null || echo 17361)
    fi

    PAYLOAD=$(STATE="$STATE" AGENT="$AGENT" REASON="$REASON" MESSAGE="$MESSAGE" CWD_VALUE="$CWD_VALUE" HOOK_INPUT="$HOOK_INPUT" python3 - <<'PY'
    import json
    import os
    state = os.environ.get("STATE", "working")
    reason = os.environ.get("REASON", "hook")
    message = os.environ.get("MESSAGE", "")
    hook_input = os.environ.get("HOOK_INPUT", "")
    haystack = " ".join([reason, message, hook_input]).lower()
    quota_patterns = [
        "quota", "rate limit", "rate-limit", "usage limit", "credit",
        "insufficient", "billing", "exceeded", "429", "额度", "限额", "余额不足"
    ]
    if any(pattern in haystack for pattern in quota_patterns):
        state = "error"
        reason = "quota"
        message = "Quota or rate limit reached"
    print(json.dumps({
        "state": state,
        "agent": os.environ.get("AGENT", "agent"),
        "reason": reason,
        "message": message,
        "cwd": os.environ.get("CWD_VALUE", ""),
        "openApp": os.environ.get("AGENT_LIGHT_OPEN_APP", ""),
        "bundleId": os.environ.get("AGENT_LIGHT_BUNDLE_ID", ""),
        "openURL": os.environ.get("AGENT_LIGHT_OPEN_URL", ""),
        "openCommand": os.environ.get("AGENT_LIGHT_OPEN_COMMAND", ""),
    }))
    PY
    )

    curl -s --max-time 2 -X POST "http://127.0.0.1:$PORT/status" \\
      -H 'Content-Type: application/json' \\
      -d "$PAYLOAD" \\
      >/dev/null 2>&1 || true

    exit 0
    """

    private static func ensureHookScript(force: Bool = false) {
        // Create hooks directory
        try? FileManager.default.createDirectory(atPath: hooksDir, withIntermediateDirectories: true, attributes: nil)

        // Check if script already exists with correct content
        if !force, FileManager.default.fileExists(atPath: hookScriptPath) {
            if let existing = try? String(contentsOfFile: hookScriptPath, encoding: .utf8),
               existing.contains("Installed by AgentTrafficLight.app") {
                return // Already up to date
            }
        }

        // Write the script
        try? hookScriptContent.write(toFile: hookScriptPath, atomically: true, encoding: .utf8)

        // Make executable
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", hookScriptPath]
        try? chmod.run()
        chmod.waitUntilExit()

        print("📜 Hook script installed at \(hookScriptPath)")
    }
}
