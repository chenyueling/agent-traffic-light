import AppKit
import Foundation

struct DetectedAgent {
    let id: String
    let displayName: String
    let source: String

    func toConfig() -> AgentConfig {
        AgentConfig(id: id, displayName: displayName)
    }
}

enum AgentDetector {

    static func detect() -> [DetectedAgent] {
        var found: [DetectedAgent] = []

        // CodeBuddy (various editions)
        if let _ = findApp("CodeBuddy CN") ?? findApp("CodeBuddy") {
            found.append(DetectedAgent(id: "codebuddy", displayName: "CodeBuddy", source: "App"))
        } else if let _ = findApp(matching: "CodeBuddy") {
            found.append(DetectedAgent(id: "codebuddy", displayName: "CodeBuddy", source: "App"))
        }

        // Claude
        if let _ = findApp("Claude") {
            found.append(DetectedAgent(id: "claude", displayName: "Claude", source: "App"))
        }

        // OpenAI Codex
        if let _ = findCLI("codex") {
            found.append(DetectedAgent(id: "codex", displayName: "Codex", source: "CLI"))
        }

        // Gemini CLI
        if let _ = findCLI("gemini") {
            found.append(DetectedAgent(id: "gemini", displayName: "Gemini", source: "CLI"))
        }

        // GitHub Copilot (VS Code extension - check for copilot CLI)
        if let _ = findCLI("github-copilot-cli") {
            found.append(DetectedAgent(id: "copilot", displayName: "Copilot", source: "CLI"))
        }

        // Cursor
        if let _ = findApp("Cursor") {
            found.append(DetectedAgent(id: "cursor", displayName: "Cursor", source: "App"))
        }

        // Windsurf
        if let _ = findApp("Windsurf") {
            found.append(DetectedAgent(id: "windsurf", displayName: "Windsurf", source: "App"))
        }

        // If nothing found, provide defaults
        if found.isEmpty {
            found = [
                DetectedAgent(id: "codex", displayName: "Codex", source: "default"),
                DetectedAgent(id: "claude", displayName: "Claude", source: "default"),
                DetectedAgent(id: "codebuddy", displayName: "CodeBuddy", source: "default"),
            ]
        }

        return found
    }

    static func findApp(_ name: String) -> String? {
        let paths: [String] = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications",
        ]
        let fm = FileManager.default
        for base in paths {
            let path = "\(base)/\(name).app"
            if fm.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func findApp(matching: String) -> String? {
        for base in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for item in contents where item.lowercased().contains(matching.lowercased()) && item.hasSuffix(".app") {
                return "\(base)/\(item)"
            }
        }
        return nil
    }

    static func findCLI(_ name: String) -> String? {
        // Check known paths first
        for base in ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/opt/homebrew/opt"] {
            let path = "\(base)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback to which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let data = try? (process.standardOutput as! Pipe).fileHandleForReading.readToEnd(),
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return nil
    }
}
