import Foundation
import AppKit
import SwiftUI

// Exercise the native store used by the team editor, mentions, Inbox and Changes pane.
@main
enum TeamStoreSmoke {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--native-preview") { NSApplication.shared.setActivationPolicy(.prohibited) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/team-store-smoke")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let store = EngineStore(options: LaunchOptions())
        store.settings.workspace = first.path
        store.settings.workspaceFolders = [first.path, second.path]
        store.settings.workflow = .conversation
        store.settings.claudeBackend = .anthropic
        for index in store.settings.agents.indices { store.settings.agents[index].selected = [.claude, .codex].contains(store.settings.agents[index].provider) }
        store.loaded = true; store.connected = true
        store.agents = Provider.allCases.map { AgentInfo(provider: $0, status: "ready", label: "Fixture", detail: "Fixture") }
        expect(store.effortOptions(.codex).contains(.max), "Codex Default must offer Max before the catalogue loads")
        store.modelCatalogs = [ModelCatalog(provider: .codex, source: "Fixture", options: [
            ModelOption(id: "model-a", label: "Model A", effortLevels: [.low, .high]),
            ModelOption(id: "model-b", label: "Model B", effortLevels: [.low, .high]),
            ModelOption(id: "model-c", label: "Model C", effortLevels: [.low, .high, .max, .ultra])
        ], effortLevels: [.low, .medium, .high, .xhigh, .max])]
        expect(store.effortOptions(.codex).contains(.max), "Codex Default must keep Max after catalogue delivery")
        expect(!store.effortOptions(.codex, model: "model-a").contains(.max), "Explicit models must retain their supported effort limits")
        expect(Array(store.effortOptions(.codex, model: "model-c").suffix(2)) == [.max, .ultra], "The picker must expose the full advertised range for a selected model")
        store.resetRoleTeam()
        let original = store.coworkers
        expect(original.map(\.role) == [.architect, .builder, .reviewer], "The role template must create all three roles")
        expect(original.map(\.provider) == [.claude, .codex, .codex] && Set(original.map(\.id)).count == 3, "Two roles on Codex must have different identities")
        expect(store.chatIdentities.map(\.id) == original.map(\.id), "Autocomplete must use coworker IDs rather than connections")
        expect(coworkerMentions("@codex inspect", coworkers: original).ambiguous != nil, "A connection alias must be ambiguous when two coworkers share it")
        expect(matchingTeammates("cod", identities: store.chatIdentities).count == 2, "Autocomplete must show both Codex coworkers")
        expect(coworkerMentions("@\(original[2].mention) review", coworkers: original).ids == [original[2].id], "A personal mention must select exactly its coworker")
        expect(coworkerMentions("mail@\(original[1].mention) `@\(original[2].mention)`\n```\n@\(original[0].mention)\n```", coworkers: original).ids.isEmpty, "Code and email must not invoke coworkers")
        var maxBuilder = original[1]; maxBuilder.effort = .max
        expect(store.updateCoworker(maxBuilder) == nil && store.coworkers[1].effort == .max, "A coworker using Codex Default must accept and retain Max")
        maxBuilder.model = "model-a"
        expect(store.updateCoworker(maxBuilder) != nil, "Max must be rejected for an explicit model that does not advertise it")
        var builder = original[1]; builder.model = "model-a"; builder.effort = .low
        var reviewer = original[2]; reviewer.model = "model-b"; reviewer.effort = .high
        expect(store.updateCoworker(builder) == nil && store.updateCoworker(reviewer) == nil, "The editor must accept separate models and efforts on one connection")
        expect(store.coworkers[1].model == "model-a" && store.coworkers[2].effort == .high && store.settings.agents.first { $0.provider == .codex }?.model == "", "Coworker choices must preserve connection defaults")
        var invalid = reviewer; invalid.mention = builder.mention
        expect(store.updateCoworker(invalid) != nil, "The editor must reject stealing another coworker's handle")
        store.prompt = "@codex ambiguous"
        expect(!store.canRun, "Sending an ambiguous connection mention must be blocked")
        store.prompt = "@\(builder.mention) work"
        expect(store.canRun, "A ready named coworker must be invokable")
        store.teamDiscussion = true
        expect(store.discussionHint.contains("4 replies"), "Discussion counts must include every coworker, including duplicate connections")
        store.teamDiscussion = false
        let firstDraft = store.coworkers
        store.selectWorkspace(second.path)
        expect(Set(store.coworkers.map(\.id)).isDisjoint(with: firstDraft.map(\.id)), "Another workspace must have independent draft coworkers")
        store.selectWorkspace(first.path)
        expect(store.coworkers == firstDraft, "Returning to a workspace must restore its team and model choices")
        store.newTask()
        expect(Set(store.coworkers.map(\.id)).isDisjoint(with: firstDraft.map(\.id)) && Set(store.coworkers.map(\.mention)).isDisjoint(with: firstDraft.map(\.mention)), "New Chat must create fresh IDs and employee names")

        var run = RunRecord(id: UUID().uuidString.lowercased(), prompt: "Fixture isolated task", workspace: root.appendingPathComponent("checkout").path, workflow: .conversation,
                            createdAt: "2026-10-11T00:00:00Z", finishedAt: nil, status: .completed, stages: [])
        run.workspaceInfo = WorkspaceInfo(project: first.path, path: run.workspace, branch: "codex/team-fixture", isolated: true, baseCommit: "fixture")
        run.conversation = TaskConversation(members: [.claude, .codex], lead: .claude, messages: [], sessions: [
            AgentSession(provider: .codex, sessionId: "builder-native-id", scope: "builder-scope", coworkerId: builder.id),
            AgentSession(provider: .codex, sessionId: "reviewer-native-id", scope: "reviewer-scope", coworkerId: reviewer.id)
        ], coworkers: [original[0], builder, reviewer], leadId: builder.id, mailbox: [])
        store.runs = [run.summary]; store.continueChat(run)
        expect(store.workspaceRun?.id == run.id && store.settings.workspace == first.path, "An isolated chat must remain grouped under its project")
        var renamed = builder; renamed.name = "Atlas"; renamed.mention = "atlas"
        expect(store.updateCoworker(renamed) == nil && store.coworkers[1].id == builder.id && store.chatRun?.conversation?.sessions.count == 2, "Renaming must preserve identity and both native sessions")
        expect(store.chatRun?.summary.matchesSearch("Atlas") == true && store.chatRun?.summary.matchesSearch("Reviewer") == true, "History must search employee names and roles")
        store.reuse(store.chatRun!)
        expect(Set(store.coworkers.map(\.id)).isDisjoint(with: original.map(\.id)) && store.coworkers[1].model == "model-a" && store.coworkers[2].effort == .high, "Use Task Again must keep role/model/effort choices while creating independent coworkers")
        let question = AgentQuestionRequest(id: "question", questions: [AgentUserQuestion(id: "q", header: "Scope", question: "Which scope?", options: [], multiSelect: false)], answers: nil)
        let approval = AgentApprovalRequest(id: "approval", summary: "Run a check", argv: ["cargo", "test"], decision: nil, result: nil)
        let usage = Usage(inputTokens: 0, outputTokens: 0, costUsd: nil)
        var questionMessage = ChatMessage(id: "q-message", at: run.createdAt, kind: "assistant", author: .codex, to: [], text: "Need scope", status: .waitingForUser, model: "model-b", sessionId: "reviewer-native-id", logs: [], usage: usage, error: nil, questionRequest: question)
        questionMessage.authorId = reviewer.id
        var approvalMessage = ChatMessage(id: "a-message", at: run.createdAt, kind: "assistant", author: .codex, to: [], text: "Need permission", status: .waitingForUser, model: "model-a", sessionId: "builder-native-id", logs: [], usage: usage, error: nil)
        approvalMessage.authorId = builder.id; approvalMessage.approvalRequest = approval
        var readyBuilder = builder; readyBuilder.attention = "ready_for_review"
        run.conversation = TaskConversation(members: [.claude, .codex], lead: .claude, messages: [questionMessage, approvalMessage], sessions: [], coworkers: [original[0], readyBuilder, reviewer], leadId: builder.id, mailbox: [])
        store.runs = [run.summary]; store.continueChat(run)
        expect(store.attentionCount == 3 && store.hasPendingQuestions, "Inbox must collect a question, approval and review across coworkers")
        let item = run.summary.attention!.first { $0.kind == "question" }!
        store.openAttention(run: run.summary, item: item)
        expect(store.focusedMessageID == questionMessage.id && store.screen == "workspace", "Inbox must open the owning chat and jump to the question")
        expect(commandArguments("cargo test --locked") == ["cargo", "test", "--locked"] && commandArguments("printf '%s' '$(touch injected)' \"a b\"") == ["printf", "%s", "$(touch injected)", "a b"], "Check input must parse literal argv without shell expansion")
        expect(commandArguments("cargo 'unfinished") == nil && commandArguments(" ") == nil, "Invalid or empty check commands must stay local")

        // A question can be answered by another identity on the same connection.
        run = RunRecord(id: run.id, prompt: run.prompt, workspace: run.workspace, workflow: run.workflow,
                        createdAt: run.createdAt, finishedAt: run.finishedAt, status: .waitingForUser, stages: run.stages, workspaceInfo: run.workspaceInfo)
        let waitingMail = MailboxDelivery(id: "waiting", at: run.createdAt, from: nil, to: reviewer.id, text: "Original task", kind: "user", state: "waiting_for_user", replyTo: nil, responseId: questionMessage.id)
        run.conversation = TaskConversation(members: [.claude, .codex], lead: .claude, messages: [questionMessage], sessions: [], coworkers: original, leadId: builder.id, mailbox: [waitingMail])
        store.runs = [run.summary]; store.continueChat(run)
        expect(store.questionTeammates(runID: run.id, message: questionMessage).contains { $0.id == builder.id }
               && !store.questionTeammates(runID: run.id, message: questionMessage).contains { $0.id == reviewer.id }, "Teammate answers must route by coworker ID and exclude the asker")
        expect(store.delegateQuestion(runID: run.id, message: questionMessage, coworkerID: reviewer.id) != nil && store.pendingQuestionReplies.isEmpty, "Self-delegation must stay local")
        let assignment = MailboxDelivery(id: "answer-delivery", at: run.createdAt, from: reviewer.id, to: builder.id, text: "Answer the questions", kind: "question_answer", state: "delivered", replyTo: waitingMail.id, responseId: "peer-response", questionTarget: QuestionTarget(messageId: questionMessage.id, requestId: question.id))
        run.conversation?.mailbox?.append(assignment)
        store.runs = [run.summary]; store.continueChat(run)
        expect(store.questionDelegate(runID: run.id, message: questionMessage)?.to == builder.id && !store.canAnswerQuestion(runID: run.id, message: questionMessage), "In-flight delegation must show its owner and prevent competing human answers")
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let attributedQuestion = try decoder.decode(AgentQuestionRequest.self, from: Data("{\"id\":\"question\",\"questions\":[],\"answers\":[],\"answered_by\":\"\(builder.id)\"}".utf8))
        expect(attributedQuestion.answeredBy == builder.id, "Answered cards must retain the answering coworker's identity")

        // Decode actual engine output as well as constructed native records.
        if let path = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".json") }) {
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let records = try decoder.decode([RunRecord].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            expect(records.contains { ($0.conversation?.coworkers?.count ?? 0) == 3 && $0.workspaceInfo?.isolated == true && $0.changes != nil }, "Rust team, mailbox and diff records must decode in the native app")
            if CommandLine.arguments.contains("--render") {
                store.runs = records.map(\.summary)
                if let first = records.first { store.settings.workspace = first.projectWorkspace; store.settings.workspaceFolders = [first.projectWorkspace] }
                store.screen = "attention"
                try render(store, name: "inbox")
                for (name, matches) in [("approval", { (run: RunRecord) in !(run.conversation?.pendingApprovals.isEmpty ?? true) }), ("question", { (run: RunRecord) in !(run.conversation?.pendingQuestions.isEmpty ?? true) }), ("changes", { (run: RunRecord) in run.changes?.files.contains { $0.ownerId != nil } == true })] {
                    guard var record = records.first(where: matches), let chat = record.conversation else { fatalError("Missing \(name) layout fixture") }
                    record.conversation = TaskConversation(members: chat.members, lead: chat.lead, messages: Array(chat.messages.suffix(2)), sessions: chat.sessions, names: chat.names, models: chat.models, efforts: chat.efforts, coworkers: chat.coworkers, leadId: chat.leadId, mailbox: chat.mailbox)
                    store.continueChat(record); store.inspectorTab = name == "changes" ? "changes" : "team"
                    try render(store, name: name)
                    if name == "question" && CommandLine.arguments.contains("--native-preview") { try renderNativeQuestion(store) }
                }
                store.newTask(); store.resetRoleTeam()
                try render(store, name: "new-team")
            }
        }
        print("Swift team store passed: scoped teammate question choices, answer attribution, duplicate sessions, role templates, autocomplete, Inbox navigation and literal check arguments.")
    }
    @MainActor private static func render(_ store: EngineStore, name: String) throws {
        let renderer = ImageRenderer(content: LayoutPreview(width: 1440).environmentObject(store).environment(\.colorScheme, .dark).tint(Theme.accent).frame(width: 1440, height: 940))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Could not render \(name)") }
        let path = "target/team-\(name)-preview.png"
        try data.write(to: URL(fileURLWithPath: path)); print("Rendered \(path)")
    }
    @MainActor private static func renderNativeQuestion(_ store: EngineStore) throws {
        // Native menus and text fields are omitted by ImageRenderer. Render our
        // own hidden fixture window without driving the installed application.
        store.focusedMessageID = nil
        let host = NSHostingView(rootView: RootView().environmentObject(store).environment(\.colorScheme, .dark).tint(Theme.accent))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 940)
        let hiddenWindow = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        hiddenWindow.appearance = NSAppearance(named: .darkAqua)
        hiddenWindow.contentView = host
        defer { withExtendedLifetime(hiddenWindow) {} }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        expect(!hiddenWindow.isVisible, "The native question fixture must stay off the user's desktop")
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Missing native question bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Missing native question image") }
        try data.write(to: URL(fileURLWithPath: "target/team-question-native-preview.png"))
        print("Rendered native question controls without a visible window")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
}
