import AppKit
import Foundation
import SwiftUI

// Coalesce visual progress before Markdown parsing, and hold it while reading
// older messages as well as during a live scroll.
// Control transitions stay immediate; the engine keeps working independently.
// Scheduler state is lock protected; rendering is serial; receive is main-only.
final class EventDelivery: @unchecked Sendable {
    private struct Status: Equatable { let id: String; let value: String }
    private struct MessageControl: Equatable {
        let id: String; let kind: String; let status: String
        let question: String?; let answered: Bool
        let approval: String?; let decision: Bool?
    }
    private struct ControlState: Equatable {
        let status: String
        let stages: [Status]
        let messages: [MessageControl]
        let mailbox: [Status]
        init(_ run: RunRecord) {
            status = run.status.rawValue
            stages = run.stages.map { Status(id: $0.provider.rawValue, value: $0.status.rawValue) }
            messages = (run.conversation?.messages ?? []).map {
                MessageControl(id: $0.id, kind: $0.kind, status: $0.status.rawValue,
                               question: $0.questionRequest?.id, answered: $0.questionRequest?.answers != nil,
                               approval: $0.approvalRequest?.id, decision: $0.approvalRequest?.decision)
            }
            mailbox = (run.conversation?.mailbox ?? []).map { Status(id: $0.id, value: $0.state) }
        }
    }
    // Engine models and Markdown blocks are value snapshots. A copied snapshot
    // is prepared on one queue, then transferred to the main queue without mutation.
    private struct Snapshot: @unchecked Sendable {
        let event: EngineEvent
        var rendered: [Provider: [ResponseBlock]]
        var chat: [String: [ResponseBlock]]
        var needsRendering: Bool
        let control: ControlState?
        var progress: Bool
    }
    private let lock = NSLock()
    private var pending: [Snapshot] = []
    private var controls: [String: ControlState] = [:]
    private var deletedRuns = Set<String>()
    private var scheduled = false
    private var delayed = false
    private var preparing = false
    private var generation = 0
    private var scrolling = false
    private var lastDelivery: TimeInterval = 0
    private let renderingQueue = DispatchQueue(label: "dev.agentconductor.render", qos: .userInitiated)
    private let render: ((EngineEvent) -> RenderedEvent)?
    private let receive: @MainActor (EngineEvent, [Provider: [ResponseBlock]], [String: [ResponseBlock]]) -> Void
    init(render: ((EngineEvent) -> RenderedEvent)? = nil, receive: @escaping @MainActor (EngineEvent, [Provider: [ResponseBlock]], [String: [ResponseBlock]]) -> Void) {
        self.render = render
        self.receive = receive
    }
    func enqueue(_ event: EngineEvent, rendered: [Provider: [ResponseBlock]], chat: [String: [ResponseBlock]]) {
        enqueue(event, rendered: rendered, chat: chat, needsRendering: false)
    }
    func enqueue(_ event: EngineEvent) { enqueue(event, rendered: [:], chat: [:], needsRendering: true) }
    private func enqueue(_ event: EngineEvent, rendered: [Provider: [ResponseBlock]], chat: [String: [ResponseBlock]], needsRendering: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if event.type == "run_deleted", let id = event.runId {
            deletedRuns.insert(id)
            controls.removeValue(forKey: id)
            pending.removeAll { $0.event.run?.id == id }
        }
        if let id = event.run?.id, deletedRuns.contains(id) { return }
        let control = event.run.map(ControlState.init)
        let progress = event.type == "run_updated" && event.run?.status == .running && event.run.map { controls[$0.id] == control } == true
        if let run = event.run, let control {
            controls[run.id] = control
            if controls.count > 128, let evicted = controls.keys.first(where: { $0 != run.id }) { controls.removeValue(forKey: evicted) }
        }
        var snapshot = Snapshot(event: event, rendered: rendered, chat: chat, needsRendering: needsRendering, control: control, progress: progress)
        if event.type == "run_updated", event.run?.status == .running,
           let last = pending.last, last.event.type == "run_updated", last.event.run?.status == .running,
           last.event.run?.id == event.run?.id, last.control == control {
            // A newer token snapshot can carry the same initial/control state.
            snapshot.progress = last.progress && snapshot.progress
            pending[pending.count - 1] = snapshot
        } else if progress, let index = pending.indices.reversed().prefix(while: { pending[$0].progress }).first(where: { pending[$0].event.run?.id == event.run?.id }) {
            pending[index] = snapshot
        } else { pending.append(snapshot) }
        guard !preparing else { return }
        if pending.contains(where: { !$0.progress }) {
            if !scheduled || delayed { scheduleLocked(after: 0) }
        } else if !scheduled && !scrolling {
            scheduleLocked(after: max(0, 1.0 / 15 - (ProcessInfo.processInfo.systemUptime - lastDelivery)))
        }
    }
    func setScrolling(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard scrolling != active else { return }
        scrolling = active
        if active && pending.allSatisfy(\.progress) {
            generation += 1; scheduled = false; delayed = false
        } else if !active && !pending.isEmpty && !preparing { scheduleLocked(after: 0) }
    }
    private func scheduleLocked(after delay: TimeInterval) {
        scheduled = true; delayed = delay > 0; generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in drain(current) }
    }
    @MainActor private func drain(_ current: Int) {
        lock.lock()
        guard generation == current else { lock.unlock(); return }
        scheduled = false; delayed = false
        guard !preparing, !scrolling || pending.contains(where: { !$0.progress }) else { lock.unlock(); return }
        let snapshots = pending
        pending.removeAll(keepingCapacity: true)
        let needsRendering = snapshots.contains(where: \.needsRendering) && render != nil
        preparing = needsRendering
        lock.unlock()
        let urgent = snapshots.contains { !$0.progress }
        if needsRendering, let render {
            // Only accepted frames reach the parser. A burst of tokens or an
            // offscreen live reply does not repeatedly parse a long document.
            renderingQueue.async { [self] in
                let prepared = snapshots.map { snapshot -> Snapshot in
                    var snapshot = snapshot
                    if snapshot.needsRendering {
                        let content = render(snapshot.event)
                        snapshot.rendered = content.responses; snapshot.chat = content.chat
                        snapshot.needsRendering = false
                    }
                    return snapshot
                }
                DispatchQueue.main.async { [self] in finish(prepared, urgent: urgent, prepared: true) }
            }
        } else { finish(snapshots, urgent: urgent) }
    }
    @MainActor private func finish(_ snapshots: [Snapshot], urgent: Bool, prepared: Bool = false) {
        lock.lock()
        if prepared { preparing = false }
        var delivered: [Snapshot] = []
        for snapshot in snapshots {
            if let id = snapshot.event.run?.id, deletedRuns.contains(id) { continue }
            if !urgent && snapshot.progress, let id = snapshot.event.run?.id {
                // Scrolling can start while background parsing is in flight.
                // Never restore stale progress after a newer control state.
                guard controls[id] == snapshot.control else { continue }
                if pending.contains(where: { $0.event.run?.id == id }) { continue }
                if scrolling { pending.insert(snapshot, at: 0); continue }
            }
            delivered.append(snapshot)
        }
        if !delivered.isEmpty { lastDelivery = ProcessInfo.processInfo.systemUptime }
        if !pending.isEmpty && !scheduled && !preparing {
            if pending.contains(where: { !$0.progress }) { scheduleLocked(after: 0) }
            else if !scrolling { scheduleLocked(after: max(0, 1.0 / 15 - (ProcessInfo.processInfo.systemUptime - lastDelivery))) }
        }
        lock.unlock()
        for snapshot in delivered { receive(snapshot.event, snapshot.rendered, snapshot.chat) }
    }
}

struct RenderedEvent {
    var responses: [Provider: [ResponseBlock]] = [:]
    var chat: [String: [ResponseBlock]] = [:]
}

