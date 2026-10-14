import Foundation
import SwiftUI

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex, antigravity, qoder
    case deepseek = "deep_seek"
    case kiro
    var id: String { rawValue }
    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .qoder: return "Qoder"
        case .deepseek: return "DeepSeek"
        case .kiro: return "Kiro"
        }
    }
    var teammateName: String {
        switch self {
        case .claude: return "Maya"
        case .codex: return "Alex"
        case .antigravity: return "Avery"
        case .qoder: return "Quinn"
        case .deepseek: return "Sage"
        case .kiro: return "Kai"
        }
    }
    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "terminal"
        case .antigravity: return "triangle"
        case .qoder: return "q.circle"
        case .deepseek: return "water.waves"
        case .kiro: return "sparkle"
        }
    }
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.84, green: 0.61, blue: 0.46)
        case .codex: return Color(red: 0.55, green: 0.78, blue: 0.67)
        case .antigravity: return Color(red: 0.53, green: 0.68, blue: 0.93)
        case .qoder: return Color(red: 0.69, green: 0.60, blue: 0.90)
        case .deepseek: return Color(red: 0.49, green: 0.65, blue: 0.94)
        case .kiro: return Color(red: 0.69, green: 0.55, blue: 0.95)
        }
    }
    var docs: URL {
        let path: String
        switch self {
        case .claude: path = "https://code.claude.com/docs/en/headless"
        case .codex: path = "https://developers.openai.com/codex/noninteractive/"
        case .antigravity: path = "https://www.antigravity.google/docs/cli/headless/"
        case .qoder: path = "https://docs.qoder.com/cli/run-in-scripts"
        case .deepseek: path = "https://github.com/deepseek-ai/deepseek-harness"
        case .kiro: path = "https://kiro.dev/docs/cli/headless/"
        }
        return URL(string: path)!
    }
}

enum Workflow: String, Codable, CaseIterable {
    case conversation = "Conversation", independent = "Independent", collaborate = "Collaborate"
    var name: String { switch self { case .conversation: return "Chat"; case .independent: return "Parallel"; case .collaborate: return "Handoff" } }
    var explanation: String {
        if self == .conversation { return "Talk to one agent, @mention a teammate, or turn on Team discussion to have them review each other's answers." }
        return self == .independent
        ? "Each agent tackles the same task in its own session."
        : "Agents take turns, passing their findings to the next."
    }
}

enum DeepSeekMode: String, Codable { case claudeCode = "ClaudeCode", nativeHarness = "NativeHarness", directApi = "DirectApi" }

enum ClaudeBackend: String, Codable, CaseIterable {
    case inherit = "Inherit", anthropic = "Anthropic", deepseek = "DeepSeek", custom = "Custom"
    var name: String {
        switch self {
        case .inherit: return "Auto · detected configuration"
        case .anthropic: return "Claude · Anthropic"
        case .deepseek: return "DeepSeek"
        case .custom: return "Custom Anthropic-compatible API"
        }
    }
}

struct ClaudeConfigSource: Decodable, Identifiable {
    let name: String
    let path: String?
    let exists: Bool
    let supplies: [String]
    let error: String?
    var id: String { path ?? name }
}

struct ClaudeConfigSnapshot: Decodable {
    let workspace: String
    let configDirOverride: String
    let configDir: String
    let backend: String
    let endpoint: String
    let model: String
    let conductorModel: String
    let source: String
    let credentialConfigured: Bool
    let managedRouting: Bool
    let sources: [ClaudeConfigSource]
}

enum Effort: String, Codable, CaseIterable, Identifiable {
    case `default`, none, minimal, low, medium, high, xhigh, max, ultra
    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: return "Default"
        case .none: return "Off"
        case .xhigh: return "Extra high"
        default: return rawValue.capitalized
        }
    }
}

struct AgentConfig: Codable, Identifiable {
    var provider: Provider
    var selected = false
    var executable = ""
    var model = ""
    var effort = Effort.default
    var extraArgs = "[]"
    var allowEdits = false
    var id: Provider { provider }
    enum CodingKeys: String, CodingKey { case provider, selected, executable, model, effort, extraArgs, allowEdits }
}

extension AgentConfig {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(provider: try values.decode(Provider.self, forKey: .provider))
        selected = try values.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        executable = try values.decodeIfPresent(String.self, forKey: .executable) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try values.decodeIfPresent(Effort.self, forKey: .effort) ?? .default
        extraArgs = try values.decodeIfPresent(String.self, forKey: .extraArgs) ?? "[]"
        allowEdits = try values.decodeIfPresent(Bool.self, forKey: .allowEdits) ?? false
    }
}

