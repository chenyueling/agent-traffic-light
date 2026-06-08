import AppKit
import Darwin
import Foundation
import Network

enum AgentState: String, Codable {
    case idle
    case working
    case blocked
    case error

    var title: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Needs input"
        case .error: "Error"
        }
    }

    var activeIndex: Int {
        switch self {
        case .idle, .error: 0
        case .blocked: 1
        case .working: 2
        }
    }

    var color: NSColor {
        switch self {
        case .idle: NSColor(calibratedRed: 0.95, green: 0.12, blue: 0.16, alpha: 1)
        case .working: NSColor(calibratedRed: 0.18, green: 1.0, blue: 0.44, alpha: 1)
        case .blocked: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.12, alpha: 1)
        case .error: NSColor(calibratedRed: 1.0, green: 0.20, blue: 0.08, alpha: 1)
        }
    }
}

struct AgentStatus: Codable {
    var state: AgentState
    var agent: String
    var reason: String
    var message: String
    var cwd: String
    var openApp: String?
    var bundleId: String?
    var openURL: String?
    var openCommand: String?
    var updatedAt: Date
}

struct StatusSnapshot: Codable {
    var aggregate: AgentStatus
    var agents: [AgentStatus]
}

enum AgentDefaults {
    static func openApp(for agent: String) -> String? {
        switch agent.lowercased() {
        case "codex": return AgentDetector.findApp("Codex") == nil ? nil : "Codex"
        case "claude": return AgentDetector.findApp("Claude") == nil ? nil : "Claude"
        case "codebuddy":
            if AgentDetector.findApp("CodeBuddy CN") != nil { return "CodeBuddy CN" }
            if AgentDetector.findApp("CodeBuddy") != nil { return "CodeBuddy" }
            return AgentDetector.findApp(matching: "CodeBuddy").flatMap { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        case "cursor": return AgentDetector.findApp("Cursor") == nil ? nil : "Cursor"
        case "windsurf": return AgentDetector.findApp("Windsurf") == nil ? nil : "Windsurf"
        default: return nil
        }
    }

    static func bundleId(for agent: String) -> String? {
        switch agent.lowercased() {
        case "codex": return AgentDetector.findApp("Codex") == nil ? nil : "com.openai.codex"
        case "claude": return AgentDetector.findApp("Claude") == nil ? nil : "com.anthropic.claudefordesktop"
        case "codebuddy":
            if AgentDetector.findApp("CodeBuddy CN") != nil { return "com.tencent.codebuddycn" }
            return nil
        default: return nil
        }
    }
}

final class StatusStore: @unchecked Sendable {
    static let shared = StatusStore()

    private let lock = NSLock()
    private(set) var agentDisplayNames: [String: String] = [:]
    private(set) var preferredOrder: [String] = []

    func configure(with config: AppConfig) {
        lock.lock()
        defer { lock.unlock() }
        agentDisplayNames = config.agentDisplayNames
        preferredOrder = config.preferredOrder
        for agent in config.agents {
            if agents[agent.id] == nil {
                agents[agent.id] = AgentStatus(
                    state: .idle,
                    agent: agent.id,
                    reason: "startup",
                    message: "Waiting for a \(agent.displayName) signal",
                    cwd: "",
                    openApp: AgentDefaults.openApp(for: agent.id),
                    bundleId: AgentDefaults.bundleId(for: agent.id),
                    openURL: nil,
                    openCommand: nil,
                    updatedAt: Date()
                )
            }
        }
        aggregateStatus = aggregate(from: sortedAgents())
    }

    private var agents: [String: AgentStatus] = [:]

    private var aggregateStatus = AgentStatus(
        state: .idle,
        agent: "all agents",
        reason: "startup",
        message: "All agents are idle",
        cwd: "",
        openApp: nil,
        bundleId: nil,
        openURL: nil,
        openCommand: nil,
        updatedAt: Date()
    )

    var onChange: ((StatusSnapshot) -> Void)?

    func snapshot() -> StatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return StatusSnapshot(aggregate: aggregateStatus, agents: sortedAgents())
    }

    func update(_ next: AgentStatus) {
        let normalizedAgent = normalizeAgent(next.agent)
        let normalized = AgentStatus(
            state: next.state,
            agent: normalizedAgent,
            reason: next.reason,
            message: next.message,
            cwd: next.cwd,
            openApp: next.openApp,
            bundleId: next.bundleId,
            openURL: next.openURL,
            openCommand: next.openCommand,
            updatedAt: next.updatedAt
        )

        lock.lock()
        agents[normalizedAgent] = normalized
        aggregateStatus = aggregate(from: sortedAgents())
        let snapshot = StatusSnapshot(aggregate: aggregateStatus, agents: sortedAgents())
        lock.unlock()

        DispatchQueue.main.async {
            self.onChange?(snapshot)
        }
    }

