import Foundation

// Exercise the same store actions used by the native folder picker and sidebar.
@main
enum WorkspaceSmoke {
    @MainActor static func main() throws {
        let area = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/workspace-smoke")
        let first = area.appendingPathComponent("first project")
        let second = area.appendingPathComponent("second project")
        let alias = area.appendingPathComponent("second alias")
        for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        if !FileManager.default.fileExists(atPath: alias.path) {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        }
        let file = area.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: file)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var legacy = Settings()
        legacy.workspace = first.path
        var legacyJSON = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
        legacyJSON.removeValue(forKey: "workspace_folders")
        legacyJSON.removeValue(forKey: "chat_introduced")
        legacyJSON["agents"] = (legacyJSON["agents"] as! [[String: Any]]).filter { $0["provider"] as? String != "kiro" }.map { agent in
            var value = agent; value.removeValue(forKey: "effort"); return value
        }
        for key in ["claude_backend", "claude_base_url", "claude_config_dir"] { legacyJSON.removeValue(forKey: key) }
        let restored = try decoder.decode(Settings.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        expect(restored.workspaceFolders == [first.path], "The old workspace must migrate without an extra current-directory entry")
        expect(restored.claudeBackend == .inherit && restored.claudeConfigDir.isEmpty, "Existing installations must keep their detected Claude configuration")
        expect(restored.agents.last?.provider == .kiro && restored.agents.last?.selected == false, "Existing preferences must gain an unselected Kiro connection")
        expect(restored.agents.allSatisfy { $0.effort == .default }, "Legacy connections must retain CLI effort defaults")

        var legacyOptions = LaunchOptions()
        legacyOptions.smoke = true
        let store = EngineStore(options: legacyOptions)
        store.settings = restored
        store.prompt = "Draft for the first project"
        store.addWorkspaceFolders([first, second, alias, file])
        expect(store.settings.workspaceFolders == [first.path, second.path], "Multiple selections must ignore files and deduplicate folder aliases")
        store.selectWorkspace(second.path)
        expect(store.prompt.isEmpty, "A new folder must start with its own draft")
        store.prompt = "Draft for the second project"
        store.selectWorkspace(first.path)
        expect(store.prompt == "Draft for the first project", "Switching back must restore the first draft")

        let run = RunRecord(id: "first-run", prompt: "A saved task", workspace: first.path, workflow: .independent,
                            createdAt: "2026-10-10T00:00:00Z", finishedAt: nil, status: .running, stages: [])
        store.runs = [run.summary]
        store.selectedRun = run
        expect(store.workspaceRuns.count == 1 && store.workspaceRun?.id == run.id, "The current folder must show its own task")
        store.selectWorkspace(second.path)
        expect(store.workspaceRuns.isEmpty && store.workspaceRun == nil, "Another folder must not show the previous folder's task")
        expect(store.prompt == "Draft for the second project", "Switching back must restore the second draft")
        store.selectedRun = run
        expect(store.workspaceRun == nil && store.busy, "A delayed foreign run detail must stay out of this folder while preserving running status")
        store.removeWorkspace(second.path)
        expect(store.settings.workspace == first.path && store.prompt == "Draft for the first project", "Removing the active entry must select the remaining folder")
        store.removeWorkspace(first.path)
        expect(store.settings.workspace.isEmpty && store.settings.workspaceFolders.isEmpty, "Removing the last entry must leave an empty workspace")
        expect(store.runs.count == 1 && FileManager.default.fileExists(atPath: first.path), "Removing sidebar entries must preserve history and files")
        let empty = try decoder.decode(Settings.self, from: encoder.encode(store.settings))
        expect(empty.workspace.isEmpty && empty.workspaceFolders.isEmpty, "An empty workspace must roundtrip without reappearing")
        store.reuse(run)
        expect(store.settings.workspaceFolders == [first.path] && store.prompt == run.prompt, "Reusing a saved task must restore its folder and prompt")
        let claudeIndex = store.settings.agents.firstIndex { $0.provider == .claude }!
        store.claudeSessionKey = "fixture-private-claude-key"
        store.settings.agents[claudeIndex].model = "previous-backend-model"
        store.setClaudeBackend(.anthropic)
        expect(store.claudeSessionKey.isEmpty && store.settings.agents[claudeIndex].model.isEmpty,
               "A backend switch must clear the previous provider's credential and model")
        store.claudeSessionKey = "fixture-private-claude-key"
        store.setClaudeBackend(.anthropic)
        expect(!store.claudeSessionKey.isEmpty, "Selecting the active provider must preserve its session key")
        store.setClaudeBackend(.custom)
        store.settings.claudeBaseUrl = "https://gateway.example/anthropic"
        store.settings.claudeConfigDir = area.appendingPathComponent("config").path
        store.claudeSessionKey = "fixture-private-claude-key"
        let saved = try encoder.encode(store.settings)
        let profile = try decoder.decode(Settings.self, from: saved)
        expect(profile.claudeBackend == .custom && profile.claudeConfigDir == store.settings.claudeConfigDir && profile.claudeBaseUrl == store.settings.claudeBaseUrl,
               "The chosen provider and configuration folder must survive a restart")
        expect(!String(decoding: saved, as: UTF8.self).contains("fixture-private-claude-key"), "Session credentials must stay out of preferences")
        store.settings.claudeBaseUrl = "https://another.example/anthropic"
        expect(store.claudeSessionKey.isEmpty, "A changed custom endpoint must not receive the previous endpoint's key")
        store.setClaudeBackend(.deepseek)
        store.claudeSessionKey = "fixture-private-claude-key"
        store.sessionKey = "fixture-private-deepseek-key"
        store.settings.deepseekBaseUrl = "https://another.example"
        expect(store.claudeSessionKey.isEmpty && store.sessionKey.isEmpty, "Changing the DeepSeek endpoint must clear both harnesses' session keys")
        expect(!restored.chatIntroduced, "Existing preferences must allow the one-time Chat migration")
        expect(agentMentions("@Claude @codex @deep_seek @CLAUDE") == [.claude, .codex, .deepseek], "Mention routing must match the engine and deduplicate names")
        expect(agentMentions("email@codex.example `@qoder`\n```\n@claude\n```\n(@antigravity)") == [.antigravity], "Examples and email addresses must not invoke agents")
        let roster = AgentIdentity.suggestedTeam(members: Provider.allCases)
        expect(roster.map(\.name) == ["Maya", "Alex", "Avery", "Quinn", "Sage", "Kai"] && Set(roster.map(\.mention)).count == 6,
               "Every new teammate must get a distinct employee name and handle")
        let colliding = AgentIdentity.suggestedTeam(members: [.claude, .codex], overrides: [AgentIdentity(provider: .claude, name: "Alex", mention: "alex")])
        expect(colliding[1].name == "Maya" && colliding[1].mention == "maya", "Suggested names must choose another employee when a custom name is taken")
        expect(AgentIdentity.suggestedHandle(for: "Éva Chen", provider: .claude) == "eva-chen", "Name edits should suggest a valid handle")
        let nextRoster = AgentIdentity.suggestedTeam(members: Provider.allCases, excluding: roster)
        expect(nextRoster.map(\.name) == ["Noah", "Emma", "Liam", "Olivia", "Ethan", "Isla"]
               && Set(nextRoster.map(\.mention)).isDisjoint(with: roster.map(\.mention)), "Fresh rosters must avoid every previous coworker")
        let namingStore = EngineStore(options: legacyOptions)
        namingStore.loaded = true
        namingStore.connected = true
        namingStore.settings.workflow = .conversation
        namingStore.settings.agents[1].selected = false
        let inactiveCoworker = namingStore.newAgentNames.first { $0.provider == .codex }!
        expect(namingStore.renameAgent(.claude, name: inactiveCoworker.name, mention: inactiveCoworker.mention) == nil,
               "A name from an unselected connection can be used for the selected coworker")
        namingStore.settings.agents[1].selected = true
        expect(Set(namingStore.chatIdentities.map(\.mention)).count == namingStore.chatMembers.count
               && namingStore.identity(.claude).mention == inactiveCoworker.mention && namingStore.identity(.codex).mention != inactiveCoworker.mention,
               "Adding a teammate after a rename must allocate a different coworker instead of colliding with an existing name")
        expect(matchingTeammates("al", identities: roster).map(\.provider) == [.codex]
               && matchingTeammates("cod", identities: roster).map(\.mention) == ["alex"]
               && matchingTeammates("deep_s", identities: roster).map(\.provider) == [.deepseek],
               "Autocomplete must match employee names, custom handles, and engine aliases")
        let incomplete = "🧠 Ask @alex to review"
        let caret = ("🧠 Ask @al" as NSString).length
        let query = mentionQuery(in: incomplete, selection: NSRange(location: caret, length: 0))!
        let inserted = mentionInsertion(roster[1], query: query, in: incomplete)!
        expect(inserted.applying(to: incomplete) == "🧠 Ask @alex to review" && inserted.selection.location == ("🧠 Ask @alex " as NSString).length,
               "Autocomplete must replace the whole token at the caret and preserve emoji and following text")
        let aliasDraft = "Ask @cod, then continue"
        let aliasQuery = mentionQuery(in: aliasDraft, selection: NSRange(location: 8, length: 0))!
        expect(mentionInsertion(roster[1], query: aliasQuery, in: aliasDraft)?.applying(to: aliasDraft) == "Ask @alex, then continue",
               "Autocomplete must insert the task's custom handle without changing punctuation")
        for ignored in ["mail@al", "`@al", "```\n@al", "~~~\n@al", "Ask @al "] {
            expect(mentionQuery(in: ignored, selection: NSRange(location: ignored.utf16.count, length: 0)) == nil,
                   "Emails, code examples, and finished tokens must not open the mention menu")
        }
        expect(mentionQuery(in: "@al", selection: NSRange(location: 1, length: 2)) == nil
               && mentionQuery(in: "```\nexample\n```\n@al", selection: NSRange(location: "```\nexample\n```\n@al".utf16.count, length: 0))?.query == "al",
               "Selection must dismiss completions, and mentions after a closed code block must work")
        let message = ChatMessage(id: "reply", at: "2026-10-10T00:00:00Z", kind: "assistant", author: .claude, to: [], text: "A saved answer", status: .completed,
                                  model: "deepseek-v4-pro", sessionId: "claude-session", logs: [], usage: Usage(inputTokens: 10, outputTokens: 5, costUsd: nil), error: nil)
        var chatRun = RunRecord(id: "chat-task", prompt: "A shared task", workspace: first.path, workflow: .conversation, createdAt: "2026-10-10T00:00:00Z", finishedAt: nil, status: .completed, stages: [])
        chatRun.conversation = TaskConversation(members: [.claude, .codex, .qoder, .deepseek], lead: .claude, messages: [message],
                                                sessions: [AgentSession(provider: .claude, sessionId: "claude-session", scope: "profile")],
                                                names: [AgentIdentity(provider: .claude, name: "Atlas", mention: "atlas"), AgentIdentity(provider: .codex, name: "Nova", mention: "nova")])
        store.runs = [chatRun.summary]
        store.loaded = true
        store.connected = true
        store.agents = Provider.allCases.map { AgentInfo(provider: $0, status: $0 == .claude || $0 == .codex ? "ready" : "missing", label: "Fixture", detail: "Fixture connection") }
        store.screen = "history"
        store.selectRun(chatRun.id)
        store.prompt = "A reply while loading"
        expect(store.screen == "workspace" && store.selectedRunID == chatRun.id && store.workspaceSelectionPending && !store.canRun,
               "Opening a saved chat must go directly to its dialogue and block sending until that conversation loads")
        store.continueChat(chatRun)
        store.prompt = "Talk to the lead first"
        expect(store.chatRun?.id == chatRun.id && store.chatMembers.count == 4 && store.canRun, "An existing four-member task must allow a ready lead even if idle members are unavailable")
        let connectionModels = store.settings.agents.map(\.model)
        store.modelCatalogs = [ModelCatalog(provider: .codex, source: "Fixture catalogue", options: [
            ModelOption(id: "fixture-codex-a", label: "Codex A", effortLevels: [.low, .high, .max, .ultra], defaultEffort: .low),
            ModelOption(id: "no-thinking", label: "No thinking", effortLevels: [])
        ], effortLevels: [.low, .medium, .high, .xhigh])]
        expect(store.setAgentModel(.codex, model: "fixture-codex-a") == nil && store.modelLabel(.codex) == "Codex A", "The chat picker must select and display a model from the CLI catalogue")
        expect(store.chatRun?.conversation?.models == [AgentModel(provider: .codex, model: "fixture-codex-a")] && store.settings.agents.map(\.model) == connectionModels,
               "Chat model selection must be task-scoped and preserve the Connection defaults")
        let connectionEfforts = store.settings.agents.map(\.effort)
        expect(store.effortOptions(.codex) == [.low, .high, .max, .ultra] && store.setAgentEffort(.codex, effort: .ultra) == nil,
               "The effort picker must expose the selected model's advertised levels")
        expect(store.chatEfforts == [AgentEffort(provider: .codex, effort: .ultra)] && store.settings.agents.map(\.effort) == connectionEfforts,
               "Effort must be stored per teammate in this chat without changing Connection defaults")
        expect(store.setAgentEffort(.codex, effort: .medium) != nil && store.setAgentEffort(.claude, effort: .medium) != nil,
               "Unadvertised Codex levels and unsupported DeepSeek levels must be rejected")
        expect(store.setAgentModel(.codex, model: "no-thinking") == nil && store.effortOptions(.codex).isEmpty && !store.effortIsValid(.codex),
               "A model without effort support must require clearing an incompatible saved choice")
        expect(store.setAgentEffort(.codex, effort: .default) == nil && store.effortIsValid(.codex) && store.chatEfforts.isEmpty,
               "Default must remain selectable for models without reasoning controls")
        expect(store.setAgentModel(.codex, model: "fixture-codex-a") == nil && store.setAgentEffort(.claude, effort: .max) == nil,
               "Claude using DeepSeek must offer its actual maximum effort")
        expect(store.effortOptions(.antigravity) == [.low, .medium, .high] && store.setAgentEffort(.kiro, effort: .low) != nil,
               "Effort choices must respect providers and chat membership")
        expect(store.chatRun?.conversation?.sessions.first?.sessionId == "claude-session", "Editing effort must preserve session metadata until the next invocation")
        expect(store.setAgentEffort(.claude, effort: .default) == nil && store.chatEfforts.isEmpty, "Default must clear this chat's effort override")
        expect(store.setAgentModel(.claude, model: "sonnet") != nil && store.setAgentModel(.claude, model: "deepseek-v4-flash[1m]") == nil
               && store.modelOverride(.claude) == "deepseek-flash", "Claude using DeepSeek must offer compatible models and normalize legacy names")
        expect(store.chatRun?.conversation?.sessions.first?.sessionId == "claude-session", "Choosing a model must not delete saved session metadata before a new invocation")
        expect(store.setAgentModel(.codex, model: "--bad") != nil && store.setAgentModel(.kiro, model: "auto") != nil, "Invalid model IDs and agents outside the task must be rejected")
        store.runs = [run.summary]
        expect(!store.canChangeChatModels && store.setAgentModel(.codex, model: "fixture-codex-b") != nil, "Model changes must be blocked while an agent is working")
        expect(store.setAgentEffort(.codex, effort: .high) != nil, "Effort changes must be blocked while an agent is working")
        store.runs = [chatRun.summary]
        expect(store.setAgentModel(.codex, model: "") == nil && store.setAgentModel(.claude, model: "") == nil && store.chatModels.isEmpty,
               "Choosing Default must remove the chat override")
        store.teamDiscussion = true
        expect(!store.canRun && store.discussionUnavailable == [.qoder, .deepseek], "A team discussion must require every participant to be ready before sending")
        store.agents = Provider.allCases.map { AgentInfo(provider: $0, status: "ready", label: "Fixture", detail: "Fixture connection") }
        expect(store.canRun && store.chatTargets == chatRun.conversation?.members && store.discussionHint.contains("5 replies"),
               "A discussion must include the task's whole team and explain its bounded lead-review-lead flow")
        store.chatLead = .codex
        expect(store.discussionHint.contains("Nova answers first"), "The selected agent must lead the discussion")
        store.prompt = "@antigravity inspect"
        expect(!store.canRun, "Discussion mode must still reject an addressed agent outside this task")
        store.teamDiscussion = false
        store.chatLead = .claude
        store.agents = Provider.allCases.map { AgentInfo(provider: $0, status: $0 == .claude || $0 == .codex ? "ready" : "missing", label: "Fixture", detail: "Fixture connection") }
        expect(chatRun.summary.providers.count == 4 && chatRun.summary.totalTokens == 15, "History must preserve chat members and usage")
        expect(chatRun.summary.displayName(.codex) == "Nova" && chatRun.summary.matchesSearch("@NOVA") && chatRun.summary.matchesSearch("Atlas")
               && chatRun.summary.matchesSearch("Codex") && !chatRun.summary.matchesSearch("Unknown colleague"),
               "History must display and search teammate names and handles while keeping engine searches")
        store.prompt = "@qoder review this"
        expect(!store.canRun, "An addressed unavailable agent must require setup")
        store.prompt = "@codex @claude review this"
        expect(store.canRun && store.chatTargets == [.codex, .claude], "Mentions must select only the addressed task members")
        store.prompt = "@NOVA @atlas check the task"
        expect(store.canRun && store.chatTargets == [.codex, .claude] && store.displayName(.claude) == "Atlas", "Named agents must route inside their saved task")
        store.prompt = ""
        store.mention(.codex)
        expect(store.prompt == "@nova ", "Saved team buttons must insert the custom handle")
        expect(store.renameAgent(.claude, name: "Atlas", mention: "nova") != nil, "Another member's handle cannot be stolen")
        expect(store.renameAgent(.claude, name: "Atlas", mention: "kiro") != nil, "Provider handles must stay reserved even outside the team")
        expect(store.renameAgent(.claude, name: "Atlas renamed", mention: "atlas") == nil && store.chatRun?.conversation?.sessions.first?.sessionId == "claude-session", "Renaming must preserve the existing native session")
        let namesBefore = store.chatIdentities
        var editedTeam = namesBefore
        editedTeam[0].name = "Nova"
        editedTeam[0].mention = "nova"
        editedTeam[1].name = "Atlas renamed"
        editedTeam[1].mention = "atlas"
        expect(store.renameTeam(editedTeam) == nil && store.identity(.codex).mention == "atlas" && store.identity(.claude).mention == "nova"
               && store.chatRun?.conversation?.sessions.first?.sessionId == "claude-session" && store.chatRun?.conversation?.messages.first?.text == message.text,
               "Edit Team must save multiple names atomically, allow handle swaps, and preserve the conversation")
        editedTeam[1].mention = "nova"
        expect(store.renameTeam(editedTeam) != nil && store.identity(.codex).mention == "atlas", "A duplicate handle must reject the whole proposed roster")
        expect(store.renameTeam([namesBefore[0]]) != nil && store.renameTeam(namesBefore) == nil, "The roster must contain each task member exactly once")
        store.prompt = "@antigravity review this"
        expect(!store.canRun, "An agent outside the task must not be invoked")
        store.newTask()
        expect(store.chatRun == nil && store.selectedRunID == nil && store.selectedRun == nil && store.prompt.isEmpty && store.settings.workflow == .conversation,
               "New Task must start a fresh Chat instead of continuing the selected conversation")
        expect(!store.teamDiscussion, "A new chat must start with direct messaging")
        for index in store.settings.agents.indices { store.settings.agents[index].selected = [.claude, .codex].contains(store.settings.agents[index].provider) }
        let firstNewRoster = store.chatIdentities
        store.mention(.codex)
        expect(store.prompt == "@\(store.identity(.codex).mention) " && Set(firstNewRoster.map(\.mention)).isDisjoint(with: namesBefore.map(\.mention)),
               "New chats must create different coworkers and route their own mention buttons")
        expect(store.chatIdentities == firstNewRoster && matchingTeammates("", identities: store.chatIdentities) == firstNewRoster,
               "Reading the draft and opening autocomplete must keep the same roster")
        store.settings.agents[1].selected = false
        store.settings.agents[1].selected = true
        expect(store.chatIdentities == firstNewRoster, "Toggling a connection must preserve this draft's coworker")
        var reusableChat = chatRun
        reusableChat.conversation?.models = [AgentModel(provider: .codex, model: "fixture-copied-model")]
        reusableChat.conversation?.efforts = [AgentEffort(provider: .codex, effort: .high)]
        store.reuse(reusableChat)
        expect(store.composingNewTask && store.team.count == 4, "Reusing a conversation must restore its team for a new task")
        expect(store.identity(.claude).name != "Atlas" && Set(store.chatIdentities.map(\.mention)).isDisjoint(with: firstNewRoster.map(\.mention))
               && store.chatModels == reusableChat.conversation?.models && store.chatEfforts == reusableChat.conversation?.efforts,
               "Reusing a task must create fresh coworkers while retaining model and effort choices")
        store.runs = []
        expect(store.renameAgent(.codex, name: "Reviewer", mention: "reviewer") == nil, "A selected draft agent must be editable before its first message")
        expect(store.setAgentModel(.codex, model: "fixture-draft-model") == nil, "Draft models must be selectable before the first message")
        expect(store.setAgentEffort(.codex, effort: .high) == nil, "Draft effort must be selectable before the first message")
        store.selectWorkspace(second.path)
        expect(store.modelOverride(.codex).isEmpty, "Another workspace must have an independent model draft")
        expect(store.effortOverride(.codex) == .default, "Another workspace must have an independent effort draft")
        expect(store.identity(.codex).mention != "reviewer", "A different workspace must have its own coworkers")
        expect(store.renameAgent(.codex, name: "Second reviewer", mention: "second-reviewer") == nil, "A different workspace can name the same provider independently")
        store.selectWorkspace(first.path)
        expect(store.modelOverride(.codex) == "fixture-draft-model", "Switching folders must restore the model draft")
        expect(store.effortOverride(.codex) == .high, "Switching folders must restore the teammate's effort draft")
        expect(store.identity(.codex).mention == "reviewer", "Switching back must restore the workspace's naming draft")
        let previousDraftRoster = store.chatIdentities
        store.newTask()
        expect(store.chatModels.isEmpty, "New chats must start with Connection model defaults")
        expect(store.chatEfforts.isEmpty, "New chats must start with Connection effort defaults")
        expect(Set(store.chatIdentities.map(\.mention)).isDisjoint(with: previousDraftRoster.map(\.mention))
               && Set(store.chatIdentities.map(\.mention)).isDisjoint(with: firstNewRoster.map(\.mention)),
               "A new task must not recycle coworkers from earlier drafts")
        expect(matchingTeammates("reviewer", identities: store.chatIdentities).isEmpty
               && agentMentions("@codex", identities: store.chatIdentities) == [.codex],
               "Autocomplete must show only this chat's coworkers while provider aliases still route locally")

        let stage = Stage(provider: .codex, model: "", status: .completed, sessionId: "old-batch-session", output: "A batch result", logs: [],
                          usage: Usage(inputTokens: 1, outputTokens: 2, costUsd: nil), error: nil)
        let batch = RunRecord(id: "batch-task", prompt: "A previous batch task", workspace: second.path, workflow: .collaborate,
                              createdAt: "2026-10-10T00:00:00Z", finishedAt: nil, status: .completed, stages: [stage])
        store.runs = [batch.summary, chatRun.summary]
        store.selectWorkspace(second.path)
        expect(store.composingNewTask && store.selectedRunID == nil && store.chatRun == nil,
               "A workspace with only old batch results must open a fresh chat composer in Chat mode")
        store.selectRun(batch.id)
        expect(store.screen == "history" && store.selectedRunID == batch.id, "Batch tasks must retain their results view")
        store.startChat(from: batch)
        expect(store.screen == "workspace" && store.settings.workflow == .conversation && store.composingNewTask && store.prompt == batch.prompt
               && store.selectedRunID == nil && store.team.map(\.provider) == [.codex] && store.effectiveLead == .codex,
               "Start Chat must prepare the old task's prompt and agents as a new conversation without submitting it")
        expect(batch.workflow == .collaborate && batch.stages.first?.sessionId == "old-batch-session" && store.runs.count == 2,
               "Starting a chat from a batch must preserve its original result and session")
        store.selectRun(chatRun.id)
        expect(store.settings.workspace == first.path && store.screen == "workspace" && store.selectedRunID == chatRun.id && !store.canRun,
               "Opening a chat from another folder must select its own workspace and wait for its saved conversation")
        store.continueChat(chatRun)
        expect(store.chatRun?.conversation?.messages.first?.text == message.text && store.chatRun?.conversation?.sessions.first?.sessionId == "claude-session",
               "Chat navigation must restore the saved dialogue and exact session")
        expect(store.identity(.claude).name == "Atlas" && store.identity(.codex).name == "Nova", "Reopening a chat must preserve its original coworkers")
        store.screen = "history"
        store.selectRun(chatRun.id, navigate: false)
        expect(store.screen == "history", "Loading a history preview must not unexpectedly navigate away")
        store.kiroSessionKey = "fixture-private-kiro-key"
        let savedKiroSettings = try encoder.encode(store.settings)
        expect(!String(decoding: savedKiroSettings, as: UTF8.self).contains(store.kiroSessionKey), "Kiro API keys must stay out of preferences")
        let question = AgentUserQuestion(id: "q1", header: "Scope", question: "Which approach should I use?", options: [
            AgentQuestionOption(id: "o1", label: "Focused change", description: "Keep the current design"),
            AgentQuestionOption(id: "o2", label: "Full change", description: "Replace the feature")], multiSelect: false)
        let request = AgentQuestionRequest(id: "question-request", questions: [question], answers: nil)
        let questionMessage = ChatMessage(id: "question-message", at: message.at, kind: "assistant", author: .codex, to: [], text: "Before I continue…", status: .waitingForUser,
                                          model: "", sessionId: "codex-session", logs: [], usage: message.usage, error: nil, questionRequest: request)
        var waiting = RunRecord(id: "waiting-task", prompt: "A task with a question", workspace: first.path, workflow: .conversation, createdAt: message.at,
                                finishedAt: message.at, status: .waitingForUser, stages: [])
        waiting.conversation = TaskConversation(members: [.claude, .codex], lead: .claude, messages: [questionMessage], sessions: [])
        store.runs = [waiting.summary]
        store.continueChat(waiting)
        store.prompt = "@claude cannot bypass the question"
        expect(store.hasPendingQuestions && !store.busy && !store.canRun && store.canAnswerQuestion(runID: waiting.id, message: questionMessage),
               "Pending questions must pause ordinary chat, remain idle, and allow the asking agent's answer card")
        expect(store.answerQuestion(runID: waiting.id, message: questionMessage, answers: []) != nil && store.pendingQuestionReplies.isEmpty,
               "Incomplete answers must stay local and leave the question retryable")
        let draft = AgentQuestionDraft(selected: ["o2"], text: "Keep @claude as answer text")
        expect(store.answerQuestion(runID: waiting.id, message: questionMessage, answers: [draft.answer(question)]) == nil && store.pendingQuestionReplies == [request.id],
               "Submitting answers must send a structured reply and prevent duplicate submissions until acknowledged")
        expect(!store.canAnswerQuestion(runID: waiting.id, message: questionMessage) && !store.canChangeChatModels,
               "A pending answer must block another submission and conflicting model edits")
        expect(RunStatus.waitingForUser.label == "Waiting for you" && request.plainText.contains("Focused change"), "Question state and copy text must be readable")
        print("Swift store smoke passed: fresh coworkers per chat, stable draft rosters, rename/add-teammate collisions, scoped autocomplete, reuse model/effort choices, structured questions, saved sessions, workspace drafts and credentials")
    }

    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