struct Settings: Codable {
    var workspace = FileManager.default.currentDirectoryPath
    var workspaceFolders = [FileManager.default.currentDirectoryPath]
    var agents = Provider.allCases.map { AgentConfig(provider: $0, selected: $0 == .claude || $0 == .codex) }
    var workflow = Workflow.independent
    var timeoutSeconds: UInt64 = 900
    var deepseekBaseUrl = "https://api.deepseek.com"
    var deepseekMode = DeepSeekMode.claudeCode
    var deepseekHarnessExecutable = ""
    var deepseekUseCliConfig = false
    var claudeBackend = ClaudeBackend.inherit
    var claudeBaseUrl = ""
    var claudeConfigDir = ""
    var chatIntroduced = false
    var workspaceName: String { workspace.isEmpty ? "Choose a folder" : folderName(workspace) }
    func folderLabel(_ path: String) -> String {
        let name = folderName(path)
        if workspaceFolders.filter({ folderName($0) == name }).count > 1 {
            return "\(name) · \(URL(fileURLWithPath: path).deletingLastPathComponent().path)"
        }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case workspace, workspaceFolders, agents, workflow, timeoutSeconds, deepseekBaseUrl, deepseekMode, deepseekUseCliConfig, deepseekHarnessExecutable
        case claudeBackend, claudeBaseUrl, claudeConfigDir
        case chatIntroduced
    }
}

extension Settings {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try values.decode(String.self, forKey: .workspace)
        workspaceFolders = try values.decodeIfPresent([String].self, forKey: .workspaceFolders) ?? []
        var seen = Set<String>()
        workspaceFolders = workspaceFolders.filter { !$0.isEmpty && seen.insert($0).inserted }
        if workspace.isEmpty { workspace = workspaceFolders.first ?? "" }
        else if !workspaceFolders.contains(workspace) { workspaceFolders.insert(workspace, at: 0) }
        agents = try values.decode([AgentConfig].self, forKey: .agents)
        for provider in Provider.allCases where !agents.contains(where: { $0.provider == provider }) { agents.append(AgentConfig(provider: provider)) }
        workflow = try values.decode(Workflow.self, forKey: .workflow)
        timeoutSeconds = try values.decode(UInt64.self, forKey: .timeoutSeconds)
        deepseekBaseUrl = try values.decode(String.self, forKey: .deepseekBaseUrl)
        deepseekMode = try values.decode(DeepSeekMode.self, forKey: .deepseekMode)
        deepseekHarnessExecutable = try values.decodeIfPresent(String.self, forKey: .deepseekHarnessExecutable) ?? ""
        deepseekUseCliConfig = try values.decode(Bool.self, forKey: .deepseekUseCliConfig)
        claudeBackend = try values.decodeIfPresent(ClaudeBackend.self, forKey: .claudeBackend) ?? .inherit
        claudeBaseUrl = try values.decodeIfPresent(String.self, forKey: .claudeBaseUrl) ?? ""
        claudeConfigDir = try values.decodeIfPresent(String.self, forKey: .claudeConfigDir) ?? ""
        chatIntroduced = try values.decodeIfPresent(Bool.self, forKey: .chatIntroduced) ?? false
    }
}

func folderName(_ path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? path : name
}

struct AgentInfo: Decodable, Identifiable {
    let provider: Provider
    let status: String
    let label: String
    let detail: String
    var id: Provider { provider }
    var ready: Bool { status == "ready" }
}

enum RunStatus: String, Codable {
    case queued = "Queued", running = "Running", completed = "Completed"
    case failed = "Failed", cancelled = "Cancelled", interrupted = "Interrupted"
    case waitingForUser = "WaitingForUser"
    var active: Bool { self == .queued || self == .running }
    var label: String { self == .waitingForUser ? "Waiting for you" : rawValue }
    var color: Color {
        switch self {
        case .completed: return .mint
        case .running: return Theme.accent
        case .failed: return .red
        case .waitingForUser: return .orange
        default: return .secondary
        }
    }
}

struct Usage: Decodable, Equatable {
    let inputTokens: UInt64
    let outputTokens: UInt64
    let costUsd: Double?
}

struct LogEntry: Decodable, Equatable {
    let at: String
    let kind: String
    let text: String
}

func visibleActivityLogs(_ logs: [LogEntry]) -> [LogEntry] {
    var thinkingShown = false
    return logs.compactMap { log in
        if ["System: thinking_tokens", "Agent is reasoning", "Thinking…"].contains(log.text) {
            guard !thinkingShown else { return nil }
            thinkingShown = true
            return LogEntry(at: log.at, kind: log.kind, text: "Thinking…")
        }
        return log
    }
}