// Used only on EventDelivery's serial rendering queue. Keep separate caches for
// interleaved chats so another task's update cannot reparse completed replies.
final class EventRenderer {
    private struct Cache {
        var responses: [Provider: (String, [ResponseBlock])] = [:]
        var chat: [String: (String, [ResponseBlock])] = [:]
        var bytes: Int { responses.values.reduce(0) { $0 + $1.0.utf8.count } + chat.values.reduce(0) { $0 + $1.0.utf8.count } }
    }
    private var caches: [String: Cache] = [:]
    private var recent: [String] = []
    private(set) var parsedDocuments = 0
    func render(_ event: EngineEvent) -> RenderedEvent {
        if event.type == "run_deleted", let id = event.runId {
            caches.removeValue(forKey: id); recent.removeAll { $0 == id }
        }
        guard let run = event.run else { return RenderedEvent() }
        var cache = caches[run.id] ?? Cache()
        var result = RenderedEvent()
        let providers = Set(run.stages.map(\.provider))
        cache.responses = cache.responses.filter { providers.contains($0.key) }
        for stage in run.stages {
            if cache.responses[stage.provider]?.0 != stage.output {
                cache.responses[stage.provider] = (stage.output, responseBlocks(stage.output)); parsedDocuments += 1
            }
            result.responses[stage.provider] = cache.responses[stage.provider]?.1 ?? []
        }
        let messages = run.conversation?.messages ?? []
        let ids = Set(messages.map(\.id))
        cache.chat = cache.chat.filter { ids.contains($0.key) }
        for message in messages {
            if cache.chat[message.id]?.0 != message.text {
                cache.chat[message.id] = (message.text, responseBlocks(message.text)); parsedDocuments += 1
            }
            result.chat[message.id] = cache.chat[message.id]?.1 ?? []
        }
        recent.removeAll { $0 == run.id }; recent.append(run.id)
        caches[run.id] = cache
        // A few large conversations should not keep every old Markdown tree
        // alive. Retain the current run; evict older entries by size as well as count.
        while recent.count > 1 && (recent.count > 8 || caches.values.reduce(0, { $0 + $1.bytes }) > 8 * 1024 * 1024) {
            caches.removeValue(forKey: recent.removeFirst())
        }
        return result
    }
}

// Pipe framing and decoding stay off the main queue. Markdown waits for the
// delivery boundary, after pacing and reading-history backpressure.
private final class EventReader {
    private let queue = DispatchQueue(label: "dev.agentconductor.events", qos: .userInitiated)
    private var buffer = Data()
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }()
    let receive: (EngineEvent) -> Void
    let fail: (String) -> Void
    init(receive: @escaping (EngineEvent) -> Void, fail: @escaping (String) -> Void) {
        self.receive = receive
        self.fail = fail
    }
    func consume(_ data: Data) {
        queue.async { [self] in
            buffer.append(data)
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                do {
                    receive(try decoder.decode(EngineEvent.self, from: line))
                }
                catch { fail("Could not read the agent engine response: \(error.localizedDescription)") }
            }
            if buffer.count > 16 * 1024 * 1024 {
                buffer.removeAll()
                fail("The engine response exceeded the display limit.")
            }
        }
    }
}

@MainActor
extension EngineStore {
    var usesCoworkerTeams: Bool { !options.smoke }
    var coworkers: [Coworker] {
        if let conversation = chatRun?.conversation {
            if let workers = conversation.coworkers, !workers.isEmpty { return workers }
            return conversation.members.map { provider in
                let identity = conversation.identity(provider)
                return Coworker(id: "legacy-\(provider.rawValue)", provider: provider, name: identity.name, mention: identity.mention)
            }
        }
        return draftCoworkers
    }
    var effectiveCoworker: Coworker? { coworkers.first { $0.id == coworkerLead } ?? coworkers.first }
    var canQueueMessage: Bool { chatRun?.status.active == true && chatRun?.conversation?.mailbox?.contains { ["queued", "delivered"].contains($0.state) } == true }
    var attentionCount: Int { runs.reduce(0) { $0 + ($1.attention?.count ?? 0) } }
    var sharedTaskChoices: [RunSummary] { workspaceRuns.filter { $0.workflow == .conversation && $0.executionWorkspace != nil } }
    var queuedMail: [MailboxDelivery] { (chatRun?.conversation?.mailbox ?? []).filter { ["queued", "paused", "delivered", "waiting_for_user"].contains($0.state) } }
    private var reservedCoworkerNames: [AgentIdentity] { otherCoworkers + runs.flatMap { ($0.coworkers ?? []).map(\.identity) } + coworkerDrafts.values.flatMap { $0.map(\.identity) } + draftCoworkers.map(\.identity) + coworkers.map(\.identity) }
    private func makeCoworker(provider: Provider, role: CoworkerRole, excluding: [Coworker] = []) -> Coworker {
        let name = AgentIdentity.suggestedTeam(members: [provider], excluding: reservedCoworkerNames + excluding.map(\.identity))[0]
        allocatedCoworkers.append(name)
        return Coworker(provider: provider, name: name.name, mention: name.mention, role: role)
    }
    private func makeRoleTeam() -> [Coworker] {
        let providers = team.map(\.provider)
        let architect = providers.contains(.claude) ? Provider.claude : providers.first ?? .claude
        let builder = providers.contains(.codex) ? Provider.codex : providers.last ?? architect
        var result: [Coworker] = []
        for (provider, role) in [(architect, CoworkerRole.architect), (builder, .builder), (builder, .reviewer)] { result.append(makeCoworker(provider: provider, role: role, excluding: result)) }
        return result
    }
    private func freshTeam(template: [Coworker], keepChoices: Bool) -> [Coworker] {
        var result: [Coworker] = []
        for worker in template {
            var fresh = makeCoworker(provider: worker.provider, role: worker.role, excluding: result)
            if keepChoices { fresh.model = worker.model; fresh.effort = worker.effort }
            result.append(fresh)
        }
        return result
    }
    func resetRoleTeam() {
        guard chatRun == nil, canChangeChatModels else { return }
        draftCoworkers = makeRoleTeam(); coworkerLead = draftCoworkers.first?.id ?? ""
        coworkerDrafts[settings.workspace] = draftCoworkers
    }
    func addCoworker(_ provider: Provider, role: CoworkerRole = .general) {
        guard chatRun == nil, canChangeChatModels, draftCoworkers.count < 6 else { return }
        draftCoworkers.append(makeCoworker(provider: provider, role: role)); coworkerDrafts[settings.workspace] = draftCoworkers
    }
    func removeCoworker(_ id: String) {
        guard chatRun == nil, canChangeChatModels else { return }
        draftCoworkers.removeAll { $0.id == id }
        if !draftCoworkers.contains(where: { $0.id == coworkerLead }) { coworkerLead = draftCoworkers.first?.id ?? "" }
        coworkerDrafts[settings.workspace] = draftCoworkers
    }
    func updateCoworker(_ proposed: Coworker) -> String? {
        guard canChangeChatModels, coworkers.contains(where: { $0.id == proposed.id }) else { return "Wait for the current exchange before editing a coworker." }
        var worker = proposed
        worker.name = worker.name.trimmingCharacters(in: .whitespacesAndNewlines)
        worker.mention = worker.mention.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" }).lowercased()
        let others = coworkers.filter { $0.id != worker.id }
        if worker.name.isEmpty || worker.name.count > 64 || worker.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) || others.contains(where: { $0.name.lowercased() == worker.name.lowercased() }) { return "Give each coworker a unique name of 1–64 characters." }
        let reservedAlias = canonicalMention(worker.mention).map { $0 != worker.provider || others.contains { $0.provider == worker.provider } } ?? false
        if worker.mention.isEmpty || worker.mention.utf8.count > 32 || worker.mention.first?.isLowercase != true || !worker.mention.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") }) || others.contains(where: { $0.mention == worker.mention }) || reservedAlias { return "Use a unique personal @handle, starting with a letter. Connection names are reserved when several coworkers use them." }
        if worker.model.utf8.count > 512 || worker.model.hasPrefix("-") || worker.model.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) { return "Use a model ID without whitespace or a leading hyphen." }
        if worker.provider == .claude && claudeUsesDeepSeek || worker.provider == .deepseek && settings.deepseekMode == .claudeCode {
            if worker.model.hasSuffix("[1m]") { worker.model.removeLast(4) }
            if worker.model == "deepseek-v4-flash" { worker.model = "deepseek-flash" }
            if !worker.model.isEmpty && !["deepseek-flash", "deepseek-v4-pro"].contains(worker.model) { return "This connection uses DeepSeek. Choose deepseek-flash or deepseek-v4-pro." }
        }
        if worker.effort != .default && !effortOptions(worker.provider, model: worker.model.isEmpty ? defaultModel(worker.provider) : worker.model).contains(worker.effort) { return "Choose an effort supported by this coworker's model." }
        if var run = chatRun, let index = run.conversation?.coworkers?.firstIndex(where: { $0.id == worker.id }) {
            guard worker.provider == run.conversation?.coworkers?[index].provider else { return "Create a new coworker in a new chat to change its connection." }
            run.conversation?.coworkers?[index] = worker; selectedRun = run
            send(["type": "update_coworker", "run_id": run.id, "coworker": worker.command])
        } else if let index = draftCoworkers.firstIndex(where: { $0.id == worker.id }) { draftCoworkers[index] = worker; coworkerDrafts[settings.workspace] = draftCoworkers }
        return nil
    }
    func coworkerModelLabel(_ worker: Coworker) -> String { worker.model.isEmpty ? "Default · \(defaultModel(worker.provider))" : modelOptions(worker.provider).first { $0.id == worker.model }?.label ?? worker.model }
    func mentionCoworker(_ worker: Coworker) { prompt += (prompt.isEmpty || prompt.hasSuffix(" ") ? "" : " ") + "@\(worker.mention) " }
    func cancelDelivery(_ mail: MailboxDelivery) { if let id = chatRun?.id { send(["type": "cancel_mail", "run_id": id, "mail_id": mail.id]) } }
    func continueMailbox() {
        guard !busy, let run = chatRun else { return }
        send(["type": "session_key", "key": sessionKey, "claude_key": claudeSessionKey, "kiro_key": kiroSessionKey])
        send(["type": "team_continue", "run_id": run.id, "settings": encodedSettings()])
    }
    func openAttention(run: RunSummary, item: AttentionItem) {
        selectRun(run.id); focusedMessageID = item.messageId
        inspectorTab = item.kind == "review" ? "changes" : "team"
    }
    func decideApproval(runID: String, message: ChatMessage, approved: Bool) {
        guard !busy, loaded, connected, !demo, let request = message.approvalRequest, request.decision == nil, !pendingQuestionReplies.contains(request.id) else { return }
        pendingQuestionReplies.insert(request.id)
        send(["type": "session_key", "key": sessionKey, "claude_key": claudeSessionKey, "kiro_key": kiroSessionKey])
        send(["type": "team_approval", "run_id": runID, "message_id": message.id, "request_id": request.id, "approved": approved, "settings": encodedSettings()])
    }
    func refreshChanges() { if let id = chatRun?.id { send(["type": "refresh_changes", "run_id": id]) } }
    func runCheck(_ command: String) -> String? {
        guard !busy, !demo, let run = chatRun else { return "Wait for the current exchange before running checks." }
        guard let argv = commandArguments(command), !argv[0].isEmpty else { return "Enter a command with balanced quotes." }
        send(["type": "run_check", "run_id": run.id, "argv": argv, "owner_id": NSNull()]); return nil
    }
    func sendReviewFeedback(file: ChangedFile, text: String, owner: String) {
        guard let worker = coworkers.first(where: { $0.id == owner }) else { return }
        forcedRecipientID = owner
        defer { forcedRecipientID = nil }
        coworkerLead = owner; teamDiscussion = false
        prompt = "@\(worker.mention) Review feedback for \(file.path):\n\(text)\nAddress this feedback and report the changes and checks."
        startRun()
    }
    func askForReview() {
        guard let reviewer = coworkers.first(where: { $0.role == .reviewer }) ?? coworkers.last else { return }
        coworkerLead = reviewer.id; teamDiscussion = false
        prompt = "@\(reviewer.mention) Review the current workspace diff independently. Report concrete issues with file references and send actionable requests to the responsible coworker."
        startRun()
    }
}