    private func normalizeAgent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "agent" : trimmed
    }

    private func sortedAgents() -> [AgentStatus] {
        return agents.values.sorted { lhs, rhs in
            let left = preferredOrder.firstIndex(of: lhs.agent) ?? Int.max
            let right = preferredOrder.firstIndex(of: rhs.agent) ?? Int.max
            if left != right {
                return left < right
            }
            return lhs.agent < rhs.agent
        }
    }

    private func aggregate(from statuses: [AgentStatus]) -> AgentStatus {
        if let blocked = statuses.first(where: { $0.state == .blocked || $0.state == .error }) {
            return AgentStatus(
                state: blocked.state,
                agent: blocked.agent,
                reason: blocked.reason,
                message: "\(displayName(blocked.agent)) needs input",
                cwd: blocked.cwd,
                openApp: blocked.openApp,
                bundleId: blocked.bundleId,
                openURL: blocked.openURL,
                openCommand: blocked.openCommand,
                updatedAt: blocked.updatedAt
            )
        }

        if let working = statuses.first(where: { $0.state == .working }) {
            let count = statuses.filter { $0.state == .working }.count
            return AgentStatus(
                state: .working,
                agent: count == 1 ? working.agent : "\(count) agents",
                reason: working.reason,
                message: count == 1 ? "\(displayName(working.agent)) is working" : "\(count) agents are working",
                cwd: working.cwd,
                openApp: working.openApp,
                bundleId: working.bundleId,
                openURL: working.openURL,
                openCommand: working.openCommand,
                updatedAt: working.updatedAt
            )
        }

        return AgentStatus(
            state: .idle,
            agent: "all agents",
            reason: "idle",
            message: "All agents are idle",
            cwd: "",
            openApp: nil,
            bundleId: nil,
            openURL: nil,
            openCommand: nil,
            updatedAt: Date()
        )
    }

    private func displayName(_ agent: String) -> String {
        agentDisplayNames[agent] ?? agent.capitalized
    }

    private func shortPath(_ path: String) -> String {
        guard !path.isEmpty else { return "-" }
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 2 else { return path }
        return ".../" + components.suffix(2).joined(separator: "/")
    }
}

final class LightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum DiagnosticsReport {
    static func make(config: AppConfig, snapshot: StatusSnapshot, serverRunning: Bool) -> String {
        var lines: [String] = []
        lines.append("Agent Traffic Light Diagnostics")
        lines.append("Generated: \(Date())")
        lines.append("")
        lines.append("App")
        lines.append("- Local server: \(serverRunning ? "running" : "not running") on port \(config.port)")
        lines.append("- Config file: \(exists(AppConfig.configFile.path)) \(AppConfig.configFile.path)")
        lines.append("- Hook script: \(HookInstaller.hookScriptExists ? "installed" : "missing") \(HookInstaller.hookScriptLocation)")
        lines.append("- Registered agents: \(config.agents.map { $0.id }.joined(separator: ", "))")
        lines.append("")
        lines.append("Aggregate")
        lines.append("- State: \(snapshot.aggregate.state.rawValue)")
        lines.append("- Agent: \(snapshot.aggregate.agent)")
        lines.append("- Reason: \(snapshot.aggregate.reason)")
        lines.append("- Message: \(snapshot.aggregate.message)")
        lines.append("")
        lines.append("Agents")
        for agent in config.agents {
            let status = snapshot.agents.first { $0.agent == agent.id }
            let settingsPath = HookInstaller.settingsPath(for: agent.id) ?? "-"
            let settingsExists = HookInstaller.settingsFileExists(for: agent.id)
            let installed = HookInstaller.isInstalled(for: agent.id)
            lines.append("\(agent.displayName) (\(agent.id))")
            lines.append("- Configured: yes")
            lines.append("- Hook file: \(settingsExists ? "exists" : "missing") \(settingsPath)")
            lines.append("- Hooks installed: \(installed ? "yes" : "no")")
            if let status {
                lines.append("- Last state: \(status.state.rawValue)")
                lines.append("- Last reason: \(status.reason)")
                lines.append("- Last message: \(status.message)")
                lines.append("- Last signal: \(status.reason == "startup" ? "never" : relativeTime(since: status.updatedAt))")
                if !status.cwd.isEmpty {
                    lines.append("- CWD: \(status.cwd)")
                }
            } else {
                lines.append("- Last signal: never")
            }
            if agent.id == "codex" {
                lines.append("- Note: run /hooks in Codex and trust the hook if signals do not arrive.")
            }
            lines.append("")
        }
        lines.append("Next Steps")
        lines.append("- If hook files are missing, install the relevant agent first.")
        lines.append("- If hooks are not installed, right-click the light and choose Install Hooks.")
        lines.append("- If Codex hooks are installed but silent, run /hooks in Codex and trust them.")
        lines.append("- If the server is not running, restart AgentTrafficLight.app.")
        return lines.joined(separator: "\n")
    }