struct Stage: Decodable, Identifiable {
    let provider: Provider
    let model: String
    let status: RunStatus
    let sessionId: String?
    let output: String
    let logs: [LogEntry]
    let usage: Usage
    let error: String?
    var reasoning: String? = nil
    var id: Provider { provider }
}

struct RunSummary: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let workspace: String
    let workflow: Workflow
    let createdAt: String
    let status: RunStatus
    let providers: [Provider]
    let totalTokens: UInt64
    var names: [AgentIdentity]? = nil
    var coworkers: [Coworker]? = nil
    var attention: [AttentionItem]? = nil
    var executionWorkspace: String? = nil
    func displayName(_ provider: Provider) -> String {
        let workers = (coworkers ?? []).filter { $0.provider == provider }
        return workers.isEmpty ? names?.first { $0.provider == provider }?.name ?? provider.name : workers.map(\.name).joined(separator: ", ")
    }
    func matchesSearch(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query)
            || providers.contains { $0.name.localizedCaseInsensitiveContains(query) }
            || (names ?? []).contains { $0.name.localizedCaseInsensitiveContains(query) || "@\($0.mention)".localizedCaseInsensitiveContains(query) }
            || (coworkers ?? []).contains { $0.name.localizedCaseInsensitiveContains(query) || $0.role.label.localizedCaseInsensitiveContains(query) || "@\($0.mention)".localizedCaseInsensitiveContains(query) }
    }
}

struct RunRecord: Decodable, Identifiable {
    let id: String
    let prompt: String
    let workspace: String
    let workflow: Workflow
    let createdAt: String
    let finishedAt: String?
    let status: RunStatus
    let stages: [Stage]
    var conversation: TaskConversation? = nil
    var workspaceInfo: WorkspaceInfo? = nil
    var changes: ChangeSet? = nil
    var dismissedAttention: [AttentionKey]? = nil
    var projectWorkspace: String { workspaceInfo?.project ?? workspace }
    var summary: RunSummary {
        RunSummary(id: id, title: String(prompt.components(separatedBy: .newlines).first?.prefix(58) ?? "Task"), workspace: projectWorkspace,
                   workflow: workflow, createdAt: createdAt, status: status, providers: conversation?.members ?? stages.map(\.provider),
                   totalTokens: conversation?.messages.reduce(0) { $0 + $1.usage.inputTokens + $1.usage.outputTokens } ?? stages.reduce(0) { $0 + $1.usage.inputTokens + $1.usage.outputTokens }, names: conversation?.names,
                   coworkers: conversation?.coworkers, attention: conversation?.attentionItems.filter { !(dismissedAttention ?? []).contains($0.key) }, executionWorkspace: workspace)
    }
}

struct TaskConversation: Decodable {
    let members: [Provider]
    let lead: Provider
    let messages: [ChatMessage]
    var sessions: [AgentSession]
    var names: [AgentIdentity]? = nil
    var models: [AgentModel]? = nil
    var efforts: [AgentEffort]? = nil
    var coworkers: [Coworker]? = nil
    var leadId: String? = nil
    var mailbox: [MailboxDelivery]? = nil
    var pendingQuestions: [ChatMessage] { messages.filter { $0.questionRequest?.answers == nil && $0.questionRequest != nil } }
    func identity(_ provider: Provider) -> AgentIdentity { names?.first { $0.provider == provider } ?? AgentIdentity(provider: provider) }
    func coworker(_ id: String?) -> Coworker? { coworkers?.first { $0.id == id } }
    var pendingApprovals: [ChatMessage] { messages.filter { $0.approvalRequest?.decision == nil && $0.approvalRequest != nil } }
    var attentionItems: [AttentionItem] {
        var items = messages.flatMap { message -> [AttentionItem] in
            var result: [AttentionItem] = []
            if let question = message.questionRequest, question.answers == nil { result.append(AttentionItem(id: question.id, messageId: message.id, ownerId: message.authorId, kind: "question", title: question.questions.first?.question ?? "Needs your answer", revision: question.id)) }
            if let approval = message.approvalRequest, approval.decision == nil { result.append(AttentionItem(id: approval.id, messageId: message.id, ownerId: message.authorId, kind: "approval", title: approval.summary, revision: approval.id)) }
            return result
        }
        items += (coworkers ?? []).filter { $0.attention == "ready_for_review" }.map { worker in
            AttentionItem(id: worker.id, messageId: nil, ownerId: worker.id, kind: "review", title: "\(worker.name)'s changes are ready for review", revision: worker.reviewId ?? messages.last { $0.authorId == worker.id && $0.status == .completed }?.id ?? worker.id)
        }
        return items
    }
}

