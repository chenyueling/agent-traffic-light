import Foundation

struct AgentConfig: Codable {
    var id: String
    var displayName: String
}

struct AppConfig: Codable, @unchecked Sendable {
    var port: UInt16 = 17361
    var agents: [AgentConfig] = []
    var installHooksOnLaunch: Bool = false

    enum CodingKeys: String, CodingKey {
        case port
        case agents
        case installHooksOnLaunch
    }

    init(port: UInt16 = 17361, agents: [AgentConfig] = [], installHooksOnLaunch: Bool = false) {
        self.port = port
        self.agents = agents
        self.installHooksOnLaunch = installHooksOnLaunch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 17361
        agents = try container.decodeIfPresent([AgentConfig].self, forKey: .agents) ?? []
        installHooksOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .installHooksOnLaunch) ?? false
    }

    static let configDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-traffic-light")
    }()

    static let configFile: URL = {
        configDir.appendingPathComponent("config.json")
    }()

    static func load() -> AppConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: configFile),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data),
           !config.agents.isEmpty {
            print("Loaded config from \(configFile.path) with \(config.agents.count) agents")
            return config
        }
        // Auto-detect agents on first launch
        let detected = AgentDetector.detect()
        let defaults = AppConfig(agents: detected.map { $0.toConfig() })
        write(defaults)
        print("Auto-detected \(detected.count) agents: \(detected.map { "\($0.displayName)(\($0.source))" }.joined(separator: ", "))")
        return defaults
    }

    static func write(_ config: AppConfig) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configFile, options: .atomic)
        }
    }

    var agentDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.displayName) })
    }

    var preferredOrder: [String] {
        agents.map { $0.id }
    }
}