@MainActor
final class EngineStore: ObservableObject {
    let remote = RemoteAccessStore()
    func configureRemote(_ config: RemoteConfiguration, token: String) { send(["type": "remote_configure", "config": config.command, "token": token]) }
    func disableRemote() { send(["type": "remote_disable"]) }
    @Published var settings = Settings() {
        didSet {
            if !applying {
                if settings.claudeBaseUrl != oldValue.claudeBaseUrl { claudeSessionKey = "" }
                if settings.deepseekBaseUrl != oldValue.deepseekBaseUrl {
                    sessionKey = ""
                    if settings.claudeBackend == .deepseek { claudeSessionKey = "" }
                }
                if loaded { scheduleSettings() }
            }
        }
    }
    @Published var agents: [AgentInfo] = []
    @Published var runs: [RunSummary] = []
    @Published var selectedRun: RunRecord?
    @Published var selectedRunID: String?
    @Published var selectedProvider: Provider?
    @Published var renderedResponses: [Provider: [ResponseBlock]] = [:]
    @Published var renderedChat: [String: [ResponseBlock]] = [:]
    @Published var composingNewTask = true
    @Published var chatLead: Provider = .claude
    @Published var teamDiscussion = false
    @Published var draftCoworkers: [Coworker] = []
    @Published var coworkerLead = ""
    @Published var inspectorTab = "team"
    @Published var isolationMode = "shared"
    @Published var shareTaskID = ""
    @Published var focusedMessageID: String?
    private var forcedRecipientID: String?
    @Published var newAgentNames: [AgentIdentity] = []
    @Published var newAgentModels: [AgentModel] = []
    @Published var newAgentEfforts: [AgentEffort] = []
    @Published var modelCatalogs: [ModelCatalog] = []
    @Published var prompt = ""
    @Published var composerExpanded = true
    @Published var screen = "workspace"
    @Published var loaded = false
    @Published var connected = false
    @Published var demo = false
    @Published var persistenceBlocked = false
    @Published var notice: String?
    @Published var noticeIsError = false
    @Published var sessionKey = ""
    @Published var claudeSessionKey = ""
    @Published var kiroSessionKey = ""
    @Published var claudeConfig: ClaudeConfigSnapshot?
    @Published var cancelling = Set<String>()
    @Published private(set) var pendingQuestionReplies = Set<String>()
    @Published var chatToDelete: RunSummary?
    @Published private(set) var deletingRuns = Set<String>()
    @Published private(set) var clearingInbox = false
    let options: LaunchOptions
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: EventReader?
    private var delivery: EventDelivery?
    private(set) var transcriptReadingHistory = false
    private let writer = DispatchQueue(label: "dev.agentconductor.commands")
    private var applying = false
    private var saving: Task<Void, Never>?
    private var closing = false
    private var smokeStarted = false
    private var smokeRunID: String?
    private var smokeChatStep = 0
    private var smokeCompletionScheduled = false
    private var captureScheduled = false
    private var noticeGeneration = 0
    private var drafts: [String: String] = [:]
    private var nameDrafts: [String: [AgentIdentity]] = [:]
    private var allocatedCoworkers: [AgentIdentity] = []
    private var modelDrafts: [String: [AgentModel]] = [:]
    private var effortDrafts: [String: [AgentEffort]] = [:]
    private var pendingChat = false
    private var submittedChatPrompt = ""
    private var coworkerDrafts: [String: [Coworker]] = [:]
    private var deletedRunIDs = Set<String>()
    private var pendingInboxBatches = 0

    init(options: LaunchOptions) {
        self.options = options
        screen = options.view
        newAgentNames = AgentIdentity.suggestedTeam(members: Provider.allCases)
    }

    func setTranscriptReadingHistory(_ active: Bool) {
        transcriptReadingHistory = active
        delivery?.setScrolling(active)
    }