struct AgentEffort: Codable, Identifiable, Equatable {
    let provider: Provider
    let effort: Effort
    var id: Provider { provider }
    var command: [String: String] { ["provider": provider.rawValue, "effort": effort.rawValue] }
}

enum CoworkerRole: String, Codable, CaseIterable, Identifiable {
    case architect, builder, reviewer, general
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var description: String {
        switch self {
        case .architect: return "Investigates requirements and designs the approach."
        case .builder: return "Implements changes and runs relevant checks."
        case .reviewer: return "Independently reviews changes and sends feedback."
        case .general: return "Follows the role you describe in the conversation."
        }
    }
}

struct Coworker: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var provider: Provider
    var name: String
    var mention: String
    var role = CoworkerRole.general
    var model = ""
    var effort = Effort.default
    var canReadWorkspace = true
    var accessChangedAt: String? = nil
    var blockedMessageIds: [String] = []
    var attention = "idle"
    var waitingFor: String? = nil
    var reviewId: String? = nil
    var identity: AgentIdentity { AgentIdentity(provider: provider, name: name, mention: mention, coworkerId: id) }
    var command: [String: Any] { ["id": id, "provider": provider.rawValue, "name": name, "mention": mention, "role": role.rawValue, "model": model, "effort": effort.rawValue, "can_read_workspace": canReadWorkspace, "attention": attention, "waiting_for": waitingFor as Any? ?? NSNull()] }
    enum CodingKeys: String, CodingKey { case id, provider, name, mention, role, model, effort, canReadWorkspace, accessChangedAt, blockedMessageIds, attention, waitingFor, reviewId }
    func statusLabel(in coworkers: [Coworker]) -> String {
        switch attention {
        case "working": return "Working"
        case "queued": return "Message queued"
        case "waiting_for_coworker": return "Waiting for \(coworkers.first { $0.id == waitingFor }?.name ?? "teammate")"
        case "needs_answer": return "Needs your answer"
        case "ready_for_review": return "Ready for review"
        case "failed": return "Needs attention"
        case "cancelled": return "Stopped"
        default: return "Available"
        }
    }
}

extension Coworker {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); provider = try c.decode(Provider.self, forKey: .provider)
        name = try c.decode(String.self, forKey: .name); mention = try c.decode(String.self, forKey: .mention)
        role = try c.decodeIfPresent(CoworkerRole.self, forKey: .role) ?? .general
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""; effort = try c.decodeIfPresent(Effort.self, forKey: .effort) ?? .default
        canReadWorkspace = try c.decodeIfPresent(Bool.self, forKey: .canReadWorkspace) ?? true
        accessChangedAt = try c.decodeIfPresent(String.self, forKey: .accessChangedAt)
        blockedMessageIds = try c.decodeIfPresent([String].self, forKey: .blockedMessageIds) ?? []
        attention = try c.decodeIfPresent(String.self, forKey: .attention) ?? "idle"
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor); reviewId = try c.decodeIfPresent(String.self, forKey: .reviewId)
    }
}

struct MailboxDelivery: Decodable, Identifiable {
    let id: String
    let at: String
    let from: String?
    let to: String
    let text: String
    let kind: String
    let state: String
    let replyTo: String?
    let responseId: String?
    var questionTarget: QuestionTarget? = nil
    var pendingQuestionAnswer: Bool { kind == "question_answer" && ["queued", "delivered", "paused", "waiting_for_user"].contains(state) }
    var cancellable: Bool { ["queued", "delivered", "paused"].contains(state) }
    var label: String {
        switch state {
        case "queued": return "Queued"
        case "delivered": return "Delivered · working"
        case "waiting_for_user": return "Needs your answer"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        case "paused": return "Paused at exchange limit"
        default: return state.capitalized
        }
    }
}

struct QuestionTarget: Decodable, Equatable {
    let messageId: String
    let requestId: String
}

struct AttentionItem: Decodable, Identifiable, Equatable {
    let id: String
    let messageId: String?
    let ownerId: String?
    let kind: String
    let title: String
    var revision: String? = nil
    var key: AttentionKey { AttentionKey(id: id, revision: revision ?? id) }
}

struct AttentionKey: Decodable, Equatable {
    let id: String
    let revision: String
}

struct AttentionDismissal: Decodable {
    let runId: String
    let id: String
    let revision: String
    var key: AttentionKey { AttentionKey(id: id, revision: revision) }
    var command: [String: Any] { ["run_id": runId, "id": id, "revision": revision] }
}