    static func localServerReachable(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func exists(_ path: String) -> String {
        FileManager.default.fileExists(atPath: path) ? "exists" : "missing"
    }

    private static func relativeTime(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

enum AgentOpener {
    static func open(_ status: AgentStatus) {
        if let rawURL = status.openURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawURL.isEmpty {
            runProcess("/usr/bin/open", arguments: [rawURL])
            return
        }

        if let bundleId = status.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleId.isEmpty {
            runProcess("/usr/bin/open", arguments: ["-b", bundleId])
            return
        }

        if let appName = status.openApp?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appName.isEmpty {
            runProcess("/usr/bin/open", arguments: ["-a", appName])
            return
        }

        if let defaultBundleId = AgentDefaults.bundleId(for: status.agent) {
            runProcess("/usr/bin/open", arguments: ["-b", defaultBundleId])
            return
        }

        if let defaultApp = AgentDefaults.openApp(for: status.agent) {
            runProcess("/usr/bin/open", arguments: ["-a", defaultApp])
            return
        }

        if let command = status.openCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            runShell(command)
            return
        }

        if !status.cwd.isEmpty {
            let script = """
            tell application "Terminal"
              activate
              do script "cd \(appleScriptEscaped(status.cwd))"
            end tell
            """
            runProcess("/usr/bin/osascript", arguments: ["-e", script])
            return
        }
    }

    private static func runShell(_ command: String) {
        runProcess("/bin/zsh", arguments: ["-lc", command])
    }

    private static func runProcess(_ path: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Settings Window

@MainActor
final class SettingsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var tableView: NSTableView!
    private var agents: [AgentConfig] = []
    private var detectedAgents: [DetectedAgent] = []
    private var onSave: (([AgentConfig]) -> Void)?

    func show(agents: [AgentConfig], detected: [DetectedAgent], onSave: @escaping ([AgentConfig]) -> Void) {
        self.agents = agents
        self.detectedAgents = detected
        self.onSave = onSave

        if window == nil {
            buildWindow()
        }
        tableView.reloadData()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let width: CGFloat = 420
        let height: CGFloat = 340
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "Agent Traffic Light — Settings"
        w.isReleasedWhenClosed = false
        window = w

        guard let contentView = w.contentView else { return }

        // Header
        let header = NSTextField(labelWithString: "Monitored Agents")
        header.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        header.frame = NSRect(x: 20, y: height - 36, width: 200, height: 20)
        contentView.addSubview(header)

        // Table
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 80, width: width - 40, height: height - 120))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView(frame: .zero)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agent"))
        col.width = scrollView.contentSize.width
        tableView.addTableColumn(col)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // Add button
        let addBtn = NSButton(frame: NSRect(x: 20, y: 52, width: 80, height: 24))
        addBtn.title = "Add"
        addBtn.bezelStyle = .rounded
        addBtn.target = self
        addBtn.action = #selector(addAgent)
        contentView.addSubview(addBtn)

        // Remove button
        let removeBtn = NSButton(frame: NSRect(x: 104, y: 52, width: 80, height: 24))
        removeBtn.title = "Remove"
        removeBtn.bezelStyle = .rounded
        removeBtn.target = self
        removeBtn.action = #selector(removeAgent)
        contentView.addSubview(removeBtn)

        // Rescan button
        let rescanBtn = NSButton(frame: NSRect(x: 200, y: 52, width: 90, height: 24))
        rescanBtn.title = "Rescan"
        rescanBtn.bezelStyle = .rounded
        rescanBtn.target = self
        rescanBtn.action = #selector(rescanAgents)
        contentView.addSubview(rescanBtn)

        // Save button
        let saveBtn = NSButton(frame: NSRect(x: width - 104, y: 52, width: 80, height: 24))
        saveBtn.title = "Save"
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(save)
        contentView.addSubview(saveBtn)

        // Instruction
        let instruction = NSTextField(labelWithString: "Edit cells to change display name. Add/remove agents as needed.")
        instruction.font = NSFont.systemFont(ofSize: 10)
        instruction.textColor = .secondaryLabelColor
        instruction.frame = NSRect(x: 20, y: 10, width: width - 40, height: 16)
        instruction.lineBreakMode = .byTruncatingTail
        contentView.addSubview(instruction)

        // Hook hint
        let hookHint = NSTextField(labelWithString: "Agents appear automatically when they POST status. Configure display names above.")
        hookHint.font = NSFont.systemFont(ofSize: 10)
        hookHint.textColor = .tertiaryLabelColor
        hookHint.frame = NSRect(x: 20, y: 30, width: width - 40, height: 16)
        hookHint.lineBreakMode = .byTruncatingTail
        contentView.addSubview(hookHint)
    }

    @objc private func addAgent() {
        let agent = AgentConfig(id: "new-agent", displayName: "New Agent")
        agents.append(agent)
        tableView.reloadData()
        // Select and edit the new row
        let row = agents.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeAgent() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < agents.count else { return }
        agents.remove(at: tableView.selectedRow)
        tableView.reloadData()
    }

    @objc private func rescanAgents() {
        detectedAgents = AgentDetector.detect()
        // Add any newly detected agents that aren't already in the list
        let existingIDs = Set(agents.map { $0.id })
        for da in detectedAgents where !existingIDs.contains(da.id) {
            agents.append(da.toConfig())
        }
        tableView.reloadData()
    }

    @objc private func save() {
        onSave?(agents)
        window?.orderOut(nil)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        agents.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? AgentConfigCell)
            ?? AgentConfigCell(identifier: identifier)
        let agent = agents[row]
        cell.configure(id: agent.id, displayName: agent.displayName) { [weak self, weak cell] newName in
            guard let self, let cell else { return }
            let currentRow = tableView.row(for: cell)
            guard currentRow >= 0, currentRow < self.agents.count else { return }
            self.agents[currentRow].displayName = newName
        } onChangeID: { [weak self, weak cell] newID in
            guard let self, let cell else { return }
            let currentRow = tableView.row(for: cell)
            guard currentRow >= 0, currentRow < self.agents.count else { return }
            self.agents[currentRow].id = newID.lowercased().trimmingCharacters(in: .whitespaces)
        }
        return cell
    }
}

@MainActor
final class DiagnosticsWindowController: NSObject {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var report = ""

    func show(report: String) {
        self.report = report
        if window == nil {
            buildWindow()
        }
        textView?.string = report
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let width: CGFloat = 640
        let height: CGFloat = 560
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Agent Traffic Light — Diagnostics"
        w.isReleasedWhenClosed = false
        window = w

        guard let contentView = w.contentView else { return }

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 62, width: width - 40, height: height - 84))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = report
        scrollView.documentView = textView
        self.textView = textView
        contentView.addSubview(scrollView)

        let copyButton = NSButton(title: "Copy Report", target: self, action: #selector(copyReport))
        copyButton.frame = NSRect(x: width - 232, y: 20, width: 112, height: 28)
        copyButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(copyButton)

        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.frame = NSRect(x: width - 108, y: 20, width: 88, height: 28)
        closeButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(closeButton)
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    @objc private func close() {
        window?.close()
    }
}