    var busy: Bool { runs.contains { $0.status.active } }
    var workspaceRuns: [RunSummary] { runs.filter { $0.workspace == settings.workspace } }
    var workspaceRun: RunRecord? { selectedRun?.projectWorkspace == settings.workspace ? selectedRun : nil }
    var workspaceSelectionPending: Bool {
        selectedRun == nil && workspaceRuns.contains { $0.id == selectedRunID }
    }
    var team: [AgentConfig] { settings.agents.filter(\.selected) }
    var chatRun: RunRecord? { composingNewTask ? nil : workspaceRun?.conversation == nil ? nil : workspaceRun }
    var chatMembers: [Provider] { chatRun?.conversation?.members ?? team.map(\.provider) }
    var chatIdentities: [AgentIdentity] {
        if usesCoworkerTeams { return coworkers.map(\.identity) }
        if let conversation = chatRun?.conversation { return chatMembers.map(conversation.identity) }
        return AgentIdentity.suggestedTeam(members: chatMembers, overrides: newAgentNames)
    }
    private var otherCoworkers: [AgentIdentity] {
        runs.flatMap { $0.names ?? [] } + nameDrafts.values.flatMap { $0 } + allocatedCoworkers
    }
    func suggestedCoworkers(members: [Provider]) -> [AgentIdentity] {
        AgentIdentity.suggestedTeam(members: members, excluding: otherCoworkers + newAgentNames + (chatRun?.conversation?.names ?? []))
    }
    private func freshCoworkers(excluding names: [AgentIdentity] = [], includeCurrent: Bool = true) -> [AgentIdentity] {
        let roster = AgentIdentity.suggestedTeam(members: Provider.allCases, excluding: otherCoworkers + names + (includeCurrent ? newAgentNames : []))
        allocatedCoworkers += roster
        return roster
    }
    func identity(_ provider: Provider) -> AgentIdentity { chatIdentities.first { $0.provider == provider } ?? AgentIdentity(provider: provider) }
    func displayName(_ provider: Provider) -> String { identity(provider).name }
    var chatModels: [AgentModel] { chatRun?.conversation?.models ?? (chatRun == nil ? newAgentModels : []) }
    func modelOverride(_ provider: Provider) -> String { chatModels.first { $0.provider == provider }?.model ?? "" }
    func modelOptions(_ provider: Provider) -> [ModelOption] { modelCatalogs.first { $0.provider == provider }?.options ?? [] }
    var chatEfforts: [AgentEffort] { chatRun?.conversation?.efforts ?? (chatRun == nil ? newAgentEfforts : []) }
    func effortOverride(_ provider: Provider) -> Effort { chatEfforts.first { $0.provider == provider }?.effort ?? .default }
    func defaultEffort(_ provider: Provider) -> Effort { settings.agents.first { $0.provider == provider }?.effort ?? .default }
    func effectiveEffort(_ provider: Provider) -> Effort {
        let choice = effortOverride(provider)
        return choice == .default ? defaultEffort(provider) : choice
    }
    func effortOptions(_ provider: Provider, model: String? = nil) -> [Effort] {
        let chosen = model ?? (modelOverride(provider).isEmpty ? defaultModel(provider) : modelOverride(provider))
        if let levels = modelCatalogs.first(where: { $0.provider == provider })?.levels(for: chosen) { return levels }
        if provider == .deepseek || (provider == .claude && claudeUsesDeepSeek) {
            return provider == .deepseek && settings.deepseekMode == .directApi ? [.none, .low, .high, .max] : [.low, .high, .max]
        }
        if provider == .antigravity { return [.low, .medium, .high] }
        if provider == .codex { return [.low, .medium, .high, .xhigh, .max] }
        return [.low, .medium, .high, .xhigh, .max]
    }
    func effortNote(_ provider: Provider) -> String {
        modelCatalogs.first { $0.provider == provider }?.effortNote ?? "Available effort levels depend on the selected model."
    }
    func effortLabel(_ provider: Provider) -> String {
        let choice = effortOverride(provider)
        if choice != .default { return "Effort · \(choice.label)" }
        let fallback = defaultEffort(provider)
        return fallback == .default ? "Effort · Default" : "Default · \(fallback.label) effort"
    }
    func effortIsValid(_ provider: Provider) -> Bool { effectiveEffort(provider) == .default || effortOptions(provider).contains(effectiveEffort(provider)) }
    func setAgentEffort(_ provider: Provider, effort: Effort) -> String? {
        guard canChangeChatModels && chatMembers.contains(provider) else { return "Wait for the current reply and choose a teammate in this chat." }
        guard effort == .default || effortOptions(provider).contains(effort) else { return "Choose an effort level supported by this teammate's model or connection." }
        var choices = chatEfforts.filter { $0.provider != provider }
        if effort != .default { choices.append(AgentEffort(provider: provider, effort: effort)) }
        if var run = chatRun {
            run.conversation?.efforts = choices
            selectedRun = run
            send(["type": "set_agent_effort", "run_id": run.id, "provider": provider.rawValue, "effort": effort.rawValue])
        } else {
            newAgentEfforts = choices
            effortDrafts[settings.workspace] = choices
        }
        return nil
    }
    func defaultModel(_ provider: Provider) -> String {
        let configured = settings.agents.first { $0.provider == provider }?.model ?? ""
        if !configured.isEmpty { return configured }
        if provider == .claude {
            switch settings.claudeBackend {
            case .anthropic: return "sonnet"
            case .deepseek: return "deepseek-flash"
            case .custom: return "Set in Connections"
            case .inherit: return claudeConfig?.conductorModel ?? "CLI default"
            }
        }
        if provider == .deepseek {
            if settings.deepseekMode == .claudeCode && settings.deepseekUseCliConfig && claudeConfig?.backend == "DeepSeek" { return claudeConfig?.conductorModel ?? "deepseek-flash" }
            return "deepseek-flash"
        }
        return "CLI default"
    }
    func modelLabel(_ provider: Provider) -> String {
        let chosen = modelOverride(provider)
        if chosen.isEmpty { return "Default · \(defaultModel(provider))" }
        return modelOptions(provider).first { $0.id == chosen }?.label ?? chosen
    }
    var canChangeChatModels: Bool { loaded && connected && !demo && !busy && !pendingChat && pendingQuestionReplies.isEmpty && !workspaceSelectionPending }
    var canEditTeam: Bool { canChangeChatModels && chatting && !chatMembers.isEmpty }
    private var claudeUsesDeepSeek: Bool { settings.claudeBackend == .deepseek || (settings.claudeBackend == .inherit && claudeConfig?.backend == "DeepSeek") }
    func setAgentModel(_ provider: Provider, model raw: String) -> String? {
        guard canChangeChatModels else { return "Wait for the current reply before changing its model." }
        guard chatMembers.contains(provider) else { return "Choose an agent in this task's team." }
        var model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.utf8.count > 512 || model.hasPrefix("-") || model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return "Use a model ID below 512 bytes, without spaces, line breaks or a leading hyphen."
        }
        if !model.isEmpty && ((provider == .claude && claudeUsesDeepSeek) || (provider == .deepseek && settings.deepseekMode == .claudeCode)) {
            if model.hasSuffix("[1m]") { model.removeLast(4) }
            if model == "deepseek-v4-flash" { model = "deepseek-flash" }
            if !["deepseek-flash", "deepseek-v4-pro"].contains(model) { return "This Claude Code connection uses DeepSeek. Choose deepseek-flash or deepseek-v4-pro." }
        }
        var models = chatModels.filter { $0.provider != provider }
        if !model.isEmpty { models.append(AgentModel(provider: provider, model: model)) }
        if var run = chatRun {
            run.conversation?.models = models
            selectedRun = run
            send(["type": "set_agent_model", "run_id": run.id, "provider": provider.rawValue, "model": model])
        } else {
            newAgentModels = models
            modelDrafts[settings.workspace] = models
        }
        return nil
    }
    var chatTargets: [Provider] { if teamDiscussion { return chatMembers }; let targets = agentMentions(prompt, identities: chatIdentities); return targets.isEmpty ? [effectiveLead] : targets }
    var discussionUnavailable: [Provider] { chatMembers.filter { availability($0)?.ready != true } }
    var discussionHint: String {
        if usesCoworkerTeams {
            if coworkers.count < 2 { return "Add at least two coworkers to start a team discussion." }
            let unavailable = coworkers.filter { availability($0.provider)?.ready != true }
            if !unavailable.isEmpty { return "Set up \(unavailable.map(\.name).joined(separator: ", ")) in Connections to include the whole team." }
            return "\(leadName) answers first, each coworker reviews, then \(leadName) responds with their feedback. \(coworkers.count + 1) replies."
        }
        if chatMembers.count < 2 { return "Select at least two agents to start a team discussion." }
        if !discussionUnavailable.isEmpty { return "Set up \(discussionUnavailable.map(displayName).joined(separator: ", ")) in Connections to include the whole team." }
        return "\(displayName(effectiveLead)) answers first, the team reviews, then \(displayName(effectiveLead)) responds with their feedback. \(chatMembers.count + 1) replies."
    }
    var effectiveLead: Provider { chatMembers.contains(chatLead) ? chatLead : chatMembers.first ?? .claude }
    var leadName: String { usesCoworkerTeams ? effectiveCoworker?.name ?? "your coworker" : displayName(effectiveLead) }
    var chatting: Bool { settings.workflow == .conversation || chatRun != nil }
    var hasPendingQuestions: Bool { !(chatRun?.conversation?.pendingQuestions.isEmpty ?? true) || !(chatRun?.conversation?.pendingApprovals.isEmpty ?? true) }
    var questionsAssignedToTeammates: Bool {
        guard let run = chatRun, let chat = run.conversation, !chat.pendingQuestions.isEmpty, chat.pendingApprovals.isEmpty else { return false }
        return chat.pendingQuestions.allSatisfy { questionDelegate(runID: run.id, message: $0) != nil }
    }
    var canRun: Bool {
        if usesCoworkerTeams && chatting {
            let query = forcedRecipientID.map { (ids: [$0], ambiguous: String?.none) } ?? coworkerMentions(prompt, coworkers: coworkers)
            let targets = teamDiscussion ? coworkers : query.ids.isEmpty ? effectiveCoworker.map { [$0] } ?? [] : coworkers.filter { query.ids.contains($0.id) }
            return loaded && connected && !demo && (!busy || canQueueMessage) && !pendingChat && pendingQuestionReplies.isEmpty && !hasPendingQuestions
                && !workspaceSelectionPending && !settings.workspace.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !targets.isEmpty && query.ambiguous == nil && (!teamDiscussion || coworkers.count >= 2)
                && targets.allSatisfy { availability($0.provider)?.ready == true && ($0.effort == .default || effortOptions($0.provider, model: $0.model.isEmpty ? defaultModel($0.provider) : $0.model).contains($0.effort)) }
        }
        return loaded && connected && !demo && !busy && !pendingChat && pendingQuestionReplies.isEmpty && !hasPendingQuestions && !workspaceSelectionPending && !settings.workspace.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (chatting ? !chatMembers.isEmpty && (!teamDiscussion || chatMembers.count >= 2) && agentMentions(prompt, identities: chatIdentities).allSatisfy { chatMembers.contains($0) }
            && chatTargets.allSatisfy { chatMembers.contains($0) && availability($0)?.ready == true && effortIsValid($0) }
            : !team.isEmpty && team.allSatisfy { availability($0.provider)?.ready == true })
    }
    func availability(_ provider: Provider) -> AgentInfo? { agents.first { $0.provider == provider } }
    func statusLabel(_ provider: Provider) -> String {
        let label = availability(provider)?.label ?? "Checking"
        guard provider == .claude else { return label }
        let backend = settings.claudeBackend == .inherit ? claudeConfig?.backend : settings.claudeBackend == .deepseek ? "DeepSeek" : settings.claudeBackend == .custom ? "Custom endpoint" : nil
        guard let backend, backend != "Claude (Anthropic)" else { return label }
        return "\(backend) · \(label)"
    }

    func launch() {
        guard process == nil else { return }
        if options.smoke { print("Starting SwiftUI fixture engine"); fflush(stdout) }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/conductor-engine")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            showNotice("The Rust engine is missing. Build the app with scripts/bundle-macos.sh.", error: true)
            return
        }
        let child = Process()
        let incoming = Pipe()
        let outgoing = Pipe()
        let errors = Pipe()
        child.executableURL = executable
        child.arguments = [options.demo || options.smoke ? "--bridge" : "--connect"] + (options.demo ? ["--demo"] : [])
        if let dataDir = options.dataDir { child.arguments! += ["--data-dir", dataDir] }
        child.standardInput = incoming
        child.standardOutput = outgoing
        child.standardError = errors
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        let renderer = EventRenderer()
        let delivery = EventDelivery(render: renderer.render) { [weak self] event, rendered, chat in self?.apply(event, rendered: rendered, chat: chat) }
        self.delivery = delivery
        delivery.setScrolling(transcriptReadingHistory)
        reader = EventReader(receive: { event in
            delivery.enqueue(event)
        }, fail: { [weak self] message in
            DispatchQueue.main.async { self?.showNotice(message, error: true) }
        })
        let eventReader = reader!
        outgoing.fileHandleForReading.readabilityHandler = { file in
            let data = file.availableData
            if data.isEmpty { file.readabilityHandler = nil }
            else { eventReader.consume(data) }
        }
        // Drain diagnostic stderr without reflecting credentials or arbitrary CLI output into the UI.
        errors.fileHandleForReading.readabilityHandler = { file in
            if file.availableData.isEmpty { file.readabilityHandler = nil }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = false
                self.clearingInbox = false; self.pendingInboxBatches = 0; self.deletingRuns.removeAll()
                if !self.closing { self.showNotice("The agent engine stopped. Reopen the app to reconnect.", error: true) }
            }
        }
        do {
            try child.run()
            process = child
            connected = true
            if options.smoke { print("SwiftUI engine PID: \(child.processIdentifier)"); fflush(stdout) }
        } catch {
            showNotice("Could not start the Rust engine: \(error.localizedDescription)", error: true)
        }
    }

    func apply(_ event: EngineEvent, rendered: [Provider: [ResponseBlock]], chat: [String: [ResponseBlock]]) {
        if options.smoke {
            print("SwiftUI event: \(event.type), run status: \(event.run?.status.rawValue ?? "none")")
            fflush(stdout)
        }
        switch event.type {
        case "remote_state": remote.receive(event.remote)
        case "state":
            guard event.protocolVersion == 1, let settings = event.settings else {
                showNotice("This interface and engine use incompatible versions.", error: true)
                return
            }
            applying = true
            self.settings = settings
            applying = false
            runs = event.runs ?? []
            agents = event.agents ?? []
            demo = event.demo ?? false
            persistenceBlocked = event.persistenceBlocked ?? false
            if !loaded { newAgentNames = freshCoworkers(includeCurrent: false); draftCoworkers = makeRoleTeam(); coworkerLead = draftCoworkers.first?.id ?? "" }
            loaded = true
            claudeConfig = event.claudeConfig
            modelCatalogs = event.modelCatalogs ?? []
            let introduceChat = !self.settings.chatIntroduced && !demo && !options.smoke
            if introduceChat {
                self.settings.chatIntroduced = true
                self.settings.workflow = .conversation
                flushSettings()
            }
            if introduceChat { newTask() }
            else { restoreWorkspaceSelection() }
            if let errors = event.errors, !errors.isEmpty { showNotice(errors.joined(separator: "\n"), error: true) }
        case "agents_updated": agents = event.agents ?? []
        case "claude_config_updated":
            if let config = event.claudeConfig, config.workspace == settings.workspace && config.configDirOverride == settings.claudeConfigDir {
                claudeConfig = config
                modelCatalogs = event.modelCatalogs ?? modelCatalogs
            }
        case "run_updated", "run_detail":
            guard let run = event.run else { return }
            guard !deletedRunIDs.contains(run.id) else { return }
            for message in run.conversation?.messages ?? [] {
                if let request = message.questionRequest, pendingQuestionReplies.contains(request.id),
                   request.answers != nil || run.conversation?.mailbox?.contains(where: { $0.questionTarget?.requestId == request.id }) == true || !run.status.active {
                    pendingQuestionReplies.remove(request.id)
                }
                if let request = message.approvalRequest, request.decision != nil, pendingQuestionReplies.contains(request.id) { pendingQuestionReplies.remove(request.id) }
            }
            if pendingChat && event.type == "run_updated" && run.status.active && run.conversation?.messages.last(where: { $0.kind == "user" })?.text == submittedChatPrompt {
                pendingChat = false
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines) == submittedChatPrompt { prompt = "" }
                selectedRunID = run.id
                composingNewTask = false
                screen = "workspace"
            }
            if let index = runs.firstIndex(where: { $0.id == run.id }) {
                let summary = run.summary
                if runs[index] != summary { runs[index] = summary }
            }
            else {
                runs.insert(run.summary, at: 0)
                runs = Array(runs.prefix(100))
                if event.type == "run_updated" {
                    if run.projectWorkspace == settings.workspace {
                        selectedRunID = run.id
                        composerExpanded = false
                        screen = "workspace"
                    }
                    if options.smoke && smokeStarted { smokeRunID = run.id }
                }
            }
            if selectedRunID == run.id {
                let loadingConversation = selectedRun?.id != run.id || event.type == "run_detail"
                selectedRun = run
                if renderedResponses != rendered { renderedResponses = rendered }
                if renderedChat != chat { renderedChat = chat }
                if let conversation = run.conversation {
                    if loadingConversation { chatLead = conversation.lead; coworkerLead = conversation.leadId ?? conversation.coworkers?.first?.id ?? "" }
                    if composingNewTask { composingNewTask = false }
                    if !composerExpanded { composerExpanded = true }
                }
                if selectedProvider == nil || !run.stages.contains(where: { $0.provider == selectedProvider }) {
                    let provider = run.stages.first?.provider
                    if selectedProvider != provider { selectedProvider = provider }
                }
            }
            if !run.status.active && cancelling.contains(run.id) { cancelling.remove(run.id) }
            if options.smoke && smokeStarted && run.id == smokeRunID && !run.status.active && !pendingChat && !smokeCompletionScheduled {
                if smokeChatStep == 5, run.status == .waitingForUser,
                   let message = run.conversation?.pendingQuestions.last, let request = message.questionRequest {
                    let passed = hasPendingQuestions && !canRun && request.questions.count == 3
                        && request.questions[0].options.count == 2 && request.questions[1].multiSelect
                        && request.questions[2].options.isEmpty && message.author == .claude && canAnswerQuestion(runID: run.id, message: message)
                    guard passed else { print("SwiftUI engine smoke test failed: pending question card"); scheduleCapture(delay: 0.5); return }
                    let answers = request.questions.enumerated().map { index, question in
                        AgentQuestionDraft(selected: index == 0 ? ["o2"] : index == 1 ? ["o1", "o2"] : [], text: index == 2 ? "Keep @alex as ordinary answer text." : "").answer(question)
                    }
                    smokeChatStep = 6
                    if let error = answerQuestion(runID: run.id, message: message, answers: answers) {
                        print("SwiftUI engine smoke test failed: \(error)"); scheduleCapture(delay: 0.5)
                    }
                    return
                }
                var result = run.status == .completed && (run.conversation.map { chat in
                    chat.messages.contains { $0.kind == "assistant" && $0.status == .completed && !$0.text.isEmpty }
                } ?? (!run.stages.isEmpty && run.stages.allSatisfy { !$0.output.isEmpty }))
                if result, let conversation = run.conversation, conversation.members.contains(.claude), conversation.members.contains(.codex) {
                    if smokeChatStep < 3 {
                        if smokeChatStep == 2 {
                            teamDiscussion = true
                            if let error = setAgentModel(.codex, model: "fixture-codex-b") ?? setAgentEffort(.codex, effort: .high) { showNotice(error, error: true); return }
                            prompt = "Discuss the approach together and return the team's feedback."
                        } else if smokeChatStep == 1 {
                            let names = chatIdentities.map { identity in
                                identity.provider == .claude || identity.provider == .codex
                                    ? AgentIdentity(provider: identity.provider, name: identity.provider.teammateName, mention: identity.provider.teammateName.lowercased()) : identity
                            }
                            if let error = renameTeam(names) { showNotice(error, error: true); return }
                            prompt = "@maya continue after Alex's review."
                        } else { prompt = "@nova review the lead's response." }
                        smokeChatStep += 1
                        startRun()
                        return
                    }
                    let allAnswers = conversation.messages.filter { $0.kind == "assistant" }
                    let answers = Array(allAnswers.prefix(8))
                    result = result && answers.map(\.author) == [.claude, .codex, .claude, .claude, .codex, .qoder, .deepseek, .claude] && answers.first?.sessionId != nil && answers.first?.sessionId == answers.last?.sessionId
                        && conversation.identity(.claude).name == "Maya" && conversation.identity(.codex).mention == "alex"
                        && conversation.messages.contains { $0.teamDiscussion == true }
                        && conversation.messages.filter { $0.kind == "request" }.count == 3
                        && answers.suffix(5).dropFirst().dropLast().allSatisfy { $0.to == [.claude] }
                        && answers[1].model == "fixture-codex-a" && answers[4].model == "fixture-codex-b" && answers[1].sessionId != answers[4].sessionId
                        && answers[0].model == "deepseek-flash" && answers[7].model == "deepseek-flash"
                        && conversation.models?.contains(AgentModel(provider: .codex, model: "fixture-codex-b")) == true
                        && answers[0].effort == .max && answers[7].effort == .max && answers[1].effort == .low && answers[4].effort == .high
                        && conversation.efforts?.contains(AgentEffort(provider: .codex, effort: .high)) == true
                        && settings.agents.allSatisfy { $0.effort == .default }
                        && settings.agents.first { $0.provider == .codex }?.model.isEmpty == true
                    if result && smokeChatStep == 3 {
                        smokeChatStep = 4
                        screen = "history"
                        selectRun(run.id)
                        return
                    }
                    result = result && screen == "workspace" && chatRun?.id == run.id && !workspaceSelectionPending
                        && conversation.messages.filter { !$0.text.isEmpty }.allSatisfy { renderedChat[$0.id]?.isEmpty == false }
                    if let first = answers.first {
                        result = result && (renderedChat[first.id] ?? []).contains { block in
                            if case .table = block.kind { return block.children.count == 7 }; return false
                        }
                    }
                    if result && smokeChatStep == 4 {
                        smokeChatStep = 5
                        teamDiscussion = false
                        prompt = "ASK_HUMAN before continuing this task."
                        startRun()
                        return
                    }
                    result = result && smokeChatStep == 6 && allAnswers.count == 10 && allAnswers.suffix(2).allSatisfy { $0.author == .claude && $0.sessionId == answers[0].sessionId }
                        && conversation.pendingQuestions.isEmpty && conversation.messages.contains { $0.kind == "answer" && $0.to == [.claude] && $0.text.contains("@alex") }
                        && allAnswers[8].questionRequest?.answers?.count == 3 && pendingQuestionReplies.isEmpty
                    if result {
                        smokeCompletionScheduled = true
                        let runCount = runs.count
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                            guard let self else { return }
                            let savedCoworkers = self.chatIdentities
                            self.newTask()
                            let freshRoster = self.chatIdentities
                            let freshCoworkers = self.chatRun == nil && self.selectedRunID == nil
                                && Set(freshRoster.map(\.mention)).isDisjoint(with: savedCoworkers.map(\.mention))
                                && self.chatIdentities == freshRoster && matchingTeammates("", identities: freshRoster) == freshRoster
                            self.continueChat(run)
                            let restoredCoworkers = self.chatIdentities == savedCoworkers && self.chatRun?.conversation?.sessions.map(\.sessionId) == conversation.sessions.map(\.sessionId)
                            let passed = freshCoworkers && restoredCoworkers && verifyNativeMentionEditor() && self.runs.count == runCount && !self.busy && !self.pendingChat
                            if passed { print("SwiftUI fresh chat coworkers, stable autocomplete, saved coworker sessions, structured questions, model/effort selection and team discussion passed") }
                            print(passed ? "SwiftUI engine smoke test passed" : "SwiftUI engine smoke test failed")
                            self.scheduleCapture(delay: 0.5)
                        }
                        return
                    }
                }
                print(result ? "SwiftUI engine smoke test passed" : "SwiftUI engine smoke test failed")
                scheduleCapture(delay: 0.5)
            }
        case "team_queued":
            pendingChat = false
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines) == submittedChatPrompt { prompt = "" }
        case "attention_dismissed":
            pendingInboxBatches = max(0, pendingInboxBatches - 1)
            clearingInbox = pendingInboxBatches > 0
            for dismissal in event.items ?? [] {
                if let index = runs.firstIndex(where: { $0.id == dismissal.runId }) {
                    runs[index].attention?.removeAll { $0.key == dismissal.key }
                }
                if var run = selectedRun, run.id == dismissal.runId {
                    var keys = run.dismissedAttention ?? []
                    if !keys.contains(dismissal.key) { keys.append(dismissal.key) }
                    run.dismissedAttention = keys
                    selectedRun = run
                }
            }
        case "run_deleted":
            guard let id = event.runId else { return }
            deletedRunIDs.insert(id)
            deletingRuns.remove(id); cancelling.remove(id)
            runs.removeAll { $0.id == id }
            if chatToDelete?.id == id { chatToDelete = nil }
            if shareTaskID == id { shareTaskID = ""; isolationMode = "shared" }
            if selectedRunID == id || selectedRun?.id == id {
                let currentScreen = screen
                for message in selectedRun?.conversation?.messages ?? [] {
                    if let request = message.questionRequest { pendingQuestionReplies.remove(request.id) }
                    if let request = message.approvalRequest { pendingQuestionReplies.remove(request.id) }
                }
                newTask()
                selectedProvider = nil; renderedResponses = [:]
                setTranscriptReadingHistory(false)
                if currentScreen != "workspace" { screen = currentScreen }
            }
            showNotice("Chat deleted. Workspace files were kept.", error: false)
        case "notice":
            if event.error == true { pendingChat = false; pendingQuestionReplies.removeAll(); deletingRuns.removeAll(); clearingInbox = false; pendingInboxBatches = 0 }
            showNotice(event.message ?? "Engine notice", error: event.error ?? false)
        default: break
        }
        if options.smoke && !smokeStarted && loaded && !agents.contains(where: { $0.status == "checking" }) {
            // Smoke runs are limited to explicitly configured executable fixtures in a development data directory.
            if options.dataDir == nil || team.isEmpty || !team.allSatisfy({ $0.executable.contains("/target/") && $0.executable.contains("fixture") }) {
                showNotice("Smoke testing requires a development data directory and fixture executables.", error: true)
                scheduleCapture(delay: 0.5)
            } else {
                smokeStarted = true
                if settings.workflow == .conversation {
                    let names = AgentIdentity.suggestedTeam(members: chatMembers, overrides: [AgentIdentity(provider: .claude, name: "Atlas", mention: "atlas"), AgentIdentity(provider: .codex, name: "Nova", mention: "nova")])
                    if let error = renameTeam(names) { showNotice(error, error: true); scheduleCapture(delay: 0.5); return }
                    if let error = setAgentModel(.claude, model: "deepseek-flash") ?? setAgentModel(.codex, model: "fixture-codex-a") { showNotice(error, error: true); scheduleCapture(delay: 0.5); return }
                    if let error = setAgentEffort(.claude, effort: .max) ?? setAgentEffort(.codex, effort: .low) ?? setAgentEffort(.qoder, effort: .medium) ?? setAgentEffort(.deepseek, effort: .low) { showNotice(error, error: true); scheduleCapture(delay: 0.5); return }
                }
                prompt = "Run the local SwiftUI integration fixture." + (settings.workflow == .conversation ? " SWIFTUI_MARKDOWN" : "")
                print("SwiftUI fixture ready: \(canRun), busy: \(busy), selected: \(team.count)")
                fflush(stdout)
                startRun()
            }
        } else if !options.smoke && loaded && options.capture != nil && !agents.contains(where: { $0.status == "checking" }) {
            scheduleCapture(delay: 0.8)
        }
    }

    private func send(_ command: [String: Any]) {
        guard let input, connected else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
            data.append(10)
            writer.async { [weak self] in
                do { try input.write(contentsOf: data) }
                catch { DispatchQueue.main.async { self?.showNotice("The engine connection closed.", error: true) } }
            }
        } catch { showNotice("Could not encode the engine request.", error: true) }
    }

    private func encodedSettings() -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? JSONSerialization.jsonObject(with: encoder.encode(settings))) as? [String: Any] ?? [:]
    }

    private func scheduleSettings() {
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushSettings()
        }
    }

    func flushSettings() {
        saving?.cancel()
        send(["type": "update_settings", "settings": encodedSettings()])
    }
    func rescan() {
        flushSettings()
        send(["type": "session_key", "key": sessionKey, "claude_key": claudeSessionKey, "kiro_key": kiroSessionKey])
        send(["type": "inspect_claude"])
        send(["type": "discover"])
    }
    func startRun() {
        guard canRun else { return }
        focusedMessageID = nil
        saving?.cancel()
        send(["type": "session_key", "key": sessionKey, "claude_key": claudeSessionKey, "kiro_key": kiroSessionKey])
        if chatting {
            pendingChat = true
            submittedChatPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if usesCoworkerTeams, let lead = effectiveCoworker {
                let isolation: [String: Any] = isolationMode == "share_task" ? ["mode": "share_task", "run_id": shareTaskID] : ["mode": isolationMode]
                send(["type": "team_chat", "run_id": chatRun?.id as Any? ?? NSNull(), "prompt": prompt, "lead_id": lead.id, "target_id": forcedRecipientID as Any? ?? NSNull(), "settings": encodedSettings(), "coworkers": coworkers.map(\.command), "discussion": teamDiscussion, "isolation": isolation])
            } else { send(["type": "chat", "run_id": chatRun?.id as Any? ?? NSNull(), "prompt": prompt, "lead": effectiveLead.rawValue, "settings": encodedSettings(), "names": chatIdentities.map(\.command), "models": chatModels.map(\.command), "efforts": chatEfforts.map(\.command), "team_discussion": teamDiscussion]) }
        } else { send(["type": "start", "prompt": prompt, "settings": encodedSettings()]) }
    }
    func canAnswerQuestion(runID: String, message: ChatMessage) -> Bool {
        loaded && connected && !demo && !busy && !pendingChat && pendingQuestionReplies.isEmpty
        && selectedRun?.id == runID && message.questionRequest?.answers == nil && message.questionRequest != nil
        && message.author.map { availability($0)?.ready == true && effortIsValid($0) } == true
        && questionDelegate(runID: runID, message: message) == nil
    }
    func questionDelegate(runID: String, message: ChatMessage) -> MailboxDelivery? {
        guard selectedRun?.id == runID, let request = message.questionRequest, request.answers == nil else { return nil }
        return selectedRun?.conversation?.mailbox?.last { $0.pendingQuestionAnswer && $0.questionTarget?.messageId == message.id && $0.questionTarget?.requestId == request.id }
    }
    func questionTeammates(runID: String, message: ChatMessage) -> [Coworker] {
        guard canAnswerQuestion(runID: runID, message: message), let chat = selectedRun?.conversation,
              let owner = message.authorId,
              chat.mailbox?.contains(where: { $0.to == owner && $0.responseId == message.id && $0.state == "waiting_for_user" }) == true else { return [] }
        return (chat.coworkers ?? []).filter { worker in
            worker.id != owner && availability(worker.provider)?.ready == true
                && (worker.effort == .default || effortOptions(worker.provider, model: worker.model.isEmpty ? defaultModel(worker.provider) : worker.model).contains(worker.effort))
                && !chat.pendingQuestions.contains(where: { $0.authorId == worker.id })
                && !chat.pendingApprovals.contains(where: { $0.authorId == worker.id })
        }
    }
    func delegateQuestion(runID: String, message: ChatMessage, coworkerID: String) -> String? {
        guard let request = message.questionRequest, questionTeammates(runID: runID, message: message).contains(where: { $0.id == coworkerID }) else {
            return "Choose an available teammate in this chat after the current exchange finishes."
        }
        saving?.cancel()
        pendingQuestionReplies.insert(request.id)
        send(["type": "session_key", "key": sessionKey, "claude_key": claudeSessionKey, "kiro_key": kiroSessionKey])
        send(["type": "delegate_question", "run_id": runID, "message_id": message.id, "request_id": request.id,
              "coworker_id": coworkerID, "settings": encodedSettings()])
        return nil
    }
    func answerQuestion(runID: String, message: ChatMessage, answers: [AgentQuestionAnswer]) -> String? {
        guard canAnswerQuestion(runID: runID, message: message), let request = message.questionRequest else {
            return "Wait for the current reply, or check this agent's connection before answering."
        }
        guard answers.count == request.questions.count,
              request.questions.allSatisfy({ question in
                  let matches = answers.filter { $0.questionId == question.id }
                  guard matches.count == 1, let answer = matches.first else { return false }
                  return answer.skipped ? answer.optionIds.isEmpty && answer.text.isEmpty
                      : (!answer.optionIds.isEmpty || !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              }) else { return "Answer or skip each question." }
        saving?.cancel()
        pendingQuestionReplies.insert(request.id)
        send(["type": "session_key", "key": sessionKey, "claude_key": claudeSessionKey, "kiro_key": kiroSessionKey])
        let usesMailbox = chatRun?.conversation?.mailbox?.contains { $0.responseId == message.id && $0.state == "waiting_for_user" } == true
        send(["type": usesMailbox ? "team_answer" : "answer_question", "run_id": runID, "message_id": message.id, "request_id": request.id,
              "answers": answers.map(\.command), "settings": encodedSettings()])
        return nil
    }
    func cancel(_ id: String) {
        cancelling.insert(id)
        send(["type": "cancel", "run_id": id])
    }
    var canClearInbox: Bool { loaded && connected && !demo && !persistenceBlocked && !clearingInbox && attentionCount > 0 }
    func dismissAttention(run: RunSummary, item: AttentionItem) {
        guard canClearInbox else { return }
        dismissAttention([AttentionDismissal(runId: run.id, id: item.id, revision: item.key.revision)])
    }
    func clearInbox() {
        guard canClearInbox else { return }
        dismissAttention(runs.flatMap { run in
            (run.attention ?? []).map { AttentionDismissal(runId: run.id, id: $0.id, revision: $0.key.revision) }
        })
    }
    private func dismissAttention(_ items: [AttentionDismissal]) {
        guard !items.isEmpty else { return }
        clearingInbox = true
        // Keep a large history beneath the bridge's 1 MiB request limit.
        pendingInboxBatches = (items.count + 499) / 500
        for start in stride(from: 0, to: items.count, by: 500) {
            send(["type": "dismiss_attention", "items": items[start..<min(start + 500, items.count)].map(\.command)])
        }
    }
    func canDeleteRun(_ run: RunSummary) -> Bool {
        loaded && connected && !demo && !persistenceBlocked && !run.status.active
            && !deletingRuns.contains(run.id) && !pendingChat && pendingQuestionReplies.isEmpty
    }
    func requestDeleteRun(_ run: RunSummary) { if canDeleteRun(run) { chatToDelete = run } }
    func deleteRun(_ run: RunSummary) {
        guard let current = runs.first(where: { $0.id == run.id }) else { return }
        guard canDeleteRun(current) else {
            showNotice("Wait for this chat's agents to stop before deleting it.", error: true)
            return
        }
        chatToDelete = nil
        deletingRuns.insert(run.id)
        send(["type": "delete_run", "run_id": run.id])
    }
    func selectRun(_ id: String, navigate: Bool = true) {
        if selectedRunID != id { teamDiscussion = false }
        if navigate {
            if let summary = runs.first(where: { $0.id == id }), summary.workflow == .conversation {
                let changingChat = settings.workspace != summary.workspace || selectedRunID != id
                if settings.workspace != summary.workspace { selectWorkspace(summary.workspace) }
                if changingChat { prompt = "" }
                settings.workflow = .conversation
                screen = "workspace"
            } else { screen = "history" }
        }
        composingNewTask = false
        pendingChat = false
        selectedRunID = id
        selectedRun = nil
        selectedProvider = nil
        renderedResponses = [:]
        renderedChat = [:]
        send(["type": "get_run", "run_id": id])
    }
    func export(_ id: String) { send(["type": "export", "run_id": id]) }
    func reuse(_ run: RunRecord) {
        teamDiscussion = false
        selectWorkspace(run.projectWorkspace)
        prompt = run.prompt
        settings.workflow = run.workflow
        for index in settings.agents.indices { settings.agents[index].selected = (run.conversation?.members ?? run.stages.map(\.provider)).contains(settings.agents[index].provider) }
        selectedRunID = nil
        selectedRun = nil
        renderedChat = [:]
        composerExpanded = true
        composingNewTask = true
        newAgentNames = freshCoworkers(excluding: run.conversation?.names ?? [])
        newAgentModels = run.conversation?.models ?? []
        newAgentEfforts = run.conversation?.efforts ?? []
        let template = run.conversation?.coworkers ?? []
        draftCoworkers = template.isEmpty ? makeRoleTeam() : freshTeam(template: template, keepChoices: true)
        coworkerLead = draftCoworkers.first?.id ?? ""
        nameDrafts[settings.workspace] = newAgentNames
        screen = "workspace"
    }
    func startChat(from run: RunRecord) {
        reuse(run)
        settings.workflow = .conversation
        chatLead = run.conversation?.lead ?? run.stages.first?.provider ?? effectiveLead
    }
    func newTask() {
        draftCoworkers = freshTeam(template: coworkers.isEmpty ? makeRoleTeam() : coworkers, keepChoices: false)
        coworkerLead = draftCoworkers.first?.id ?? ""; coworkerDrafts[settings.workspace] = draftCoworkers
        focusedMessageID = nil; inspectorTab = "team"
        newAgentNames = freshCoworkers(excluding: chatRun?.conversation?.names ?? [])
        prompt = ""
        newAgentModels = []
        newAgentEfforts = []
        nameDrafts[settings.workspace] = newAgentNames
        drafts[settings.workspace] = ""
        modelDrafts[settings.workspace] = []
        effortDrafts[settings.workspace] = []
        teamDiscussion = false
        composerExpanded = true
        composingNewTask = true
        pendingChat = false
        selectedRunID = nil
        selectedRun = nil
        renderedChat = [:]
        settings.workflow = .conversation
        screen = "workspace"
    }
    func mention(_ provider: Provider) { prompt += (prompt.isEmpty || prompt.hasSuffix(" ") ? "" : " ") + "@\(identity(provider).mention) " }
    func renameAgent(_ provider: Provider, name: String, mention: String) -> String? {
        guard chatMembers.contains(provider) else { return "Choose an agent in this task's team." }
        var names = chatIdentities
        if let index = names.firstIndex(where: { $0.provider == provider }) { names[index] = AgentIdentity(provider: provider, name: name, mention: mention) }
        return renameTeam(names)
    }
    func renameTeam(_ proposed: [AgentIdentity]) -> String? {
        guard canEditTeam else { return "Wait for the current reply before editing its team." }
        let providers = Set(proposed.map(\.provider))
        guard proposed.count == chatMembers.count && providers.count == proposed.count && providers == Set(chatMembers) else {
            return "Name each teammate in this task exactly once."
        }
        let names = proposed.map { AgentIdentity(provider: $0.provider, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), mention: $0.mention.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" }).lowercased()) }
        for identity in names { if let error = identity.validationError(in: names) { return error } }
        if var run = chatRun {
            run.conversation?.names = names
            selectedRun = run
            send(["type": "rename_team", "run_id": run.id, "names": names.map(\.command)])
        } else {
            let retained = newAgentNames.filter { identity in
                !providers.contains(identity.provider) && !names.contains { $0.name.lowercased() == identity.name.lowercased() || $0.mention.lowercased() == identity.mention.lowercased() }
            }
            newAgentNames = AgentIdentity.suggestedTeam(members: Provider.allCases, overrides: names + retained, excluding: otherCoworkers + newAgentNames)
            allocatedCoworkers += names
            nameDrafts[settings.workspace] = newAgentNames
        }
        return nil
    }
    func continueChat(_ run: RunRecord) {
        let changingChat = settings.workspace != run.projectWorkspace || selectedRunID != run.id
        if changingChat { teamDiscussion = false }
        if settings.workspace != run.projectWorkspace { selectWorkspace(run.projectWorkspace) }
        if changingChat { prompt = "" }
        selectedRunID = run.id
        selectedRun = run
        composingNewTask = false
        chatLead = run.conversation?.lead ?? .claude
        coworkerLead = run.conversation?.leadId ?? run.conversation?.coworkers?.first?.id ?? ""
        settings.workflow = .conversation
        screen = "workspace"
        send(["type": "get_run", "run_id": run.id])
    }
    func setClaudeBackend(_ backend: ClaudeBackend) {
        guard backend != settings.claudeBackend else { return }
        claudeSessionKey = ""
        settings.claudeBackend = backend
        if let index = settings.agents.firstIndex(where: { $0.provider == .claude }) { settings.agents[index].model = "" }
        rescan()
    }
    func chooseClaudeConfigFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use configuration folder"
        panel.title = "Claude Code configuration folder"
        if let path = claudeConfig?.configDir { panel.directoryURL = URL(fileURLWithPath: path) }
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK, let url = panel.url { self?.settings.claudeConfigDir = url.path; self?.rescan() }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
    func selectWorkspace(_ path: String) {
        var next = settings
        next.workspace = path
        if !path.isEmpty && !next.workspaceFolders.contains(path) { next.workspaceFolders.append(path) }
        activateWorkspace(next)
    }
    private func activateWorkspace(_ next: Settings) {
        coworkerDrafts[settings.workspace] = draftCoworkers
        teamDiscussion = false
        drafts[settings.workspace] = prompt
        nameDrafts[settings.workspace] = newAgentNames
        modelDrafts[settings.workspace] = newAgentModels
        effortDrafts[settings.workspace] = newAgentEfforts
        settings = next
        draftCoworkers = coworkerDrafts[next.workspace] ?? makeRoleTeam()
        coworkerLead = draftCoworkers.first?.id ?? ""
        prompt = drafts[next.workspace] ?? ""
        newAgentNames = nameDrafts[next.workspace] ?? freshCoworkers()
        nameDrafts[next.workspace] = newAgentNames
        newAgentModels = modelDrafts[next.workspace] ?? []
        newAgentEfforts = effortDrafts[next.workspace] ?? []
        composingNewTask = true
        composerExpanded = true
        screen = "workspace"
        selectedRunID = nil
        selectedRun = nil
        selectedProvider = nil
        renderedResponses = [:]
        renderedChat = [:]
        restoreWorkspaceSelection()
    }
    private func restoreWorkspaceSelection() {
        let first = screen == "workspace" && settings.workflow == .conversation
            ? workspaceRuns.first(where: { $0.workflow == .conversation }) : workspaceRuns.first
        if let first { selectRun(first.id, navigate: false) }
    }
    func removeWorkspace(_ path: String) {
        var next = settings
        next.workspaceFolders.removeAll { $0 == path }
        if next.workspace == path {
            next.workspace = next.workspaceFolders.first ?? ""
            activateWorkspace(next)
        } else { settings = next }
    }
    func addWorkspaceFolders(_ urls: [URL]) {
        let paths = urls.compactMap { url -> String? in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
        }
        guard let first = paths.first else {
            showNotice("Choose an existing folder to add to the workspace.", error: true)
            return
        }
        var next = settings
        for path in paths where !next.workspaceFolders.contains(path) { next.workspaceFolders.append(path) }
        next.workspace = first
        activateWorkspace(next)
    }
    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Add workspace folders"
        panel.prompt = "Add folders"
        panel.directoryURL = settings.workspace.isEmpty ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: settings.workspace)
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK { self?.addWorkspaceFolders(panel.urls) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
    func showNotice(_ message: String, error: Bool = false) {
        if options.smoke { print("SwiftUI fixture notice: \(message)"); fflush(stdout) }
        notice = message
        noticeIsError = error
        noticeGeneration += 1
        let generation = noticeGeneration
        if !persistenceBlocked {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if self?.noticeGeneration == generation { self?.notice = nil }
            }
        }
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showNotice("Copied response")
    }
    func shutdown() async {
        closing = true
        if loaded { flushSettings() }
        send(["type": "shutdown"])
        if let input { writer.async { try? input.close() } }
        for _ in 0..<50 {
            if process?.isRunning != true { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        process?.terminate()
    }
    private func scheduleCapture(delay: Double) {
        guard !captureScheduled, options.capture != nil else { return }
        captureScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.capture() }
    }
    private func capture() {
        guard let path = options.capture, let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView else { return }
        let renderer = ImageRenderer(content: LayoutPreview(width: view.bounds.width).environmentObject(self)
            .environment(\.colorScheme, .dark).tint(Theme.accent)
            .frame(width: view.bounds.width, height: view.bounds.height, alignment: .topLeading))
        renderer.scale = view.window?.backingScaleFactor ?? 2
        if let image = renderer.cgImage,
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            do { try data.write(to: URL(fileURLWithPath: path)); print("Saved SwiftUI layout preview: \(path)"); fflush(stdout) }
            catch { print("SwiftUI render failed: \(error)"); fflush(stdout) }
        } else { print("SwiftUI layout rendering is unavailable"); fflush(stdout) }
        Task {
            await shutdown()
            if options.quitTest { NSApp.terminate(nil) } else { exit(0) }
        }
    }
}