struct AgentApprovalRequest: Decodable, Identifiable, Equatable {
    let id: String
    let summary: String
    let argv: [String]
    let decision: Bool?
    let result: CheckResult?
}

struct WorkspaceInfo: Decodable {
    let project: String
    let path: String
    let branch: String
    let isolated: Bool
    let baseCommit: String
}

struct ChangedFile: Decodable, Identifiable {
    let path: String
    let status: String
    let diff: String
    let fingerprint: String
    let ownerId: String?
    let truncated: Bool
    var id: String { path }
}

struct CheckResult: Decodable, Identifiable, Equatable {
    let id: String
    let at: String
    let ownerId: String?
    let argv: [String]
    let status: RunStatus
    let exitCode: Int?
    let output: String
}

struct ChangeSet: Decodable {
    let branch: String
    let files: [ChangedFile]
    let checks: [CheckResult]
    let error: String?
    let truncated: Bool
}

func coworkerMentions(_ text: String, coworkers: [Coworker]) -> (ids: [String], ambiguous: String?) {
    var found: [String] = []; var fenced = false
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
        if fenced { continue }
        let chars = Array(line); var inline = false
        for i in chars.indices {
            if chars[i] == "`" { inline.toggle() }
            guard chars[i] == "@", !inline, i == 0 || (!chars[i-1].isLetter && !chars[i-1].isNumber && !"._-".contains(chars[i-1])) else { continue }
            let handle = String(chars.dropFirst(i+1).prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }).lowercased()
            var matches = coworkers.filter { $0.mention.lowercased() == handle }
            if matches.isEmpty, let provider = canonicalMention(handle) { matches = coworkers.filter { $0.provider == provider } }
            if matches.count > 1 { return (found, "Address a coworker by name: \(matches.map { "@\($0.mention)" }.joined(separator: ", ")).") }
            if let id = matches.first?.id, !found.contains(id) { found.append(id) }
        }
    }
    return (found, nil)
}

func commandArguments(_ text: String) -> [String]? {
    var result: [String] = []; var current = ""; var quote: Character?; var escape = false; var started = false
    for c in text {
        if escape { current.append(c); escape = false; started = true; continue }
        if c == "\\", quote != "'" { escape = true; started = true; continue }
        if let active = quote { if c == active { quote = nil } else { current.append(c) }; continue }
        if c == "\"" || c == "'" { quote = c; started = true; continue }
        if c.isWhitespace { if started { result.append(current); current = ""; started = false } }
        else { current.append(c); started = true }
    }
    guard quote == nil, !escape else { return nil }
    if started { result.append(current) }
    return result.isEmpty ? nil : result
}

struct AgentModel: Codable, Identifiable, Equatable {
    let provider: Provider
    let model: String
    var id: Provider { provider }
    var command: [String: String] { ["provider": provider.rawValue, "model": model] }
}

struct ModelOption: Decodable, Identifiable, Equatable {
    let id: String
    let label: String
    var effortLevels: [Effort]? = nil
    var defaultEffort: Effort? = nil
}

struct ModelCatalog: Decodable {
    let provider: Provider
    let source: String
    let options: [ModelOption]
    var effortLevels: [Effort]? = nil
    var effortNote: String? = nil
    func levels(for model: String) -> [Effort]? {
        if let levels = options.first(where: { $0.id == model })?.effortLevels { return levels }
        if (provider == .claude || provider == .kiro) && model.contains("claude-") {
            if ["4-5", "4-1", "3-5", "3-7", "-4-2025"].contains(where: model.contains) { return [] }
            if model.contains("4-6") { return effortLevels?.filter { $0 != .xhigh } }
        }
        return effortLevels
    }
}