@MainActor
final class AgentConfigCell: NSView {
    private let idField = NSTextField()
    private let nameField = NSTextField()
    private var onChangeDisplayName: ((String) -> Void)?
    private var onChangeID: ((String) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        self.identifier = identifier

        idField.frame = NSRect(x: 4, y: 4, width: 120, height: 20)
        idField.font = NSFont(name: "Menlo", size: 11) ?? NSFont.systemFont(ofSize: 11)
        idField.isBordered = false
        idField.drawsBackground = false
        idField.target = self
        idField.action = #selector(idChanged)
        addSubview(idField)

        nameField.frame = NSRect(x: 132, y: 4, width: 220, height: 20)
        nameField.font = NSFont.systemFont(ofSize: 12)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.placeholderString = "Display Name"
        nameField.target = self
        nameField.action = #selector(nameChanged)
        addSubview(nameField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(id: String, displayName: String,
                   onChangeDisplayName: @escaping (String) -> Void,
                   onChangeID: @escaping (String) -> Void) {
        idField.stringValue = id
        nameField.stringValue = displayName
        self.onChangeDisplayName = onChangeDisplayName
        self.onChangeID = onChangeID
    }

    @objc private func idChanged() { onChangeID?(idField.stringValue) }
    @objc private func nameChanged() { onChangeDisplayName?(nameField.stringValue) }
}

// MARK: - Traffic Light View

final class TrafficLightView: NSView {
    private var snapshot = StatusStore.shared.snapshot()
    private var expanded = false
    private var pinned = false
    private var selectedAgent: String?
    private var userSelectedTab = false
    private var pulse: CGFloat = 0
    private var trackingAreaRef: NSTrackingArea?
    private var dragStart: NSPoint?
    private var didDrag = false
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = false

        StatusStore.shared.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            if !self.userSelectedTab {
                self.selectedAgent = self.recommendedAgent(in: snapshot)
            } else if let selectedAgent = self.selectedAgent, !snapshot.agents.contains(where: { $0.agent == selectedAgent }) {
                self.selectedAgent = nil
                self.userSelectedTab = false
            }
            self.needsDisplay = true
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pulse += 0.035
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPreview(snapshot: StatusSnapshot, expanded: Bool, selectedAgent: String?? = nil) {
        self.snapshot = snapshot
        self.expanded = expanded
        if let selectedAgent {
            self.selectedAgent = selectedAgent
        } else {
            self.selectedAgent = recommendedAgent(in: snapshot)
        }
        self.pulse = 1.2
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard !expanded else { return }
        expanded = true
        animateResize()
    }

    override func mouseExited(with event: NSEvent) {
        guard !pinned else { return }
        expanded = false
        animateResize()
    }

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        if expanded, let tab = tabHit(at: point) {
            selectedAgent = tab
            userSelectedTab = true
            needsDisplay = true
            dragStart = nil
            didDrag = false
            return
        }

        if expanded, event.clickCount >= 2, contentRect().contains(point) {
            openSelectedAgent()
            dragStart = nil
            didDrag = false
            return
        }

        guard !expanded || headerDragRect().contains(point) else {
            dragStart = nil
            didDrag = false
            return
        }

        dragStart = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let current = event.locationInWindow
        didDrag = true
        var frame = window.frame
        frame.origin.x += current.x - dragStart.x
        frame.origin.y += current.y - dragStart.y
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        snapToNearestEdge()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if selectedAgent != nil {
            menu.addItem(withTitle: "Open Agent", action: #selector(openSelectedAgent), keyEquivalent: "o")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Install Hooks…", action: #selector(installHooks), keyEquivalent: "")
        menu.addItem(withTitle: "Uninstall Hooks…", action: #selector(uninstallHooks), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Diagnostics…", action: #selector(openDiagnostics), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: pinned ? "Unpin" : "Pin", action: #selector(togglePinned), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set Working", action: #selector(setWorking), keyEquivalent: "")
        menu.addItem(withTitle: "Set Blocked", action: #selector(setBlocked), keyEquivalent: "")
        menu.addItem(withTitle: "Set Idle", action: #selector(setIdle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func togglePinned() {
        pinned.toggle()
        expanded = pinned
        animateResize()
    }

    @objc private func openSelectedAgent() {
        guard let selectedAgent,
              let status = snapshot.agents.first(where: { $0.agent == selectedAgent })
        else {
            return
        }
        AgentOpener.open(status)
    }

    @objc private func setWorking() {
        setDemo(.working, "Agent is actively working")
    }

    @objc private func setBlocked() {
        setDemo(.blocked, "Waiting for human approval")
    }

    @objc private func setIdle() {
        setDemo(.idle, "Agent is stopped")
    }

    @objc private func openSettings() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.showSettings()
    }

    @objc private func installHooks() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.installHooksFromMenu()
    }

    @objc private func uninstallHooks() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.uninstallHooksFromMenu()
    }

    @objc private func openDiagnostics() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.showDiagnostics()
    }

    private func setDemo(_ state: AgentState, _ message: String) {
        let agent = StatusStore.shared.preferredOrder.first ?? "agent"
        StatusStore.shared.update(AgentStatus(
            state: state,
            agent: agent,
            reason: "manual",
            message: message,
            cwd: "",
            openApp: nil,
            bundleId: nil,
            openURL: nil,
            openCommand: nil,
            updatedAt: Date()
        ))
    }

    private func animateResize() {
        guard let window else { return }
        let size = expanded ? NSSize(width: 392, height: 326) : NSSize(width: 74, height: 146)
        var frame = window.frame
        frame.origin.y -= size.height - frame.height
        frame.size = size
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    private func snapToNearestEdge() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        let leftDistance = abs(frame.minX - visible.minX)
        let rightDistance = abs(visible.maxX - frame.maxX)
        frame.origin.x = leftDistance < rightDistance ? visible.minX + 14 : visible.maxX - frame.width - 14
        frame.origin.y = min(max(frame.origin.y, visible.minY + 14), visible.maxY - frame.height - 14)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    private func headerDragRect() -> NSRect {
        NSRect(x: 0, y: bounds.height - 104, width: bounds.width, height: 104)
    }

    private func contentRect() -> NSRect {
        NSRect(x: 16, y: 18, width: bounds.width - 32, height: bounds.height - 146)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawShell()
        drawLamps()
        if expanded {
            drawDetails()
        }
    }

    private func drawShell() {
        let rect = bounds.insetBy(dx: 6, dy: 6)
        let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)

        NSGraphicsContext.saveGraphicsState()
        NSColor(calibratedWhite: 0.045, alpha: expanded ? 0.98 : 0.76).setFill()
        path.fill()

        let stroke = NSColor(calibratedWhite: 1.0, alpha: expanded ? 0.18 : 0.14)
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 1.0, alpha: 0.06).setStroke()
        highlight.lineWidth = 1
        highlight.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLamps() {
        if expanded {
            return
        }

        let colors = [
            NSColor(calibratedRed: 1.0, green: 0.10, blue: 0.13, alpha: 1),
            NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.10, alpha: 1),
            NSColor(calibratedRed: 0.12, green: 1.0, blue: 0.38, alpha: 1)
        ]
        let x: CGFloat = bounds.midX
        let mid = bounds.midY
        let ys: [CGFloat] = [mid + 38, mid, mid - 38]

        for index in 0..<3 {
            drawLamp(
                center: NSPoint(x: x, y: ys[index]),
                color: colors[index],
                active: snapshot.aggregate.state.activeIndex == index,
                warning: snapshot.aggregate.state == .blocked || snapshot.aggregate.state == .error,
                radius: 7
            )
        }
    }

    private func drawAggregateOrb() {
        let center = NSPoint(x: 42, y: bounds.height - 58)
        drawLamp(
            center: center,
            color: snapshot.aggregate.state.color,
            active: true,
            warning: snapshot.aggregate.state == .blocked || snapshot.aggregate.state == .error,
            radius: 15
        )

        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 25, y: center.y - 25, width: 50, height: 50))
        NSColor.white.withAlphaComponent(0.12).setStroke()
        ring.lineWidth = 1
        ring.stroke()
    }

    private func drawLamp(center: NSPoint, color: NSColor, active: Bool, warning: Bool, radius: CGFloat = 8) {
        let baseRadius: CGFloat = radius
        let wave = (sin(pulse * (warning ? 5.8 : 2.4)) + 1) / 2
        let glowRadius = active ? baseRadius + (warning ? 6 : 6) + wave * (warning ? 3 : 3) : baseRadius + 1

        if active {
            let glow = NSBezierPath(ovalIn: NSRect(
                x: center.x - glowRadius,
                y: center.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            ))
            color.withAlphaComponent(warning ? 0.15 + wave * 0.08 : 0.20).setFill()
            glow.fill()
        }

        let outerRadius = baseRadius + 3
        let outer = NSBezierPath(ovalIn: NSRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
        NSColor(calibratedWhite: 0.0, alpha: active ? 0.48 : 0.32).setFill()
        outer.fill()

        if active {
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - outerRadius - 1, y: center.y - outerRadius - 1, width: (outerRadius + 1) * 2, height: (outerRadius + 1) * 2))
            color.withAlphaComponent(0.50).setStroke()
            ring.lineWidth = 1.2
            ring.stroke()
        }

        let lamp = NSBezierPath(ovalIn: NSRect(x: center.x - baseRadius, y: center.y - baseRadius, width: baseRadius * 2, height: baseRadius * 2))
        (active ? color : color.withAlphaComponent(0.28)).setFill()
        lamp.fill()

        let shine = NSBezierPath(ovalIn: NSRect(x: center.x - baseRadius * 0.5, y: center.y + baseRadius * 0.25, width: baseRadius * 0.8, height: baseRadius * 0.5))
        NSColor.white.withAlphaComponent(active ? 0.54 : 0.10).setFill()
        shine.fill()
    }

    private func drawDetails() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: snapshot.aggregate.state.color,
            .paragraphStyle: paragraph
        ]
        let messageAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 0.92),
            .paragraphStyle: paragraph
        ]
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: fixedFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 0.70),
            .paragraphStyle: paragraph
        ]

        let headerDot = NSPoint(x: 32, y: bounds.height - 42)
        drawStatusDot(center: headerDot, state: snapshot.aggregate.state, radius: 8, active: true)

        let x: CGFloat = 50
        let top = bounds.height - 38
        (snapshot.aggregate.state.title as NSString).draw(in: NSRect(x: x, y: top, width: bounds.width - x - 18, height: 20), withAttributes: titleAttrs)
        (snapshot.aggregate.message as NSString).draw(in: NSRect(x: x, y: top - 24, width: bounds.width - x - 18, height: 18), withAttributes: messageAttrs)

        let footer = [snapshot.aggregate.agent, snapshot.aggregate.reason].filter { !$0.isEmpty }.joined(separator: " / ")
        (footer as NSString).draw(in: NSRect(x: x, y: top - 43, width: bounds.width - x - 18, height: 15), withAttributes: metaAttrs)

        drawTabs()

        if let agent = selectedAgent, let status = snapshot.agents.first(where: { $0.agent == agent }) {
            drawAgentFocus(status, rect: NSRect(x: 16, y: 18, width: bounds.width - 32, height: top - 104))
        } else {
            drawOverview(rect: NSRect(x: 16, y: 18, width: bounds.width - 32, height: top - 104))
        }
    }

    private func drawTabs() {
        for tab in tabs() {
            let selected = selectedAgent == tab.agent
            let rect = tab.rect
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            let color = tab.agent.flatMap { agent in snapshot.agents.first { $0.agent == agent }?.state.color } ?? snapshot.aggregate.state.color
            (selected ? color.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.06)).setFill()
            path.fill()
            (selected ? color.withAlphaComponent(0.45) : NSColor.white.withAlphaComponent(0.10)).setStroke()
            path.lineWidth = 1
            path.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: selected ? .semibold : .medium),
                .foregroundColor: selected ? color : NSColor(calibratedWhite: 0.86, alpha: 0.82),
                .paragraphStyle: paragraph
            ]
            (tab.title as NSString).draw(in: rect.insetBy(dx: 6, dy: 5), withAttributes: attrs)
        }
    }

    private func drawOverview(rect: NSRect) {
        drawContentCard(rect)
        let recommendation = recommendationText(for: snapshot.aggregate)
        drawSectionTitle("Recommended", y: rect.maxY - 30, color: snapshot.aggregate.state.color, x: rect.minX + 18)
        drawBodyText(recommendation, rect: NSRect(x: rect.minX + 18, y: rect.maxY - 65, width: rect.width - 36, height: 24))

        let dividerY = rect.maxY - 82
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: rect.minX + 18, y: dividerY))
        divider.line(to: NSPoint(x: rect.maxX - 18, y: dividerY))
        NSColor.white.withAlphaComponent(0.09).setStroke()
        divider.lineWidth = 1
        divider.stroke()

        var rowY = dividerY - 25
        for agent in snapshot.agents {
            drawOverviewAgentRow(agent, y: rowY, rect: rect)
            rowY -= 29
        }
    }

    private func drawOverviewAgentRow(_ status: AgentStatus, y: CGFloat, rect: NSRect) {
        drawStatusDot(center: NSPoint(x: rect.minX + 27, y: y + 8), state: status.state, radius: 5, active: status.state != .idle)

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 0.92)
        ]
        let messageAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.68, alpha: 0.78)
        ]

        (displayName(status.agent) as NSString).draw(in: NSRect(x: rect.minX + 44, y: y + 9, width: 92, height: 14), withAttributes: nameAttrs)
        (status.message as NSString).draw(in: NSRect(x: rect.minX + 44, y: y - 6, width: rect.width - 170, height: 14), withAttributes: messageAttrs)
        drawStateBadge(status.state, rect: NSRect(x: rect.maxX - 106, y: y + 3, width: 82, height: 18))
    }

    private func drawAgentFocus(_ status: AgentStatus, rect: NSRect) {
        drawContentCard(rect)
        drawStatusDot(center: NSPoint(x: rect.minX + 24, y: rect.maxY - 28), state: status.state, radius: 7, active: status.state != .idle)
        drawSectionTitle(displayName(status.agent), y: rect.maxY - 34, color: NSColor(calibratedWhite: 0.96, alpha: 0.96), x: rect.minX + 42)
        drawStateBadge(status.state, rect: NSRect(x: rect.maxX - 108, y: rect.maxY - 42, width: 88, height: 18))

        drawBodyText(recommendationText(for: status), rect: NSRect(x: rect.minX + 18, y: rect.maxY - 82, width: rect.width - 36, height: 22))

        let dividerY = rect.maxY - 98
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: rect.minX + 18, y: dividerY))
        divider.line(to: NSPoint(x: rect.maxX - 18, y: dividerY))
        NSColor.white.withAlphaComponent(0.08).setStroke()
        divider.lineWidth = 1
        divider.stroke()

        drawInfoRow(label: "Reason", value: status.reason, y: dividerY - 26, rect: rect)
        drawInfoRow(label: "Message", value: status.message, y: dividerY - 52, rect: rect)
        drawInfoRow(label: "Path", value: shortPath(status.cwd), y: dividerY - 78, rect: rect)
    }

    private func drawInfoRow(label: String, value: String, y: CGFloat, rect: NSRect) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: fixedFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.56, alpha: 0.88)
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.76, alpha: 0.88)
        ]
        (label.uppercased() as NSString).draw(in: NSRect(x: rect.minX + 18, y: y, width: 72, height: 14), withAttributes: labelAttrs)
        let display = value.isEmpty ? "-" : value
        (display as NSString).draw(in: NSRect(x: rect.minX + 88, y: y, width: rect.width - 106, height: 14), withAttributes: valueAttrs)
    }

    private func drawContentCard(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.06).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawSectionTitle(_ text: String, y: CGFloat, color: NSColor, x: CGFloat? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: color
        ]
        (text as NSString).draw(in: NSRect(x: x ?? 32, y: y, width: bounds.width - 64, height: 18), withAttributes: attrs)
    }

    private func drawBodyText(_ text: String, rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 0.90),
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func drawStatusDot(center: NSPoint, state: AgentState, radius: CGFloat, active: Bool) {
        let wave = (sin(pulse * (state == .blocked || state == .error ? 5.2 : 2.2)) + 1) / 2
        if active {
            let glowRadius = radius + 5 + wave * 2
            let glow = NSBezierPath(ovalIn: NSRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2))
            state.color.withAlphaComponent(0.16).setFill()
            glow.fill()
        }

        let outer = NSBezierPath(ovalIn: NSRect(x: center.x - radius - 2, y: center.y - radius - 2, width: (radius + 2) * 2, height: (radius + 2) * 2))
        NSColor.black.withAlphaComponent(0.48).setFill()
        outer.fill()

        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        (active ? state.color : state.color.withAlphaComponent(0.28)).setFill()
        dot.fill()
    }

    private func drawStateBadge(_ state: AgentState, rect: NSRect) {
        let badge = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        state.color.withAlphaComponent(state == .idle ? 0.10 : 0.18).setFill()
        badge.fill()
        state.color.withAlphaComponent(state == .idle ? 0.28 : 0.46).setStroke()
        badge.lineWidth = 1
        badge.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: fixedFont(ofSize: 9, weight: .semibold),
            .foregroundColor: state.color,
            .paragraphStyle: paragraph
        ]
        (state.title.uppercased() as NSString).draw(in: rect.insetBy(dx: 5, dy: 3), withAttributes: attrs)
    }

    private func displayName(_ agent: String) -> String {
        StatusStore.shared.agentDisplayNames[agent] ?? agent.capitalized
    }

    private func fixedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont(name: "Menlo", size: size)
            ?? NSFont(name: "Monaco", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    private func shortPath(_ path: String) -> String {
        guard !path.isEmpty else { return "-" }
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 2 else { return path }
        return ".../" + components.suffix(2).joined(separator: "/")
    }

    private struct Tab {
        let agent: String?
        let title: String
        let rect: NSRect
    }

    private func tabs() -> [Tab] {
        let labels: [(String?, String)] = [(nil, "Overview")] + snapshot.agents.map { (Optional($0.agent), displayName($0.agent)) }
        var x: CGFloat = 14
        let y = bounds.height - 122
        let gap: CGFloat = 6
        let available = bounds.width - 28 - gap * CGFloat(max(labels.count - 1, 0))
        let width = floor(available / CGFloat(max(labels.count, 1)))
        return labels.map { agent, title in
            defer { x += width + gap }
            return Tab(agent: agent, title: title, rect: NSRect(x: x, y: y, width: width, height: 28))
        }
    }

    private func tabHit(at point: NSPoint) -> String?? {
        for tab in tabs() where tab.rect.contains(point) {
            return tab.agent
        }
        return nil
    }

    private func recommendedAgent(in snapshot: StatusSnapshot) -> String? {
        if let blocked = snapshot.agents.first(where: { $0.state == .blocked || $0.state == .error }) {
            return blocked.agent
        }
        if let working = snapshot.agents.first(where: { $0.state == .working }) {
            return working.agent
        }
        return nil
    }

    private func recommendationText(for status: AgentStatus) -> String {
        switch status.state {
        case .blocked:
            return "Action needed: review \(displayName(status.agent)) and resolve the pending request."
        case .error:
            return "Check \(displayName(status.agent)) first. It reported an error state."
        case .working:
            return "\(displayName(status.agent)) is running. No action needed right now."
        case .idle:
            return status.agent == "all agents" ? "All registered agents are idle." : "\(displayName(status.agent)) is idle."
        }
    }
}