struct AgentIdentity: Codable, Identifiable, Equatable {
    let provider: Provider
    var name: String
    var mention: String
    var coworkerId: String? = nil
    var id: String { coworkerId ?? provider.rawValue }
    init(provider: Provider, name: String? = nil, mention: String? = nil, coworkerId: String? = nil) {
        self.provider = provider
        self.name = name ?? provider.name
        self.mention = mention ?? provider.name.lowercased()
        self.coworkerId = coworkerId
    }
    var command: [String: String] { ["provider": provider.rawValue, "name": name, "mention": mention] }
    static let coworkerNames = [
        "Maya", "Alex", "Avery", "Quinn", "Sage", "Kai", "Noah", "Emma", "Liam", "Olivia",
        "Ethan", "Isla", "Lucas", "Amelia", "Aria", "Leo", "Zoe", "Owen", "Ivy", "Finn",
        "Eva", "Theo", "Ruby", "Milo", "Elena", "Eli", "Nora", "Jude", "Clara", "Hugo",
        "Esme", "Max", "Lena", "Oscar", "Vera", "Luca", "Stella", "Ezra", "Iris", "Adam",
        "Mira", "Leah", "Ben", "Lucy", "Dylan", "Ada", "Rory", "Jade", "Wren", "Elise",
        "Nico", "Freya", "River", "Tessa", "Omar", "Anya"
    ]
    static func suggestedTeam(members: [Provider], overrides: [AgentIdentity] = [], excluding otherCoworkers: [AgentIdentity] = []) -> [AgentIdentity] {
        var result = overrides.filter { members.contains($0.provider) }
        for provider in members where !result.contains(where: { $0.provider == provider }) {
            var cycle = 1
            var identity: AgentIdentity?
            while identity == nil {
                for base in [provider.teammateName] + coworkerNames {
                    let name = cycle == 1 ? base : "\(base) \(cycle)"
                    let mention = cycle == 1 ? base.lowercased() : "\(base.lowercased())\(cycle)"
                    if !(result + otherCoworkers).contains(where: { $0.name.lowercased() == name.lowercased() || $0.mention.lowercased() == mention }) {
                        identity = AgentIdentity(provider: provider, name: name, mention: mention)
                        break
                    }
                }
                cycle += 1
            }
            if let identity { result.append(identity) }
        }
        return members.compactMap { provider in result.first { $0.provider == provider } }
    }
    static func suggestedHandle(for name: String, provider: Provider) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let words = folded.split { !$0.isASCII || !($0.isLowercase || $0.isNumber) }
        let handle = String(words.joined(separator: "-").prefix(32))
        return handle.first?.isLowercase == true ? handle : provider.teammateName.lowercased()
    }
    func validationError(in identities: [AgentIdentity]) -> String? {
        if name.isEmpty || name.unicodeScalars.count > 64 || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "Use a name with 1–64 characters and no line breaks." }
        if mention.isEmpty || mention.utf8.count > 32 || !mention.prefix(1).allSatisfy({ $0.isASCII && $0.isLowercase })
            || !mention.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") }) {
            return "Use a handle with 1–32 letters, digits, underscores or hyphens, starting with a letter."
        }
        if let reserved = canonicalMention(mention), reserved != provider { return "That handle is reserved for another provider." }
        if identities.contains(where: { $0.provider != provider && $0.mention.lowercased() == mention.lowercased() }) { return "Another agent in this task already uses that handle." }
        if identities.contains(where: { $0.provider != provider && $0.name.lowercased() == name.lowercased() }) { return "Another teammate in this task already uses that name." }
        return nil
    }
}

func canonicalMention(_ name: String) -> Provider? {
    let normalized = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    return Provider.allCases.first { $0.name.lowercased() == normalized }
}

struct MentionQuery: Equatable {
    let range: NSRange
    let query: String
}

func mentionQuery(in text: String, selection: NSRange) -> MentionQuery? {
    guard selection.length == 0, let caret = Range(selection, in: text)?.lowerBound else { return nil }
    let prefix = text[..<caret]
    guard let at = prefix.lastIndex(of: "@") else { return nil }
    let query = String(prefix[prefix.index(after: at)...])
    let tokenCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    guard query.count <= 32 && query.allSatisfy(tokenCharacter) else { return nil }
    if at > text.startIndex {
        let before = text[text.index(before: at)]
        if before.isLetter || before.isNumber || "._-".contains(before) { return nil }
    }
    var fenced = false
    var inline = false
    for line in text[..<at].components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); inline = false; continue }
        inline = !fenced && line.filter { $0 == "`" }.count % 2 == 1
    }
    guard !fenced && !inline else { return nil }
    var end = caret
    while end < text.endIndex && tokenCharacter(text[end]) { end = text.index(after: end) }
    return MentionQuery(range: NSRange(at..<end, in: text), query: query)
}

func matchingTeammates(_ query: String, identities: [AgentIdentity]) -> [AgentIdentity] {
    let folded = query.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    let engineQuery = folded.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    return identities.enumerated().compactMap { index, identity -> (Int, Int, AgentIdentity)? in
        if folded.isEmpty || identity.mention.lowercased().hasPrefix(folded) { return (0, index, identity) }
        let name = identity.name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        if name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).contains(where: { $0.hasPrefix(folded) }) { return (1, index, identity) }
        if !engineQuery.isEmpty && identity.provider.name.lowercased().hasPrefix(engineQuery) { return (2, index, identity) }
        return nil
    }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
}

struct MentionInsertion {
    let range: NSRange
    let replacement: String
    let selection: NSRange
    func applying(to text: String) -> String { (text as NSString).replacingCharacters(in: range, with: replacement) }
}

func mentionInsertion(_ identity: AgentIdentity, query: MentionQuery, in text: String) -> MentionInsertion? {
    guard let range = Range(query.range, in: text), text[range].hasPrefix("@") else { return nil }
    var replace = query.range
    let suffix = text[range.upperBound...]
    let punctuation = suffix.first.map { ",.;:!?)]}".contains($0) } ?? false
    let replacement = "@\(identity.mention)" + (punctuation ? "" : " ")
    if suffix.hasPrefix(" ") { replace.length += 1 }
    return MentionInsertion(range: replace, replacement: replacement, selection: NSRange(location: replace.location + replacement.utf16.count, length: 0))
}

struct AgentSession: Decodable {
    let provider: Provider
    let sessionId: String
    let scope: String
    var coworkerId: String? = nil
}

struct ChatMessage: Decodable, Identifiable, Equatable {
    let id: String
    let at: String
    let kind: String
    let author: Provider?
    let to: [Provider]
    let text: String
    let status: RunStatus
    let model: String
    let sessionId: String?
    let logs: [LogEntry]
    let usage: Usage
    let error: String?
    var teamDiscussion: Bool? = nil
    var effort: Effort? = nil
    var questionRequest: AgentQuestionRequest? = nil
    var authorId: String? = nil
    var recipientIds: [String]? = nil
    var approvalRequest: AgentApprovalRequest? = nil
    var reasoning: String? = nil
    var authorLabel: String { author?.name ?? (kind == "system" ? "Conductor" : "You") }
}

struct AgentQuestionOption: Decodable, Identifiable, Equatable {
    let id: String
    let label: String
    let description: String
}

struct AgentUserQuestion: Decodable, Identifiable, Equatable {
    let id: String
    let header: String
    let question: String
    let options: [AgentQuestionOption]
    let multiSelect: Bool
}

struct AgentQuestionAnswer: Codable, Equatable {
    let questionId: String
    let optionIds: [String]
    let text: String
    let skipped: Bool
    var command: [String: Any] { ["question_id": questionId, "option_ids": optionIds, "text": text, "skipped": skipped] }
}

struct AgentQuestionRequest: Decodable, Identifiable, Equatable {
    let id: String
    let questions: [AgentUserQuestion]
    let answers: [AgentQuestionAnswer]?
    var answeredBy: String? = nil
    var plainText: String {
        questions.map { question in
            var lines = [question.question] + question.options.map { "• \($0.label)\($0.description.isEmpty ? "" : ": \($0.description)")" }
            if let answer = answers?.first(where: { $0.questionId == question.id }) {
                lines.append(answer.skipped ? "Skipped" : ([String](question.options.filter { answer.optionIds.contains($0.id) }.map(\.label)) + (answer.text.isEmpty ? [] : [answer.text])).joined(separator: ", "))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

struct AgentQuestionDraft {
    var selected = Set<String>()
    var text = ""
    var skipped = false
    var complete: Bool { skipped || !selected.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func answer(_ question: AgentUserQuestion) -> AgentQuestionAnswer {
        AgentQuestionAnswer(questionId: question.id, optionIds: skipped ? [] : question.options.filter { selected.contains($0.id) }.map(\.id),
                            text: skipped ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines), skipped: skipped)
    }
}

func agentMentions(_ text: String, identities: [AgentIdentity] = []) -> [Provider] {
    var result: [Provider] = []
    var fenced = false
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
        if fenced { continue }
        let chars = Array(line)
        var inline = false
        for index in chars.indices {
            if chars[index] == "`" { inline.toggle() }
            guard chars[index] == "@", !inline,
                  index == 0 || (!chars[index-1].isLetter && !chars[index-1].isNumber && !"._-".contains(chars[index-1])) else { continue }
            let name = String(chars.dropFirst(index+1).prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }).lowercased()
            if let provider = identities.first(where: { $0.mention.lowercased() == name })?.provider ?? canonicalMention(name), !result.contains(provider) { result.append(provider) }
        }
    }
    return result
}

struct EngineEvent: Decodable {
    let type: String
    var remote: RemoteInfo? = nil
    var runId: String? = nil
    let protocolVersion: Int?
    let settings: Settings?
    let runs: [RunSummary]?
    let agents: [AgentInfo]?
    let run: RunRecord?
    let demo: Bool?
    let persistenceBlocked: Bool?
    let errors: [String]?
    let message: String?
    let error: Bool?
    let claudeConfig: ClaudeConfigSnapshot?
    var modelCatalogs: [ModelCatalog]? = nil
    var items: [AttentionDismissal]? = nil
}

enum Theme {
    static let background = Color(red: 0.075, green: 0.078, blue: 0.09)
    static let panel = Color(red: 0.105, green: 0.109, blue: 0.125)
    static let border = Color.white.opacity(0.075)
    static let accent = Color(red: 0.51, green: 0.64, blue: 0.97)
}

func timeLabel(_ raw: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date.formatted(date: .abbreviated, time: .shortened) }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: raw)?.formatted(date: .abbreviated, time: .shortened) ?? raw
}