final class StatusServer: @unchecked Sendable {
    private var listener: NWListener?
    private let encoder = JSONEncoder()
    private(set) var isRunning = false

    init() {
        encoder.dateEncodingStrategy = .iso8601
    }

    func start(port: UInt16 = 17361) {
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("Failed to start status server: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            self?.receive(on: connection)
        }
        listener?.start(queue: .global(qos: .userInitiated))
        isRunning = true
        print("AgentTrafficLight listening on http://127.0.0.1:\(port)/status")
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let response = self.handle(request)
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func handle(_ request: String) -> String {
        if request.hasPrefix("GET /status") {
            return jsonResponse(StatusStore.shared.snapshot())
        }

        if request.hasPrefix("POST /status") {
            let body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            let updated = decodeStatus(from: body)
            StatusStore.shared.update(updated)
            return jsonResponse(updated)
        }

        if request.hasPrefix("GET /demo/working") {
            return updateDemo(.working, "Agent is actively working")
        }
        if request.hasPrefix("GET /demo/blocked") {
            return updateDemo(.blocked, "Waiting for human approval")
        }
        if request.hasPrefix("GET /demo/idle") {
            return updateDemo(.idle, "Agent is stopped")
        }

        return http(status: "404 Not Found", body: "{\"error\":\"not found\"}")
    }

    private func updateDemo(_ state: AgentState, _ message: String) -> String {
        let next = AgentStatus(
            state: state,
            agent: "demo",
            reason: "http",
            message: message,
            cwd: "",
            openApp: nil,
            bundleId: nil,
            openURL: nil,
            openCommand: nil,
            updatedAt: Date()
        )
        StatusStore.shared.update(next)
        return jsonResponse(next)
    }

    private func decodeStatus(from body: String) -> AgentStatus {
        let data = Data(body.utf8)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let snapshot = StatusStore.shared.snapshot()
        let agent = ((object["agent"] as? String) ?? snapshot.aggregate.agent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let previous = snapshot.agents.first { $0.agent == agent } ?? snapshot.aggregate
        let rawState = object["state"] as? String ?? previous.state.rawValue
        let normalizedState = normalizeState(rawState: rawState, reason: object["reason"] as? String, message: object["message"] as? String)

        return AgentStatus(
            state: normalizedState ?? previous.state,
            agent: agent.isEmpty ? previous.agent : agent,
            reason: nonEmptyString(object["reason"]) ?? previous.reason,
            message: nonEmptyString(object["message"]) ?? previous.message,
            cwd: nonEmptyString(object["cwd"]) ?? previous.cwd,
            openApp: nonEmptyString(object["openApp"]) ?? previous.openApp ?? AgentDefaults.openApp(for: agent),
            bundleId: nonEmptyString(object["bundleId"]) ?? previous.bundleId ?? AgentDefaults.bundleId(for: agent),
            openURL: nonEmptyString(object["openURL"]) ?? previous.openURL,
            openCommand: nonEmptyString(object["openCommand"]) ?? previous.openCommand,
            updatedAt: Date()
        )
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }

    private func normalizeState(rawState: String, reason: String?, message: String?) -> AgentState? {
        if isQuotaOrLimitFailure(reason) || isQuotaOrLimitFailure(message) {
            return .error
        }
        return AgentState(rawValue: rawState)
    }

    private func isQuotaOrLimitFailure(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        let patterns = [
            "quota",
            "rate limit",
            "rate-limit",
            "usage limit",
            "credit",
            "insufficient",
            "billing",
            "exceeded",
            "429",
            "额度",
            "限额",
            "余额不足"
        ]
        return patterns.contains { value.contains($0) }
    }

    private func jsonResponse<T: Encodable>(_ value: T) -> String {
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return http(status: "200 OK", body: String(data: data, encoding: .utf8) ?? "{}")
    }

    private func http(status: String, body: String) -> String {
        [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json; charset=utf-8",
            "Access-Control-Allow-Origin: *",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "",
            body
        ].joined(separator: "\r\n")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: LightPanel?
    private var settingsWC: SettingsWindowController?
    private var diagnosticsWC: DiagnosticsWindowController?
    private let server = StatusServer()
    private var config = AppConfig.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        StatusStore.shared.configure(with: config)
        showPanel()
        server.start(port: config.port)

        HookInstaller.prepareHookScript()
        if config.installHooksOnLaunch {
            HookInstaller.installForAgentIDs(config.agents.map(\.id))
        }
    }

    func showSettings() {
        let wc = settingsWC ?? SettingsWindowController()
        settingsWC = wc
        wc.show(agents: config.agents, detected: AgentDetector.detect()) { [weak self] updatedAgents in
            guard let self else { return }
            self.config.agents = updatedAgents
            AppConfig.write(self.config)
            StatusStore.shared.configure(with: self.config)
        }
    }

    func installHooksFromMenu() {
        HookInstaller.installForAgentIDs(config.agents.map(\.id))
    }

    func uninstallHooksFromMenu() {
        HookInstaller.uninstallForAgentIDs(config.agents.map(\.id))
    }

    func showDiagnostics() {
        let wc = diagnosticsWC ?? DiagnosticsWindowController()
        diagnosticsWC = wc
        wc.show(report: DiagnosticsReport.make(
            config: config,
            snapshot: StatusStore.shared.snapshot(),
            serverRunning: server.isRunning
        ))
    }

    private func showPanel() {
        let frame = NSRect(x: 80, y: 700, width: 74, height: 146)
        let panel = LightPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let view = TrafficLightView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

@MainActor
func renderPreview(to path: String, expanded: Bool) {
    let agents = [
        AgentStatus(
            state: .working,
            agent: "codex",
            reason: "tool",
            message: "Running shell command",
            cwd: "/tmp/project",
            openApp: "Codex",
            bundleId: nil,
            openURL: nil,
            openCommand: nil,
            updatedAt: Date()
        ),
        AgentStatus(
            state: .blocked,
            agent: "claude",
            reason: "permission",
            message: "Needs approval for npm install",
            cwd: "/tmp/project",
            openApp: "Claude",
            bundleId: nil,
            openURL: nil,
            openCommand: nil,
            updatedAt: Date()
        ),
        AgentStatus(
            state: .idle,
            agent: "codebuddy",
            reason: "stop",
            message: "Stopped",
            cwd: "/tmp/project",
            openApp: "CodeBuddy CN",
            bundleId: nil,
            openURL: nil,
            openCommand: nil,
            updatedAt: Date()
        )
    ]
    let snapshot = StatusSnapshot(
        aggregate: AgentStatus(
            state: .blocked,
            agent: "claude",
            reason: "permission",
            message: "Claude needs input",
            cwd: "/tmp/project",
            openApp: "Claude",
            bundleId: nil,
            openURL: nil,
            openCommand: nil,
            updatedAt: Date()
        ),
        agents: agents
    )

    let size = expanded ? NSSize(width: 392, height: 326) : NSSize(width: 74, height: 146)
    let view = TrafficLightView(frame: NSRect(origin: .zero, size: size))
    let selected: String?? = CommandLine.arguments.contains("--overview") ? .some(nil) : nil
    view.setPreview(snapshot: snapshot, expanded: expanded, selectedAgent: selected)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * 2),
        pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return
    }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()

    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
    let output = CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : "/tmp/agent-light-preview.png"
    renderPreview(to: output, expanded: !CommandLine.arguments.contains("--collapsed"))
    exit(0)
}

if CommandLine.arguments.contains("--install-hooks") {
    let config = AppConfig.load()
    HookInstaller.installForAgentIDs(config.agents.map(\.id))
    exit(0)
}

if CommandLine.arguments.contains("--uninstall-hooks") {
    let config = AppConfig.load()
    HookInstaller.uninstallForAgentIDs(config.agents.map(\.id))
    exit(0)
}

if CommandLine.arguments.contains("--diagnostics") {
    let config = AppConfig.load()
    StatusStore.shared.configure(with: config)
    print(DiagnosticsReport.make(
        config: config,
        snapshot: StatusStore.shared.snapshot(),
        serverRunning: DiagnosticsReport.localServerReachable(port: config.port)
    ))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