struct LaunchOptions {
    var dataDir: String?
    var capture: String?
    var demo = false
    var view = "workspace"
    var compact = false
    var smoke = false
    var quitTest = false
    init() {
        var args = Array(CommandLine.arguments.dropFirst()).makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--data-dir": dataDir = args.next()
            case "--capture": capture = args.next()
            case "--demo": demo = true
            case "--view": view = args.next() ?? "workspace"
            case "--compact": compact = true
            case "--smoke-test": smoke = true
            case "--quit-test": quitTest = true
            default: break
            }
        }
    }
}

struct ResponseBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(Int), text, code(language: String?)
        case list, listItem(number: Int?, checked: Bool?), quote, divider
        case table(columns: [PresentationIntent.TableColumn.Alignment])
        case tableRow(header: Bool), tableCell(column: Int)
    }
    let id: Int
    let kind: Kind
    var content: AttributedString
    var children: [ResponseBlock] = []
    var text: String { String(content.characters) }
}

func responseBlocks(_ text: String) -> [ResponseBlock] {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    // Foundation supplies the Markdown tree and inline attributes; this runs on
    // EventReader's background queue, including incomplete streamed responses.
    guard let parsed = try? AttributedString(markdown: text, options: .init(
        interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)), !parsed.characters.isEmpty else {
        return [ResponseBlock(id: 0, kind: .text, content: AttributedString(text))]
    }
    var nodes: [Int: MarkdownNode] = [:]
    var roots: [MarkdownNode] = []
    for run in parsed.runs {
        let components = run.presentationIntent?.components ?? []
        var parent: MarkdownNode?
        for intent in components.reversed() {
            if nodes[intent.identity] == nil {
                let node = MarkdownNode(id: intent.identity, kind: intent.kind)
                nodes[intent.identity] = node
                if let parent { parent.children.append(node) } else { roots.append(node) }
            }
            parent = nodes[intent.identity]
        }
        if parent == nil {
            if nodes[0] == nil {
                let node = MarkdownNode(id: 0, kind: .paragraph)
                nodes[0] = node
                roots.append(node)
            }
            parent = nodes[0]
        }
        var content = AttributedString(parsed[run.range])
        content.presentationIntent = nil
        parent?.content.append(content)
    }
    return roots.map { $0.block() }
}

private final class MarkdownNode {
    let id: Int
    let kind: PresentationIntent.Kind
    var content = AttributedString()
    var children: [MarkdownNode] = []
    init(id: Int, kind: PresentationIntent.Kind) { self.id = id; self.kind = kind }

    func block(ordered: Bool = false) -> ResponseBlock {
        var descendants = children.map { $0.block(ordered: kind == .orderedList) }
        let result: ResponseBlock.Kind
        switch kind {
        case .paragraph: result = .text
        case .header(let level): result = .heading(level)
        case .codeBlock(let language): result = .code(language: language)
        case .orderedList, .unorderedList: result = .list
        case .listItem(let ordinal):
            var checked: Bool?
            if !descendants.isEmpty, case .text = descendants[0].kind {
                let prefix = String(descendants[0].content.characters.prefix(4))
                if prefix == "[x] " || prefix == "[X] " || prefix == "[ ] " {
                    checked = prefix != "[ ] "
                    let start = descendants[0].content.characters.index(descendants[0].content.startIndex, offsetBy: 4)
                    descendants[0].content = AttributedString(descendants[0].content[start...])
                }
            }
            result = .listItem(number: ordered ? ordinal : nil, checked: checked)
        case .blockQuote: result = .quote
        case .thematicBreak: result = .divider
        case .table(let columns): result = .table(columns: columns.map(\.alignment))
        case .tableHeaderRow: result = .tableRow(header: true)
        case .tableRow: result = .tableRow(header: false)
        case .tableCell(let column): result = .tableCell(column: column)
        @unknown default: result = .text
        }
        return ResponseBlock(id: id, kind: result, content: content, children: descendants)
    }
}
