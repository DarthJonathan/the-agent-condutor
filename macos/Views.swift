import AppKit
import SwiftUI

private struct Panel<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: () -> Content
    init(padding: CGFloat = 22, @ViewBuilder content: @escaping () -> Content) { self.padding = padding; self.content = content }
    var body: some View {
        content().padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

struct RootView: View {
    @EnvironmentObject private var store: EngineStore
    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 190, ideal: 212, max: 250)
        } detail: {
            Group {
                if store.screen == "connections" { ConnectionsView() }
                else if store.screen == "remote" { RemoteAccessView() }
                else if store.screen == "history" { HistoryView() }
                else if store.screen == "attention" { AttentionInboxView() }
                else { WorkspaceView() }
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let notice = store.notice {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: store.noticeIsError ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(store.noticeIsError ? .orange : .mint)
                        Text(notice).font(.system(size: 12)).textSelection(.enabled)
                        Spacer(minLength: 12)
                        if !store.persistenceBlocked { Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    }.padding(14).background(Theme.panel).overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1050, minHeight: 700)
        .alert(store.chatToDelete?.workflow == .conversation ? "Delete this chat?" : "Delete this task?",
               isPresented: Binding(get: { store.chatToDelete != nil }, set: { if !$0 { store.chatToDelete = nil } }),
               presenting: store.chatToDelete) { run in
            Button("Cancel", role: .cancel) { store.chatToDelete = nil }
            Button("Delete", role: .destructive) { store.deleteRun(run) }
        } message: { run in
            Text("“\(run.title)” and its saved messages, mailbox and inbox items will be permanently removed from Conductor. Workspace files and agent CLI sessions will be kept.")
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var store: EngineStore
    var scrollable = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "waveform").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
                Text("Conductor").font(.system(size: 16, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 23).padding(.bottom, 24)
            Button(action: store.newTask) {
                HStack { Image(systemName: "square.and.pencil"); Text("New chat"); Spacer(); Text("⌘N").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 9)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 14)
            Group {
                if scrollable { ScrollView { navigationContent } }
                else { navigationContent }
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 7) {
                Divider().padding(.bottom, 7)
                HStack(spacing: 7) {
                    Circle().fill(Color.mint.opacity(0.7)).frame(width: 5, height: 5)
                    Text("Local workspace").font(.system(size: 12))
                }
                Text("\(store.settings.workspaceFolders.count) \(store.settings.workspaceFolders.count == 1 ? "folder" : "folders") · \(store.workspaceRuns.count) \(store.workspaceRuns.count == 1 ? "task" : "tasks")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }.background(Color.black.opacity(0.18))
    }
    private var navigationContent: some View {
        VStack(alignment: .leading, spacing: 4) {
                ForEach([("workspace", "Chat", "bubble.left.and.bubble.right"), ("attention", "Inbox", "tray"), ("history", "Run history", "clock"), ("connections", "Connections", "point.3.connected.trianglepath.dotted"), ("remote", "Remote", "network")], id: \.0) { screen, label, icon in
                    Button { store.screen = screen } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon).frame(width: 18)
                            Text(label)
                            Spacer()
                            if screen == "attention", store.attentionCount > 0 { Text("\(store.attentionCount)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent.opacity(0.2), in: Capsule()) }
                        }.font(.system(size: 13)).foregroundStyle(store.screen == screen ? Color.primary : .secondary)
                            .padding(.horizontal, 10).padding(.vertical, 10)
                            .background(store.screen == screen ? Color.white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text("Workspaces").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.top, 25).padding(.bottom, 8).padding(.leading, 10)
                ForEach(store.settings.workspaceFolders, id: \.self) { path in
                    WorkspaceFolderRow(path: path)
                }
                Button(action: store.addFolders) {
                    Label("Add folders…", systemImage: "plus").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!store.loaded).help("Add project folders (⌘O)")
            }.padding(.horizontal, 12)
    }
}

private struct WorkspaceFolderRow: View {
    @EnvironmentObject private var store: EngineStore
    let path: String
    private var selected: Bool { store.settings.workspace == path }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { store.selectWorkspace(path) } label: {
                HStack(spacing: 9) {
                    Image(systemName: selected ? "folder.fill" : "folder").foregroundStyle(selected ? Theme.accent : .secondary).frame(width: 18)
                    Text(store.settings.folderLabel(path)).font(.system(size: 12, weight: selected ? .medium : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.foregroundStyle(selected ? Color.primary : .secondary).padding(.horizontal, 10).padding(.vertical, 9)
                    .background(selected ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(path).accessibilityLabel("Open workspace \(path)")
                .contextMenu {
                    Button("New chat here") { store.selectWorkspace(path); store.newTask() }
                    Divider()
                    Button("Remove from sidebar") { store.removeWorkspace(path) }
                }
            if selected {
                ForEach(store.workspaceRuns.prefix(3)) { run in
                    Button { store.selectRun(run.id) } label: {
                        HStack(spacing: 7) {
                            Circle().fill(run.status.color).frame(width: 4, height: 4)
                            Text(run.title).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }.padding(.leading, 37).padding(.trailing, 10).padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(run.title)
                        .contextMenu {
                            Button("Open chat") { store.selectRun(run.id) }
                            Divider()
                            Button("Delete chat…", role: .destructive) { store.requestDeleteRun(run) }
                                .disabled(!store.canDeleteRun(run))
                        }
                }
            }
        }
    }
}

struct WorkspacePicker: View {
    @ObservedObject var store: EngineStore
    var body: some View {
        Menu {
            ForEach(store.settings.workspaceFolders, id: \.self) { path in
                Button { store.selectWorkspace(path) } label: {
                    Label(store.settings.folderLabel(path), systemImage: store.settings.workspace == path ? "checkmark" : "folder")
                }.help(path)
            }
            if !store.settings.workspaceFolders.isEmpty { Divider() }
            Button("Add folders…", systemImage: "plus", action: store.addFolders)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(store.settings.workspaceName).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }.font(.system(size: 12)).foregroundStyle(.secondary)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
            .disabled(!store.loaded).help(store.settings.workspace.isEmpty ? "Add a workspace folder" : store.settings.workspace)
            .accessibilityLabel("Choose workspace folder")
    }
}

private struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 28, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

private struct WorkspaceView: View {
    @EnvironmentObject private var store: EngineStore
    var body: some View {
        GeometryReader { geometry in
            if store.chatting { WorkspaceChatView(run: store.chatRun, availableWidth: geometry.size.width, teamWidth: geometry.size.width < 930 ? 242 : 270) }
            else { ScrollView { WorkspaceContent(teamWidth: geometry.size.width < 930 ? 242 : 270) } }
        }
    }
}

private struct WorkspaceContent: View {
    @EnvironmentObject private var store: EngineStore
    let teamWidth: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                PageHeading(title: store.settings.workspace.isEmpty ? "Workspace" : store.settings.workspaceName,
                            subtitle: store.settings.workspace.isEmpty ? "Add a folder to start working with your agents." : "A place to think, build, and work with your agents.")
                Spacer()
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 27) {
                    TaskComposer()
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("Activity").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button("View all") { store.screen = "history" }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if let run = store.workspaceRun {
                            if run.conversation != nil { ChatHistoryView(run: run) } else { RunDetailView(run: run) }
                        }
                        else if store.workspaceSelectionPending { Panel { ProgressView().frame(maxWidth: .infinity).padding(30) } }
                        else { EmptyActivity() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                TeamPanel().frame(width: teamWidth)
            }
        }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TaskComposer: View {
    @EnvironmentObject private var store: EngineStore
    @State private var focused = false
    private let suggestions = [
        ("Review code", "Review this workspace. Identify the most important bugs and risks, with file references and suggested fixes."),
        ("Plan a change", "Inspect this workspace and propose a concrete implementation plan for the following change: "),
        ("Find a bug", "Inspect this workspace for a reproducible bug. Explain its trigger and propose a focused fix.")
    ]
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(store.composerExpanded ? "New task" : "Current task").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if !store.composerExpanded {
                        Button("Edit task") { store.composerExpanded = true; focused = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if store.composerExpanded {
                    ZStack(alignment: .topLeading) {
                        if store.prompt.isEmpty {
                            Text(store.chatting ? "Message \(store.displayName(store.effectiveLead)), or @mention a teammate…" : "Describe the task you want your agents to tackle…").font(.system(size: 16)).foregroundStyle(.tertiary)
                                .padding(.top, 6).padding(.leading, 5).allowsHitTesting(false)
                        }
                        MentionComposer(text: $store.prompt, focused: $focused, identities: store.chatting ? store.chatIdentities : [],
                                        enabled: true, fontSize: 16, height: 155, accessibilityLabel: "Task")
                    }
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.0) { item in
                            Button(item.0) { store.prompt = item.1; focused = true }.font(.system(size: 11)).controlSize(.small)
                        }
                    }
                } else { Text(store.prompt).font(.system(size: 14)).lineLimit(3).textSelection(.enabled) }
                Divider()
                HStack(spacing: 12) {
                    if store.chatting { ChatRecipientPicker() }
                    else { WorkspacePicker(store: store).frame(maxWidth: 240, alignment: .leading) }
                    Spacer(minLength: 0)
                    Text("⌘ ↵").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Button(action: store.startRun) {
                        HStack(spacing: 8) { Text(store.demo ? "Demo mode" : store.busy ? "Working…" : store.chatting ? "Start conversation" : "Run agents"); Image(systemName: "arrow.up.right") }
                            .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.canRun)
                }
                if store.chatting { MentionSuggestions() }
            }
        }
        .onAppear { focused = true }
        .onChange(of: store.composerExpanded) { _, expanded in if expanded { focused = true } }
    }
}

private struct ChatRecipientPicker: View {
    @EnvironmentObject private var store: EngineStore
    var body: some View {
        if store.usesCoworkerTeams {
            Picker(store.teamDiscussion ? "Led by" : "Talk to", selection: Binding(get: { store.effectiveCoworker?.id ?? "" }, set: { store.coworkerLead = $0 })) {
                ForEach(store.coworkers) { worker in Text(worker.name).tag(worker.id) }
            }.frame(maxWidth: 210).font(.system(size: 12))
        } else {
        Picker(store.teamDiscussion ? "Led by" : "Talk to", selection: Binding(get: { store.effectiveLead }, set: { store.chatLead = $0 })) {
            ForEach(store.chatMembers) { provider in Text(store.displayName(provider)).tag(provider) }
        }.frame(maxWidth: 210).font(.system(size: 12))
        }
    }
}

private struct MentionSuggestions: View {
    @EnvironmentObject private var store: EngineStore
    private var identities: [AgentIdentity] { store.chatIdentities }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { chips }.fixedSize(horizontal: true, vertical: false)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 7)], alignment: .leading, spacing: 7) { chips }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var chips: some View {
        ForEach(identities) { identity in
            Button {
                if store.usesCoworkerTeams, let worker = store.coworkers.first(where: { $0.id == identity.id }) { store.mentionCoworker(worker) }
                else { store.mention(identity.provider) }
            } label: {
                Text("@\(identity.mention)").font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
            }
            .controlSize(.small).help("Address \(identity.name) (\(identity.provider.name)) in this task")
        }
    }
}

struct ChatComposerFooter: View {
    @EnvironmentObject private var store: EngineStore
    var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    recipient.fixedSize(horizontal: true, vertical: false)
                    model.frame(width: 195)
                    Spacer(minLength: 12)
                    send.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        recipient
                        model.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack { Spacer(minLength: 0); send }
                }
            }
            Toggle("Team discussion", isOn: $store.teamDiscussion).toggleStyle(.checkbox).font(.system(size: 12))
                .disabled(store.busy || loading || (store.chatIdentities.count < 2 && !store.teamDiscussion))
                .help("The lead asks every teammate for feedback, then responds in the same chat.")
            if store.teamDiscussion {
                Text(store.usesCoworkerTeams ? "The lead answers, each teammate reviews, then the lead synthesizes their feedback." : store.discussionHint)
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else { MentionSuggestions() }
            if store.usesCoworkerTeams, let warning = coworkerMentions(store.prompt, coworkers: store.coworkers).ambiguous {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var recipient: some View {
        ChatRecipientPicker().frame(maxWidth: 160).disabled((store.busy && !store.canQueueMessage) || loading)
    }
    @ViewBuilder private var model: some View {
        if store.usesCoworkerTeams, let worker = store.effectiveCoworker { CoworkerModelMenu(worker: worker) }
        else { AgentModelPicker(provider: store.effectiveLead) }
    }
    private var send: some View {
        HStack(spacing: 8) {
            Text("⌘ ↵").font(.system(size: 11)).foregroundStyle(.tertiary)
            Button(action: store.startRun) { Label(store.busy ? (store.canQueueMessage ? "Queue" : "Working…") : store.teamDiscussion ? "Discuss" : "Send", systemImage: store.teamDiscussion ? "bubble.left.and.bubble.right" : "arrow.up") }
                .buttonStyle(.borderedProminent).disabled(!store.canRun)
        }
    }
}

private struct WorkspaceChatView: View {
    @EnvironmentObject private var store: EngineStore
    @State private var messageFocused = false
    let run: RunRecord?
    let availableWidth: CGFloat
    let teamWidth: CGFloat
    var preview = false
    private var inspectorWidth: CGFloat { store.usesCoworkerTeams && store.inspectorTab == "changes" ? max(teamWidth, 360) : teamWidth }
    private var loading: Bool { store.workspaceSelectionPending }
    private var title: String { run?.summary.title ?? (loading ? store.workspaceRuns.first { $0.id == store.selectedRunID }?.title : nil) ?? "New conversation" }
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 22, weight: .semibold)).lineLimit(2)
                        Text(store.settings.workspace.isEmpty ? "Add a workspace folder to get started." : "\(store.settings.workspaceName) · Chat")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let run {
                        if store.usesCoworkerTeams {
                            Button { store.inspectorTab = store.inspectorTab == "changes" ? "team" : "changes"; if store.inspectorTab == "changes" { store.refreshChanges() } } label: { Label("Changes", systemImage: "arrow.triangle.branch") }.font(.system(size: 11))
                        }
                        if run.status == .waitingForUser { Label("Waiting for you", systemImage: "questionmark.bubble").font(.system(size: 11)).foregroundStyle(.orange) }
                        if run.status.active {
                            Button("Stop") { store.cancel(run.id) }.tint(.red).disabled(store.cancelling.contains(run.id))
                        } else {
                            Button { store.export(run.id) } label: { Image(systemName: "square.and.arrow.up") }.help("Export conversation")
                            DeleteRunButton(run: run.summary)
                        }
                    }
                }
                Divider()
                if let run {
                    if preview { ConversationMessages(run: run).frame(maxHeight: .infinity, alignment: .top) }
                    else { ConversationTranscript(run: run).id(run.id).frame(maxWidth: .infinity, maxHeight: .infinity) }
                } else {
                    VStack(spacing: 14) {
                        if loading { ProgressView("Opening conversation…") }
                        else {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
                            Text("Start a conversation").font(.system(size: 20, weight: .medium))
                            Text(store.chatIdentities.isEmpty ? "Build your team, then send a message." : "Talk to \(store.leadName) first. @mention teammates whenever you want to bring them in.")
                                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                            HStack(spacing: 8) {
                                Button("Explain this project") { store.prompt = "Explain what this project does and how it is organized."; messageFocused = true }
                                Button("Review code") { store.prompt = "Review this workspace for the most important bugs and risks, with file references."; messageFocused = true }
                                Button("Plan a change") { store.prompt = "Help me plan a change to this project: "; messageFocused = true }
                            }.font(.system(size: 11)).controlSize(.small).padding(.top, 6)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Panel(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.hasPendingQuestions {
                            Label(store.chatRun?.conversation?.pendingApprovals.isEmpty == false ? "Review the command approval above to continue this chat." : store.questionsAssignedToTeammates ? "Your teammate is answering the pending questions." : "Answer or skip the questions above to continue this chat.", systemImage: "questionmark.bubble")
                                .font(.system(size: 12)).foregroundStyle(.orange)
                        }
                        ZStack(alignment: .topLeading) {
                            if store.prompt.isEmpty {
                                Text(store.teamDiscussion ? "What should your team discuss?" : "Message \(store.leadName), or @mention a teammate…").font(.system(size: 15)).foregroundStyle(.tertiary).padding(.top, 6).padding(.leading, 5).allowsHitTesting(false)
                            }
                            MentionComposer(text: $store.prompt, focused: $messageFocused, identities: store.chatIdentities,
                                            enabled: !loading && !store.hasPendingQuestions, fontSize: 15, height: 90, accessibilityLabel: "Conversation message")
                        }
                        ChatComposerFooter(loading: loading)
                    }
                }
            // A concrete column width prevents the stack from repeatedly asking
            // the entire Markdown transcript and native controls for ideal sizes.
            }.frame(width: max(0, availableWidth - inspectorWidth - 88)).frame(maxHeight: .infinity, alignment: .top)
            Group {
                if store.usesCoworkerTeams {
                    VStack(spacing: 14) {
                        if preview { HStack { ForEach(["team", "mailbox", "changes"], id: \.self) { tab in Text(tab.capitalized).font(.system(size: 12)).foregroundStyle(store.inspectorTab == tab ? .primary : .secondary).padding(7).frame(maxWidth: .infinity).background(store.inspectorTab == tab ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6)) } } }
                        else { Picker("Inspector", selection: $store.inspectorTab) { Text("Team").tag("team"); Text("Mailbox").tag("mailbox"); Text("Changes").tag("changes") }.pickerStyle(.segmented) }
                        if store.inspectorTab == "changes" { ChangesInspectorView(scrollable: !preview).id(store.chatRun?.id) }
                        else if store.inspectorTab == "mailbox" { MailboxInspectorView(scrollable: !preview) }
                        else if preview { CoworkerTeamPanel() }
                        else { ScrollView { CoworkerTeamPanel() } }
                    }
                } else { ScrollView { TeamPanel() } }
            }.frame(width: inspectorWidth).disabled(loading)
        }.padding(32)
            .onAppear { messageFocused = !loading }
            .onChange(of: loading) { _, pending in if !pending { messageFocused = true } }
    }
}

private struct ConversationTranscript: View {
    @EnvironmentObject private var store: EngineStore
    @State private var following: Task<Void, Never>?
    @State private var followState = TranscriptFollowState()
    let run: RunRecord
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ConversationMessages(run: run)
                    .background(TranscriptScrollObserver { event in
                        following?.cancel(); following = nil
                        switch event {
                        case .began: followState.begin()
                        case .moved(let nearBottom): followState.moved(nearBottom: nearBottom)
                        case .ended(let nearBottom): followState.end(nearBottom: nearBottom)
                        }
                        store.setTranscriptReadingHistory(!followState.canFollow)
                        if followState.canFollow {
                            if store.focusedMessageID != nil { store.focusedMessageID = nil }
                            followBottom(proxy)
                        }
                    }.frame(width: 0, height: 0))
            }
            .overlay(alignment: .bottomTrailing) {
                if !followState.following {
                    Button {
                        store.focusedMessageID = nil
                        followState.jumpToLatest()
                        store.setTranscriptReadingHistory(false)
                        followBottom(proxy)
                    } label: { Label("Latest", systemImage: "arrow.down.circle") }
                        .buttonStyle(.bordered).padding(12)
                }
            }
            .onAppear {
                if let id = store.focusedMessageID {
                    followState.end(nearBottom: false)
                    store.setTranscriptReadingHistory(true)
                    proxy.scrollTo(id, anchor: .top)
                }
                else { store.setTranscriptReadingHistory(false); followBottom(proxy) }
            }
            .onChange(of: store.focusedMessageID) { _, id in
                if let id {
                    following?.cancel(); following = nil; followState.end(nearBottom: false)
                    store.setTranscriptReadingHistory(true)
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            .onChange(of: run.conversation?.messages.count) { _, _ in followBottom(proxy) }
            .onChange(of: run.conversation?.messages.last?.text.count) { _, _ in if run.status.active { followBottom(proxy) } }
            .onChange(of: run.conversation?.messages.last?.reasoning?.count) { _, _ in if run.status.active { followBottom(proxy) } }
            .onChange(of: run.status) { _, _ in followBottom(proxy) }
            .onDisappear { following?.cancel(); following = nil; store.setTranscriptReadingHistory(false) }
        }
    }
    // Coalesce requests until layout settles. A user scroll takes priority and
    // streaming resumes following only after the reader returns to the bottom.
    private func followBottom(_ proxy: ScrollViewProxy) {
        guard following == nil, followState.canFollow, store.focusedMessageID == nil else { return }
        following = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            if followState.canFollow && store.focusedMessageID == nil { proxy.scrollTo("chat-end", anchor: .bottom) }
            following = nil
        }
    }
}

private struct ConversationMessages: View {
    @EnvironmentObject private var store: EngineStore
    let run: RunRecord
    var body: some View {
        // Keep measured card heights stable while the viewport moves. Native
        // text views handle long answers without hundreds of SwiftUI nodes.
        VStack(alignment: .leading, spacing: 16) {
            ForEach(run.conversation?.messages ?? []) { message in
                ChatMessageView(runID: run.id,
                                presentation: ChatMessagePresentation(message: message, conversation: run.conversation,
                                                                      blocks: store.renderedChat[message.id] ?? []), store: store)
                    .equatable().id(message.id)
            }
            Color.clear.frame(height: 1).id("chat-end")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// A completed card depends only on its own contents and names, not the growing
// conversation or the store's streaming publications. Controls inside question
// and approval cards observe the store separately to remain responsive.
struct ChatMessagePresentation: Equatable {
    let message: ChatMessage
    let blocks: [ResponseBlock]
    let authorName: String
    let providerLabel: String?
    let recipients: [String]
    init(message: ChatMessage, conversation: TaskConversation?, blocks: [ResponseBlock]) {
        self.message = message; self.blocks = blocks
        let name = conversation?.coworker(message.authorId)?.name ?? message.author.map { conversation?.identity($0).name ?? $0.name } ?? message.authorLabel
        authorName = name
        providerLabel = message.author.flatMap { name != $0.name ? $0.name : nil }
        if let ids = message.recipientIds, !ids.isEmpty { recipients = ids.map { conversation?.coworker($0)?.name ?? "Coworker" } }
        else { recipients = message.to.map { conversation?.identity($0).name ?? $0.name } }
    }
}

private struct ChatMessageView: View, Equatable {
    let runID: String
    let presentation: ChatMessagePresentation
    let store: EngineStore
    @State private var expanded = false
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.runID == rhs.runID && lhs.store === rhs.store && lhs.presentation == rhs.presentation }
    private var message: ChatMessage { presentation.message }
    private var authorName: String { presentation.authorName }
    private var recipients: [String] { presentation.recipients }
    private var activity: [LogEntry] { visibleActivityLogs(message.logs) }
    private var answer: some View {
        NativeResponseText(blocks: presentation.blocks).frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if let provider = message.author { ProviderMark(provider: provider) }
                else { Image(systemName: message.kind == "system" ? "info.circle" : "person.crop.circle").foregroundStyle(.secondary) }
                Text(authorName).font(.system(size: 12, weight: .semibold))
                if let provider = presentation.providerLabel { Text(provider).font(.system(size: 10)).foregroundStyle(.tertiary) }
                if !recipients.isEmpty { Text("→ \(recipients.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                if message.status.active { ProgressView().controlSize(.small) }
                if message.author != nil && !message.model.isEmpty { Text(message.model).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
                if message.author != nil, let effort = message.effort, effort != .default {
                    Text("\(effort.label) effort").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Button { store.copy([message.text, message.questionRequest?.plainText ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).disabled(message.text.isEmpty && message.questionRequest == nil).help("Copy message")
            }
            if message.teamDiscussion == true {
                Label("Team discussion", systemImage: "bubble.left.and.bubble.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
            } else if message.kind == "answer" {
                Label(message.authorId == nil ? "Your answers" : "Teammate answers", systemImage: "checkmark.bubble").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
            } else if message.kind == "question_delegation" {
                Label("Question delegated", systemImage: "person.2").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
            } else if message.kind == "request" {
                Label("Teammate request", systemImage: "arrow.turn.down.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
            } else if message.kind == "assistant" && !recipients.isEmpty {
                Text("Teammate reply").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ReasoningSection(text: reasoning, provider: message.author,
                                 working: message.status == .running && message.text.isEmpty)
            }
            if let error = message.error { NativeResponseText(text: error, tone: .error) }
            if message.error != message.text {
                if message.text.isEmpty && message.questionRequest == nil {
                    if message.reasoning?.isEmpty != false || message.status != .running {
                        Text(message.status == .queued ? "Waiting for this agent…" : message.status == .running ? "Thinking…" : "No response text.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                else { answer }
            }
            if let request = message.questionRequest {
                AgentQuestionCard(runID: runID, message: message, request: request,
                                  agentName: authorName)
            }
            if let request = message.approvalRequest { AgentApprovalCard(runID: runID, message: message, request: request, agentName: authorName) }
            if !activity.isEmpty {
                DisclosureGroup("Activity", isExpanded: $expanded) {
                    NativeResponseText(text: activity.map(\.text).joined(separator: "\n\n"), size: 11, tone: .secondary).padding(.top, 8)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.kind == "user" ? Theme.accent.opacity(0.065) : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

struct ReasoningSection: View {
    let text: String
    let provider: Provider?
    let working: Bool
    @State private var expanded = false
    private var title: String { provider == .codex ? "Reasoning summary" : "Thinking" }
    private var preview: String { String(text.suffix(480)).split(whereSeparator: \.isNewline).last.map(String.init) ?? "" }
    private var content: some View {
        NativeResponseText(text: text, tone: .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView { content }.frame(height: 180).padding(.top, 8)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain")
                    Text(title).fontWeight(.medium)
                    Spacer(minLength: 8)
                    if working { ProgressView().controlSize(.mini) }
                }
            }.font(.system(size: 11))
            if !expanded { Text(preview).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
        }.foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct AgentQuestionCard: View {
    @EnvironmentObject private var store: EngineStore
    let runID: String
    let message: ChatMessage
    let request: AgentQuestionRequest
    let agentName: String
    @State private var drafts: [String: AgentQuestionDraft] = [:]
    @State private var error: String?
    private var pending: Bool { store.pendingQuestionReplies.contains(request.id) }
    private var canAnswer: Bool { store.canAnswerQuestion(runID: runID, message: message) }
    private var assignment: MailboxDelivery? { store.questionDelegate(runID: runID, message: message) }
    private var teammates: [Coworker] { store.questionTeammates(runID: runID, message: message) }
    private var teammateName: String { store.selectedRun?.conversation?.coworker(assignment?.to)?.name ?? "Teammate" }
    private var heading: String {
        if request.answers != nil {
            return request.answeredBy.flatMap { store.selectedRun?.conversation?.coworker($0)?.name }.map { "Answered by \($0)" } ?? "Questions answered"
        }
        return assignment == nil ? "\(agentName) needs your input" : "\(teammateName) is answering \(agentName)'s questions"
    }
    private var complete: Bool {
        request.questions.allSatisfy { drafts[$0.id]?.complete == true }
            && drafts.values.reduce(0) { $0 + $1.text.utf8.count } <= 16 * 1024
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: request.answers == nil ? "questionmark.bubble" : "checkmark.bubble")
                Text(heading)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if request.answers == nil { Text("\(request.questions.count) question\(request.questions.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.foregroundStyle(request.answers == nil ? Color.orange : Theme.accent)
            if request.answers == nil && assignment == nil {
                Menu {
                    ForEach(teammates) { worker in
                        Button("\(worker.name) · \(worker.provider.name)") { error = store.delegateQuestion(runID: runID, message: message, coworkerID: worker.id) }
                    }
                } label: { Label("Ask a teammate", systemImage: "person.2") }
                    .disabled(teammates.isEmpty).fixedSize()
                    .help("Choose another coworker to answer these questions in their own session")
            }
            ForEach(request.questions) { question in
                if let answer = request.answers?.first(where: { $0.questionId == question.id }) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(question.question).font(.system(size: 13, weight: .medium))
                        if answer.skipped { Text("Skipped").font(.system(size: 12)).foregroundStyle(.secondary) }
                        else {
                            ForEach(question.options.filter { answer.optionIds.contains($0.id) }) { option in
                                Label(option.label, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                            }
                            if !answer.text.isEmpty { NativeResponseText(text: answer.text, size: 13) }
                        }
                    }
                } else {
                    AgentQuestionRow(question: question, draft: Binding(get: { drafts[question.id] ?? AgentQuestionDraft() }, set: { drafts[question.id] = $0 }))
                        .disabled(!canAnswer)
                }
            }
            if request.answers == nil {
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                if let assignment {
                    HStack(spacing: 10) {
                        if assignment.state == "delivered" || assignment.state == "queued" { ProgressView().controlSize(.small) }
                        Text(assignment.state == "waiting_for_user" ? "\(teammateName) needs input before answering. Open their question or approval below." : assignment.state == "paused" ? "\(teammateName)'s answer is queued for continuation." : "Waiting for \(teammateName). Their answers will resume \(agentName)'s session.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if assignment.state == "paused" { Button("Continue") { store.continueMailbox() }.disabled(store.busy || store.demo) }
                        if assignment.cancellable { Button("Cancel request") { store.cancelDelivery(assignment) }.disabled(store.demo) }
                    }
                } else {
                    HStack(spacing: 12) {
                        Button("Skip questions") { submit(skipAll: true) }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!canAnswer)
                        Spacer()
                        if pending { ProgressView().controlSize(.small) }
                        Button(pending ? "Sending…" : "Send answers to \(agentName)") { submit(skipAll: false) }
                            .buttonStyle(.borderedProminent).disabled(!canAnswer || !complete)
                    }
                    Text("Answer yourself, or ask a teammate. Valid answers resume \(agentName)'s session and the paused exchange.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(request.answers == nil ? Color.orange.opacity(0.35) : Theme.border))
    }

    private func submit(skipAll: Bool) {
        let answers = request.questions.map { question in
            (skipAll ? AgentQuestionDraft(skipped: true) : drafts[question.id] ?? AgentQuestionDraft()).answer(question)
        }
        error = store.answerQuestion(runID: runID, message: message, answers: answers)
    }
}

private struct AgentQuestionRow: View {
    let question: AgentUserQuestion
    @Binding var draft: AgentQuestionDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !question.header.isEmpty { Text(question.header.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary) }
            HStack(alignment: .firstTextBaseline) {
                Text(question.question).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Toggle("Skip", isOn: $draft.skipped).toggleStyle(.checkbox).font(.system(size: 11)).help("Skip this question and let the agent use its judgment")
            }
            if !draft.skipped {
                if question.multiSelect && !question.options.isEmpty { Text("Select any that apply").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(question.options) { option in
                    let selected = draft.selected.contains(option.id)
                    let icon = question.multiSelect ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle")
                    Button {
                        if draft.selected.contains(option.id) { draft.selected.remove(option.id) }
                        else if question.multiSelect { draft.selected.insert(option.id) }
                        else { draft.selected = [option.id] }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon)
                                .foregroundStyle(selected ? Theme.accent : Color.secondary).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.label).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                                if !option.description.isEmpty { Text(option.description).font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected ? Theme.accent.opacity(0.10) : Theme.background, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.accent.opacity(0.6) : Theme.border))
                    }.buttonStyle(.plain).accessibilityLabel(option.label).accessibilityValue(selected ? "Selected" : "Not selected")
                }
                TextField(question.options.isEmpty ? "Your answer…" : "Custom answer or additional details…", text: $draft.text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...5).padding(12)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    .accessibilityLabel("Your answer to \(question.question)")
            }
        }
    }
}

private struct ChatHistoryView: View {
    @EnvironmentObject private var store: EngineStore
    let run: RunRecord
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(run.summary.title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Open chat") { store.continueChat(run) }.buttonStyle(.borderedProminent)
                }
                ConversationTranscript(run: run).frame(minHeight: 220, maxHeight: 440)
            }
        }
    }
}

private struct ProviderMark: View {
    let provider: Provider
    var body: some View {
        Image(systemName: provider.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(provider.tint)
            .frame(width: 31, height: 31).background(provider.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TeammateAvatar: View {
    let identity: AgentIdentity
    private var initials: String {
        let value = identity.name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }
    var body: some View {
        Text(initials).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(identity.provider.tint)
            .frame(width: 31, height: 31).background(identity.provider.tint.opacity(0.13), in: Circle()).accessibilityHidden(true)
    }
}

private struct TeamPanel: View {
    @EnvironmentObject private var store: EngineStore
    @State private var naming: Provider?
    @State private var editingTeam = false
    @State private var choosingAgents = false
    private var memberIndices: [Int] { store.settings.agents.indices.filter { store.chatMembers.contains(store.settings.agents[$0].provider) } }
    private var availableIndices: [Int] { store.settings.agents.indices.filter { !store.chatMembers.contains(store.settings.agents[$0].provider) } }
    var body: some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Your team").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("\(store.chatMembers.count) \(store.chatting ? "teammates" : "selected")").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if store.chatting {
                    Text(store.chatRun == nil ? "New coworkers for this chat." : "These coworkers belong to this chat.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button { editingTeam = true } label: {
                        Label("Edit team", systemImage: "person.2").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                    }.buttonStyle(.plain).disabled(!store.canEditTeam).help("Edit this chat's teammate names and @handles")
                    VStack(spacing: 3) {
                        ForEach(memberIndices, id: \.self) { index in
                            AgentTeamRow(config: $store.settings.agents[index]) { naming = store.settings.agents[index].provider }
                        }
                    }
                    if store.chatRun == nil && !availableIndices.isEmpty {
                        DisclosureGroup("Add teammates", isExpanded: Binding(get: { store.chatMembers.isEmpty || choosingAgents }, set: { choosingAgents = $0 })) {
                            VStack(spacing: 3) {
                                ForEach(availableIndices, id: \.self) { index in
                                    AgentTeamRow(config: $store.settings.agents[index]) { naming = store.settings.agents[index].provider }
                                }
                            }.padding(.top, 7)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 3) {
                        ForEach($store.settings.agents) { $config in
                            AgentTeamRow(config: $config) { naming = config.provider }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Workflow").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Picker("Workflow", selection: Binding(get: { store.chatRun != nil ? .conversation : store.settings.workflow }, set: { store.settings.workflow = $0 })) {
                        ForEach(Workflow.allCases, id: \.self) { Text($0.name).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().disabled(store.chatRun != nil)
                    Text((store.chatRun != nil ? Workflow.conversation : store.settings.workflow).explanation).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if store.chatRun == nil && store.settings.workflow == .collaborate {
                        Text(store.team.map { $0.provider.name }.joined(separator: " → ")).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                }
                Button { store.screen = "connections" } label: {
                    Label("Manage connections", systemImage: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .sheet(item: $naming) { provider in RenameAgentSheet(identity: store.identity(provider)) }
        .sheet(isPresented: $editingTeam) { EditTeamSheet(identities: store.chatIdentities) }
    }
}

private struct AgentTeamRow: View {
    @EnvironmentObject private var store: EngineStore
    @Binding var config: AgentConfig
    let rename: () -> Void
    private var info: AgentInfo? { store.availability(config.provider) }
    private var member: Bool { store.chatRun?.conversation?.members.contains(config.provider) ?? config.selected }
    private var named: Bool { store.chatting && member }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Button {
                    if store.chatRun != nil { store.mention(config.provider) }
                    else if store.chatting || config.selected || info?.ready == true { config.selected.toggle() }
                    else { store.screen = "connections" }
                } label: {
                    HStack(spacing: 10) {
                        if named { TeammateAvatar(identity: store.identity(config.provider)) }
                        else { ProviderMark(provider: config.provider) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(named ? store.displayName(config.provider) : config.provider.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                            Text(named ? "\(config.provider.name) · @\(store.identity(config.provider).mention)" : store.statusLabel(config.provider))
                                .font(.system(size: 10)).foregroundStyle(info?.status == "missing" || info?.status == "incompatible" ? Color.orange.opacity(0.8) : .secondary).lineLimit(1)
                            if named && info?.ready != true {
                                Text(store.statusLabel(config.provider)).font(.system(size: 10)).foregroundStyle(.orange.opacity(0.8)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 2)
                        Image(systemName: member ? "checkmark.square.fill" : "square").font(.system(size: 14)).foregroundStyle(member ? Theme.accent : Color.secondary.opacity(0.4))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!store.loaded || info?.status == "checking" || (store.chatRun != nil && !member))
                    .help(store.chatRun != nil && member ? "Mention @\(store.identity(config.provider).mention). \(info?.detail ?? "")" : info?.detail ?? "Checking local installation")
                    .accessibilityLabel("\(named ? store.displayName(config.provider) : config.provider.name), \(config.provider.name), \(member ? "selected" : "unselected"), \(info?.label ?? "checking")")
                if named {
                    Button(action: rename) { Image(systemName: "pencil").font(.system(size: 10)).frame(width: 19, height: 25) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!store.canEditTeam)
                        .help("Rename \(store.displayName(config.provider)) for this task").accessibilityLabel("Rename \(store.displayName(config.provider))")
                }
            }
            if named {
                VStack(alignment: .leading, spacing: 6) {
                    AgentModelPicker(provider: config.provider)
                    AgentEffortPicker(provider: config.provider)
                }.padding(.leading, 41)
            }
        }.padding(.horizontal, 9).padding(.vertical, 10)
            .background(member ? Color.white.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct AgentModelPicker: View {
    @EnvironmentObject private var store: EngineStore
    @State private var custom = false
    let provider: Provider
    private var selection: Binding<String> {
        Binding(get: { store.modelOverride(provider) }, set: { model in
            if let error = store.setAgentModel(provider, model: model) { store.showNotice(error, error: true) }
        })
    }
    var body: some View {
        Menu {
            Picker("Model", selection: selection) {
                Text("Default · \(store.defaultModel(provider))").tag("")
                ForEach(store.modelOptions(provider)) { option in Text(option.label).tag(option.id) }
                if !selection.wrappedValue.isEmpty && !store.modelOptions(provider).contains(where: { $0.id == selection.wrappedValue }) {
                    Text(selection.wrappedValue).tag(selection.wrappedValue)
                }
            }
            Divider()
            Button("Custom model…") { custom = true }
        } label: {
            Label(store.modelLabel(provider), systemImage: "cpu").lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.menuStyle(.borderlessButton).font(.system(size: 11)).foregroundStyle(Theme.accent)
            .disabled(!store.canChangeChatModels || !store.chatMembers.contains(provider))
            .help("Model for \(store.displayName(provider)): \(store.modelLabel(provider)). Applies to the next reply in this chat.")
            .accessibilityLabel("Model for \(store.displayName(provider))")
            .sheet(isPresented: $custom) { CustomModelSheet(provider: provider, model: store.modelOverride(provider)) }
    }
}

private struct AgentEffortPicker: View {
    @EnvironmentObject private var store: EngineStore
    let provider: Provider
    private var selection: Binding<Effort> {
        Binding(get: { store.effortOverride(provider) }, set: { effort in
            if let error = store.setAgentEffort(provider, effort: effort) { store.showNotice(error, error: true) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                Picker("Reasoning effort", selection: selection) {
                    Text("Default · Connections or CLI settings").tag(Effort.default)
                    ForEach(store.effortOptions(provider)) { effort in Text(effort.label).tag(effort) }
                    if selection.wrappedValue != .default && !store.effortOptions(provider).contains(selection.wrappedValue) {
                        Text("\(selection.wrappedValue.label) · unavailable for this model").tag(selection.wrappedValue).disabled(true)
                    }
                }
            } label: {
                Label(store.effortOptions(provider).isEmpty ? "Effort unavailable" : store.effortLabel(provider), systemImage: "dial.low")
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.menuStyle(.borderlessButton).font(.system(size: 11)).foregroundStyle(.secondary)
                .disabled(!store.canChangeChatModels || !store.chatMembers.contains(provider))
                .help("Reasoning effort for \(store.displayName(provider)). Saved for this chat; applies to the next reply, including teammate requests. Changing effort starts a fresh agent session with the shared conversation. \(store.effortNote(provider))")
                .accessibilityLabel("Reasoning effort for \(store.displayName(provider))")
            if !store.effortIsValid(provider) {
                Text("Choose a supported effort for this model.").font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CustomModelSheet: View {
    @EnvironmentObject private var store: EngineStore
    @Environment(\.dismiss) private var dismiss
    let provider: Provider
    @State private var model: String
    @State private var error: String?
    init(provider: Provider, model: String) {
        self.provider = provider
        _model = State(initialValue: model)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose a model for \(store.displayName(provider))").font(.system(size: 19, weight: .semibold))
            Text("Saved for this chat and used on the next reply. Changing models starts a fresh agent session with the shared conversation.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                Text("Model ID").font(.system(size: 12, weight: .medium))
                TextField(store.defaultModel(provider), text: $model).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                Text("Leave blank to use the default from Connections.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Link("Provider documentation", destination: provider.docs).font(.system(size: 11))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    error = store.setAgentModel(provider, model: model)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!store.canChangeChatModels)
            }
        }.padding(26).frame(width: 440)
    }
}

private struct EditTeamSheet: View {
    @EnvironmentObject private var store: EngineStore
    @Environment(\.dismiss) private var dismiss
    @State private var identities: [AgentIdentity]
    @State private var error: String?
    init(identities: [AgentIdentity]) { _identities = State(initialValue: identities) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit your team").font(.system(size: 20, weight: .semibold))
            Text("Give each teammate a name for this chat. Use their @handle to bring them into the conversation.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($identities) { $identity in TeammateEditor(identity: $identity) }
                }
            }.frame(height: min(CGFloat(identities.count) * 120, 440))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Use suggested names") { identities = store.suggestedCoworkers(members: identities.map(\.provider)); error = nil }.font(.system(size: 11))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save team") {
                    error = store.renameTeam(identities)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!store.canEditTeam)
            }
            Text("Names are saved with this chat. Renaming keeps each teammate's conversation and selected model.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(26).frame(width: 570)
    }
}

private struct TeammateEditor: View {
    @EnvironmentObject private var store: EngineStore
    @Binding var identity: AgentIdentity
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TeammateAvatar(identity: identity)
                Text(identity.provider.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(store.modelLabel(identity.provider)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Name").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Teammate name", text: $identity.name).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name for \(identity.provider.name)")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Mention").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("handle", text: $identity.mention).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Mention handle for \(identity.provider.name)")
                    }
                }.frame(width: 175)
            }
        }.padding(13).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .onChange(of: identity.name) { old, name in
                if identity.mention == AgentIdentity.suggestedHandle(for: old, provider: identity.provider) {
                    identity.mention = AgentIdentity.suggestedHandle(for: name, provider: identity.provider)
                }
            }
    }
}

private struct RenameAgentSheet: View {
    @EnvironmentObject private var store: EngineStore
    @Environment(\.dismiss) private var dismiss
    let identity: AgentIdentity
    @State private var name: String
    @State private var mention: String
    @State private var error: String?
    init(identity: AgentIdentity) {
        self.identity = identity
        _name = State(initialValue: identity.name)
        _mention = State(initialValue: identity.mention)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename \(identity.name)").font(.system(size: 19, weight: .semibold))
            Text("Powered by \(identity.provider.name). This name and @handle are saved with this chat.").font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text("Name").font(.system(size: 12, weight: .medium))
                TextField("Agent name", text: $name).textFieldStyle(.roundedBorder)
                    .onChange(of: name) { old, name in
                        if mention == AgentIdentity.suggestedHandle(for: old, provider: identity.provider) {
                            mention = AgentIdentity.suggestedHandle(for: name, provider: identity.provider)
                        }
                    }
                Text("Mention handle").font(.system(size: 12, weight: .medium)).padding(.top, 5)
                HStack { Text("@").foregroundStyle(.secondary); TextField("atlas", text: $mention).textFieldStyle(.roundedBorder) }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    error = store.renameAgent(identity.provider, name: name, mention: mention)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!store.canEditTeam)
            }
        }.padding(26).frame(width: 400)
    }
}

private struct EmptyActivity: View {
    var body: some View {
        Panel {
            VStack(spacing: 10) {
                Image(systemName: "terminal").font(.system(size: 27, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 4)
                Text("No runs yet").font(.system(size: 14, weight: .medium))
                Text("Your agents’ results will appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 16)
        }
    }
}

private struct DeleteRunButton: View {
    @EnvironmentObject private var store: EngineStore
    let run: RunSummary
    var body: some View {
        Button(role: .destructive) { store.requestDeleteRun(run) } label: {
            Image(systemName: "trash")
        }.disabled(!store.canDeleteRun(run))
            .help(run.status.active ? "Stop this chat before deleting it" : "Delete \(run.workflow == .conversation ? "chat" : "task")…")
            .accessibilityLabel("Delete \(run.workflow == .conversation ? "chat" : "task") \(run.title)")
    }
}

private struct HistoryView: View {
    @EnvironmentObject private var store: EngineStore
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private var filtered: [RunSummary] {
        store.runs.filter { $0.matchesSearch(search) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack {
                    PageHeading(title: "Run history", subtitle: "Your chats, tasks, and agent responses. Saved on this Mac.")
                    Spacer(minLength: 16)
                    Button(action: store.newTask) { Label("New chat", systemImage: "square.and.pencil") }.controlSize(.large)
                }
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search chats or teammates", text: $search).textFieldStyle(.plain).font(.system(size: 15))
                        .focused($searchFocused).accessibilityLabel("Search chats or teammates")
                    if !search.isEmpty {
                        Button { search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                    }
                    Text("\(filtered.count) \(filtered.count == 1 ? "task" : "tasks")").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).frame(height: 48).frame(maxWidth: .infinity)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(searchFocused ? Theme.accent.opacity(0.85) : Theme.border))
                    .onTapGesture { searchFocused = true }
                if store.runs.isEmpty { EmptyActivity() }
                else {
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(filtered) { run in
                                HStack(spacing: 8) {
                                Button { store.selectRun(run.id) } label: {
                                    HStack(spacing: 12) {
                                        Circle().fill(run.status.color).frame(width: 6, height: 6)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(run.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                            Text("\(folderName(run.workspace)) · \(timeLabel(run.createdAt)) · \(run.workflow.name) · \(run.providers.map { run.displayName($0) }.joined(separator: ", "))")
                                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                                .help(run.workspace)
                                        }
                                        Spacer()
                                        if run.workflow == .conversation {
                                            Label("Open chat", systemImage: "bubble.left").font(.system(size: 12)).foregroundStyle(Theme.accent)
                                        }
                                        Text(run.status.label).font(.system(size: 11)).foregroundStyle(run.status.color)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                DeleteRunButton(run: run)
                                }.padding(15).background(store.selectedRunID == run.id ? Theme.accent.opacity(0.08) : Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(store.selectedRunID == run.id ? Theme.accent.opacity(0.25) : Theme.border))
                                    .contextMenu {
                                        Button("Open \(run.workflow == .conversation ? "chat" : "task")") { store.selectRun(run.id) }
                                        Divider()
                                        Button("Delete \(run.workflow == .conversation ? "chat" : "task")…", role: .destructive) { store.requestDeleteRun(run) }
                                            .disabled(!store.canDeleteRun(run))
                                    }
                            }
                            if filtered.isEmpty { Text("No tasks match your search.").foregroundStyle(.secondary).padding(20) }
                        }
                    }.frame(maxHeight: 230)
                    if let run = store.selectedRun {
                        if run.conversation != nil { ChatHistoryView(run: run) } else { RunDetailView(run: run) }
                    }
                }
            }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RunDetailView: View {
    @EnvironmentObject private var store: EngineStore
    let run: RunRecord
    @State private var tab = "response"
    private var stage: Stage? { run.stages.first { $0.provider == store.selectedProvider } ?? run.stages.first }
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Circle().fill(run.status.color).frame(width: 6, height: 6)
                    Text(run.status.label).font(.system(size: 12, weight: .medium)).foregroundStyle(run.status.color)
                    Spacer()
                    if run.status.active {
                        Button(store.cancelling.contains(run.id) ? "Cancelling…" : "Cancel run") { store.cancel(run.id) }
                            .tint(.red).disabled(store.cancelling.contains(run.id))
                    } else {
                        Button("Use task again") { store.reuse(run) }.controlSize(.small)
                        Button { store.startChat(from: run) } label: { Label("Start chat", systemImage: "bubble.left") }
                            .buttonStyle(.borderedProminent).help("Start a conversation with this task's prompt and agents")
                        DeleteRunButton(run: run.summary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.summary.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    Text("\(run.workflow.name) · \(timeLabel(run.createdAt))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(run.stages) { item in
                            Button { store.selectedProvider = item.provider } label: {
                                HStack(spacing: 6) {
                                    Text(item.provider.name)
                                    Circle().fill(item.status.color).frame(width: 4, height: 4)
                                }.font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 7)
                                    .foregroundStyle(stage?.provider == item.provider ? Color.primary : .secondary)
                                    .background(stage?.provider == item.provider ? Color.white.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).help(item.status.label)
                        }
                    }
                }
                Divider()
                if let stage {
                    HStack(spacing: 12) {
                        Picker("Detail", selection: $tab) { Text("Response").tag("response"); Text("Timeline").tag("timeline") }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 175)
                        Spacer(minLength: 0)
                        Button { store.copy(stage.output) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).disabled(stage.output.isEmpty).help("Copy response")
                        Button { store.export(run.id) } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.plain).help("Export Markdown")
                    }
                    if tab == "response" { response(stage) } else { timeline(stage) }
                    HStack(spacing: 15) {
                        Text("\(stage.usage.inputTokens + stage.usage.outputTokens) reported tokens")
                        if let cost = stage.usage.costUsd { Text(cost, format: .currency(code: "USD").precision(.fractionLength(4))) }
                        Spacer()
                        if !stage.model.isEmpty { Text(stage.model).lineLimit(1) }
                    }.font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }
    private func response(_ stage: Stage) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let reasoning = stage.reasoning, !reasoning.isEmpty {
                        ReasoningSection(text: reasoning, provider: stage.provider,
                                         working: stage.status == .running && stage.output.isEmpty)
                    }
                    if let error = stage.error { NativeResponseText(text: error, tone: .error).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 7)) }
                    if stage.output.isEmpty && (stage.reasoning?.isEmpty != false || stage.status != .running) {
                        HStack(spacing: 10) {
                            if stage.status == .running { ProgressView().controlSize(.small) }
                            Text(stage.status == .queued ? "Waiting for this agent’s turn…" : stage.status == .running ? "Waiting for the first response…" : "No response text. Open Timeline for details.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(.vertical, 30)
                    }
                    NativeResponseText(blocks: store.renderedResponses[stage.provider] ?? [])
                    Color.clear.frame(height: 1).id("response-end")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 100, maxHeight: 340)
                .onChange(of: stage.output.count) { _, _ in if stage.status.active { proxy.scrollTo("response-end", anchor: .bottom) } }
        }
    }
    private func timeline(_ stage: Stage) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 13) {
                ForEach(Array(visibleActivityLogs(stage.logs).enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.kind == "Tool" ? "hammer" : entry.kind == "Error" ? "exclamationmark.circle" : "circle.dotted")
                            .foregroundStyle(entry.kind == "Error" ? .red : .secondary).frame(width: 15)
                        Text(entry.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if stage.logs.isEmpty { Text("Events will appear when this agent starts.").foregroundStyle(.secondary) }
            }.padding(.vertical, 6)
        }.frame(minHeight: 100, maxHeight: 340)
    }
}

private struct ConnectionsView: View {
    var body: some View { ScrollView { ConnectionsContent() } }
}

private struct ConnectionsContent: View {
    @EnvironmentObject private var store: EngineStore
    var body: some View {
            VStack(alignment: .leading, spacing: 23) {
                HStack {
                    PageHeading(title: "Connections", subtitle: "Connect your local agents and choose how they work.")
                    Spacer()
                    Button("Save & check", action: store.rescan).controlSize(.large).disabled(!store.loaded || store.demo)
                }
                ClaudeConfigurationPanel()
                ForEach($store.settings.agents) { $config in ConnectionCard(config: $config) }
                Panel {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Agent timeout").font(.system(size: 13, weight: .medium))
                            Text("Maximum runtime for each agent, in seconds.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField("Seconds", value: $store.settings.timeoutSeconds, format: .number).textFieldStyle(.roundedBorder).frame(width: 95)
                            .onSubmit { store.settings.timeoutSeconds = min(7200, max(10, store.settings.timeoutSeconds)) }
                    }
                }
            }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClaudeConfigurationPanel: View {
    @EnvironmentObject private var store: EngineStore
    @State private var filesExpanded = false
    private var model: Binding<String> {
        Binding(get: { store.settings.agents.first { $0.provider == .claude }?.model ?? "" }, set: { value in
            if let index = store.settings.agents.firstIndex(where: { $0.provider == .claude }) { store.settings.agents[index].model = value }
        })
    }
    private var modelPlaceholder: String {
        switch store.settings.claudeBackend {
        case .anthropic: return "sonnet (default)"
        case .deepseek: return "deepseek-flash (default)"
        case .custom: return "Required model ID"
        case .inherit: return store.claudeConfig?.conductorModel ?? "CLI default"
        }
    }
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Claude Code configuration").font(.system(size: 15, weight: .semibold))
                        Text("Detect its current backend and choose a provider for your runs.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: store.rescan) { Image(systemName: "arrow.clockwise") }.help("Refresh Claude configuration")
                        .disabled(!store.loaded || store.demo)
                }
                if let detected = store.claudeConfig {
                    HStack(alignment: .top, spacing: 25) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Detected backend").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(detected.backend).font(.system(size: 14, weight: .medium))
                            Text("\(detected.source) · \(detected.model)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(detected.credentialConfigured ? "Credential configured" : "Authentication managed by Claude Code")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(detected.endpoint).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }.padding(14).background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    if detected.managedRouting {
                        Label("Your organization controls provider routing. Use Auto to follow its configuration.", systemImage: "building.2")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else { ProgressView("Detecting configuration…").font(.system(size: 12)) }
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Provider for Conductor runs").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("Provider", selection: Binding(get: { store.settings.claudeBackend }, set: store.setClaudeBackend)) {
                            ForEach(ClaudeBackend.allCases, id: \.self) { Text($0.name).tag($0) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Model").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField(modelPlaceholder, text: model).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    }.frame(maxWidth: .infinity)
                }
                if store.settings.claudeBackend == .inherit, let detected = store.claudeConfig,
                   detected.backend == "DeepSeek", detected.model != detected.conductorModel {
                    Label("Conductor uses \(detected.conductorModel) with DeepSeek, correcting the incompatible model in the saved CLI configuration.", systemImage: "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if store.settings.claudeBackend != .inherit {
                    HStack(alignment: .top, spacing: 20) {
                        if store.settings.claudeBackend == .custom || store.settings.claudeBackend == .deepseek {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("API base URL").font(.system(size: 11)).foregroundStyle(.secondary)
                                if store.settings.claudeBackend == .deepseek {
                                    TextField("https://api.deepseek.com", text: $store.settings.deepseekBaseUrl).textFieldStyle(.roundedBorder)
                                } else {
                                    TextField("https://provider.example/anthropic", text: $store.settings.claudeBaseUrl).textFieldStyle(.roundedBorder)
                                }
                            }.font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Session API key").font(.system(size: 11)).foregroundStyle(.secondary)
                            SecureField(store.settings.claudeBackend == .anthropic ? "Optional · uses Claude Code sign-in" : "Use detected credential or enter a key", text: $store.claudeSessionKey)
                                .textFieldStyle(.roundedBorder)
                        }.frame(maxWidth: .infinity)
                    }
                    Text("Keys aren’t saved to preferences. Click Save & check after changing the endpoint, model, or key.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("Provider overrides apply to runs started by Conductor. Your Claude Code settings files are preserved.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                DisclosureGroup("Configuration folder and sources", isExpanded: $filesExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            TextField(store.claudeConfig?.configDir ?? "Auto-detect ~/.claude", text: $store.settings.claudeConfigDir)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                            Button("Choose…", action: store.chooseClaudeConfigFolder)
                            if !store.settings.claudeConfigDir.isEmpty {
                                Button("Auto") { store.settings.claudeConfigDir = ""; store.rescan() }.help("Use CLAUDE_CONFIG_DIR or the default Claude folder")
                            }
                        }
                        Text("This folder is used by the Claude agent and the DeepSeek Claude Code harness.").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(store.claudeConfig?.sources.filter { $0.exists && ($0.path != nil || !$0.supplies.isEmpty) || $0.name == "User settings" } ?? []) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(source.name).font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text(source.error != nil ? "Unreadable" : source.exists ? source.supplies.isEmpty ? "No provider override" : "Provider settings" : "Uses CLI defaults")
                                        .font(.system(size: 10)).foregroundStyle(source.error != nil ? Color.orange : .secondary)
                                }
                                if let path = source.path { Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                                if let error = source.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
                            }.padding(.vertical, 3)
                        }
                    }.padding(.top, 12)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.disabled(!store.loaded || store.demo)
    }
}

private struct ConnectionCard: View {
    @EnvironmentObject private var store: EngineStore
    @Binding var config: AgentConfig
    @State private var advanced = false
    private var index: Int { store.settings.agents.firstIndex { $0.provider == config.provider } ?? 0 }
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 12) {
                    ProviderMark(provider: config.provider)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(config.provider.name).font(.system(size: 15, weight: .semibold))
                        Text(store.statusLabel(config.provider)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.settings.agents.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move earlier in handoff")
                    Button { store.settings.agents.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == store.settings.agents.count - 1).help("Move later in handoff")
                    Link("Documentation", destination: config.provider.docs).font(.system(size: 11))
                }
                if let info = store.availability(config.provider) {
                    Text(info.detail).font(.system(size: 11)).foregroundStyle(info.status == "missing" || info.status == "incompatible" ? Color.orange.opacity(0.8) : .secondary).textSelection(.enabled)
                }
                if config.provider == .deepseek {
                    Picker("Interface", selection: $store.settings.deepseekMode) {
                        Text("Claude Code · agent").tag(DeepSeekMode.claudeCode)
                        Text("Direct API · text").tag(DeepSeekMode.directApi)
                    }.pickerStyle(.segmented).frame(maxWidth: 370)
                    if store.settings.deepseekMode == .claudeCode {
                        Toggle("Use Claude Code’s existing DeepSeek configuration", isOn: $store.settings.deepseekUseCliConfig).font(.system(size: 12))
                    } else {
                        Text("Direct API generates text and reasoning. It has no workspace file or shell tools.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if store.settings.deepseekMode == .directApi || !store.settings.deepseekUseCliConfig {
                        HStack(spacing: 18) {
                            field("API base URL", text: $store.settings.deepseekBaseUrl, placeholder: "https://api.deepseek.com")
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Session API key").font(.system(size: 11)).foregroundStyle(.secondary)
                                SecureField("DEEPSEEK_API_KEY or session key", text: $store.sessionKey).textFieldStyle(.roundedBorder)
                            }
                        }
                        Text("Session keys aren’t saved to preferences. CLI authentication remains managed by your CLI.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if config.provider == .kiro {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Session API key").font(.system(size: 11)).foregroundStyle(.secondary)
                        SecureField("KIRO_API_KEY or session key", text: $store.kiroSessionKey).textFieldStyle(.roundedBorder)
                        Text("Headless Kiro uses an API key. This key is kept in memory for Agent Conductor runs.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 18) {
                    if config.provider != .deepseek || store.settings.deepseekMode == .claudeCode {
                        field("Executable", text: $config.executable, placeholder: config.provider == .deepseek ? "Auto-detect claude" : config.provider == .kiro ? "Auto-detect kiro-cli" : "Auto-detect \(config.provider.name)")
                    }
                    if config.provider != .claude {
                        field("Model", text: $config.model, placeholder: config.provider == .deepseek && !store.settings.deepseekUseCliConfig ? "deepseek-flash" : "CLI default")
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Picker("Default reasoning effort", selection: $config.effort) {
                        Text("CLI / provider default").tag(Effort.default)
                        ForEach(store.effortOptions(config.provider, model: config.model.isEmpty ? store.defaultModel(config.provider) : config.model)) { effort in
                            Text(effort.label).tag(effort)
                        }
                        if config.effort != .default && !store.effortOptions(config.provider, model: config.model).contains(config.effort) {
                            Text("\(config.effort.label) · unavailable for this model").tag(config.effort).disabled(true)
                        }
                    }.frame(maxWidth: 420).font(.system(size: 12))
                    Text("Used by new chats and batch runs. Change each teammate's effort under Your team to override it for one chat.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Additional arguments · JSON array", text: $config.extraArgs, placeholder: "[]")
                        Toggle("Allow file edits", isOn: $config.allowEdits).font(.system(size: 12))
                        Text("Existing CLI permission rules still apply. Parallel agents share the selected workspace.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
        }.frame(maxWidth: .infinity)
    }
}

// Renders the same SwiftUI content without the AppKit window wrapper for layout QA.
// Native text editors and pickers remain exercised by the running application.
private struct CoworkerTeamPanel: View {
    @EnvironmentObject private var store: EngineStore
    @State private var editing: Coworker?
    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Your coworkers").font(.system(size: 14, weight: .semibold)); Spacer(); Text("\(store.coworkers.count)").font(.system(size: 11)).foregroundStyle(.secondary) }
                Text(store.chatRun == nil ? "Fresh people and sessions for this chat." : "Each coworker has their own session.").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(store.coworkers) { worker in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 9) {
                            TeammateAvatar(identity: worker.identity)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(worker.name).font(.system(size: 13, weight: .semibold))
                                Text("\(worker.role.label) · \(worker.provider.name)").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button { editing = worker } label: { Image(systemName: "pencil") }.buttonStyle(.plain).disabled(!store.canChangeChatModels).help("Edit \(worker.name)'s name, role, model and effort")
                            if store.chatRun == nil { Button { store.removeCoworker(worker.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!store.canChangeChatModels) }
                        }
                        HStack(spacing: 6) {
                            Circle().fill(worker.attention == "working" ? Theme.accent : worker.attention == "needs_answer" || worker.attention == "failed" ? .orange : .mint.opacity(0.7)).frame(width: 5, height: 5)
                            Text(store.availability(worker.provider)?.ready == true ? worker.statusLabel(in: store.coworkers) : store.statusLabel(worker.provider)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("@\(worker.mention)") { store.mentionCoworker(worker) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.accent)
                        }
                        CoworkerModelMenu(worker: worker)
                        CoworkerEffortMenu(worker: worker)
                    }.padding(11).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                if store.chatRun == nil {
                    HStack {
                        Menu("Add coworker") { ForEach(Provider.allCases) { provider in Button(provider.name) { store.addCoworker(provider) } } }.disabled(!store.canChangeChatModels || store.coworkers.count >= 6)
                        Spacer(minLength: 4)
                        Button("Role team") { store.resetRoleTeam() }.font(.system(size: 11)).disabled(!store.canChangeChatModels).help("Create Architect, Builder and Reviewer coworkers")
                    }.font(.system(size: 11))
                    Divider()
                    Text("Task workspace").font(.system(size: 12, weight: .medium))
                    Picker("Workspace", selection: $store.isolationMode) {
                        Text("Shared project folder").tag("shared")
                        Text("New isolated worktree").tag("worktree")
                        if !store.sharedTaskChoices.isEmpty { Text("Share another task's workspace").tag("share_task") }
                    }.labelsHidden()
                    if store.isolationMode == "share_task" {
                        Picker("Share with", selection: $store.shareTaskID) { Text("Choose a task").tag(""); ForEach(store.sharedTaskChoices) { run in Text(run.title).tag(run.id) } }
                    }
                    Text(store.isolationMode == "worktree" ? "Creates a branch from HEAD. Uncommitted files stay in the original folder. All coworkers in this chat share the new checkout." : "All coworkers in this chat work in the same folder. Choose isolation for independent changes.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let info = store.chatRun?.workspaceInfo {
                    Divider()
                    Label(info.isolated ? "Isolated task workspace" : "Shared project folder", systemImage: info.isolated ? "arrow.triangle.branch" : "folder").font(.system(size: 11))
                    if !info.branch.isEmpty { Text(info.branch).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("Open task folder") { NSWorkspace.shared.open(URL(fileURLWithPath: info.path)) }.font(.system(size: 11))
                }
                Divider()
                Button { store.screen = "connections" } label: { Label("Manage connections", systemImage: "arrow.up.right") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.sheet(item: $editing) { CoworkerEditSheet(worker: $0) }
    }
}

private struct CoworkerModelMenu: View {
    @EnvironmentObject private var store: EngineStore
    let worker: Coworker
    @State private var editing = false
    var body: some View {
        Menu {
            Button("Default · \(store.defaultModel(worker.provider))") { choose("") }
            ForEach(store.modelOptions(worker.provider)) { option in Button(option.label) { choose(option.id) } }
            Divider(); Button("Custom model…") { editing = true }
        } label: { Label(store.coworkerModelLabel(worker), systemImage: "cpu").font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading) }
            .menuStyle(.borderlessButton).disabled(!store.canChangeChatModels).help("Model for \(worker.name): \(store.coworkerModelLabel(worker))")
            .sheet(isPresented: $editing) { CoworkerEditSheet(worker: worker) }
    }
    private func choose(_ model: String) { var edited = worker; edited.model = model; if let error = store.updateCoworker(edited) { store.notice = error; store.noticeIsError = true } }
}

private struct CoworkerEffortMenu: View {
    @EnvironmentObject private var store: EngineStore
    let worker: Coworker
    var body: some View {
        Menu {
            Button("Default") { choose(.default) }
            ForEach(store.effortOptions(worker.provider, model: worker.model.isEmpty ? store.defaultModel(worker.provider) : worker.model)) { effort in Button(effort.label) { choose(effort) } }
        } label: { Label(worker.effort == .default ? "Effort · Default" : "Effort · \(worker.effort.label)", systemImage: "dial.medium").font(.system(size: 11)) }
            .menuStyle(.borderlessButton).disabled(!store.canChangeChatModels).help("Reasoning effort for \(worker.name)")
    }
    private func choose(_ effort: Effort) { var edited = worker; edited.effort = effort; if let error = store.updateCoworker(edited) { store.notice = error; store.noticeIsError = true } }
}

private struct CoworkerEditSheet: View {
    @EnvironmentObject private var store: EngineStore
    @Environment(\.dismiss) private var dismiss
    @State var worker: Coworker
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit coworker").font(.system(size: 22, weight: .semibold))
            Form {
                TextField("Name", text: $worker.name).onChange(of: worker.name) { old, name in if worker.mention == AgentIdentity.suggestedHandle(for: old, provider: worker.provider) { worker.mention = AgentIdentity.suggestedHandle(for: name, provider: worker.provider) } }
                TextField("@handle", text: $worker.mention)
                Picker("Role", selection: $worker.role) { ForEach(CoworkerRole.allCases) { role in Text(role.label).tag(role) } }
                Text(worker.role.description).font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("Connection", selection: $worker.provider) { ForEach(Provider.allCases) { provider in Text(provider.name).tag(provider) } }.disabled(store.chatRun != nil)
                Picker("Model", selection: $worker.model) {
                    Text("Default").tag("")
                    ForEach(store.modelOptions(worker.provider)) { option in Text(option.label).tag(option.id) }
                    if !worker.model.isEmpty && !store.modelOptions(worker.provider).contains(where: { $0.id == worker.model }) { Text(worker.model).tag(worker.model) }
                }
                TextField("Custom model ID", text: $worker.model)
                Picker("Reasoning effort", selection: $worker.effort) {
                    Text("Default").tag(Effort.default)
                    ForEach(store.effortOptions(worker.provider, model: worker.model.isEmpty ? store.defaultModel(worker.provider) : worker.model)) { effort in Text(effort.label).tag(effort) }
                    if worker.effort != .default && !store.effortOptions(worker.provider, model: worker.model).contains(worker.effort) { Text("\(worker.effort.label) · unsupported").tag(worker.effort) }
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { if let issue = store.updateCoworker(worker) { error = issue } else { dismiss() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 470)
    }
}

private struct MailboxInspectorView: View {
    @EnvironmentObject private var store: EngineStore
    var scrollable = true
    var body: some View {
        Group { if scrollable { ScrollView { content } } else { content } }
    }
    private var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Mailbox").font(.system(size: 16, weight: .semibold)); Spacer(); Text("\(store.queuedMail.count) pending").font(.system(size: 11)).foregroundStyle(.secondary) }
                if store.queuedMail.contains(where: { $0.state == "paused" }) {
                    Text("The exchange reached its eight-turn limit. Continue when you want the remaining deliveries to run.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Continue queued messages", action: store.continueMailbox).disabled(store.busy || store.hasPendingQuestions || store.demo)
                }
                if (store.chatRun?.conversation?.mailbox ?? []).isEmpty { Text("Requests, replies and queued messages will appear here.").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(Array((store.chatRun?.conversation?.mailbox ?? []).suffix(30).reversed())) { mail in
                    Panel(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(store.coworkers.first { $0.id == mail.from }?.name ?? "You") → \(store.coworkers.first { $0.id == mail.to }?.name ?? "Coworker")").font(.system(size: 12, weight: .medium))
                            Text(mail.label).font(.system(size: 10)).foregroundStyle(mail.state == "failed" || mail.state == "waiting_for_user" ? .orange : .secondary)
                            Text(mail.text.isEmpty ? "Team synthesis" : mail.text).font(.system(size: 11)).lineLimit(4).textSelection(.enabled)
                            if mail.cancellable { Button("Cancel delivery") { store.cancelDelivery(mail) }.font(.system(size: 10)).disabled(store.demo) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
    }
}

struct AttentionInboxView: View {
    @EnvironmentObject private var store: EngineStore
    var scrollable = true
    private var tasks: [RunSummary] { store.runs.filter { !($0.attention ?? []).isEmpty } }
    var body: some View {
        Group { if scrollable { ScrollView { content } } else { content } }
    }
    private var content: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    PageHeading(title: "Inbox", subtitle: "Questions, approvals and changes that need your attention.")
                    Spacer(minLength: 0)
                    Button(action: store.clearInbox) { Label(store.clearingInbox ? "Clearing…" : "Clear inbox", systemImage: "checkmark.circle") }
                        .disabled(!store.canClearInbox)
                        .help("Dismiss the current inbox items. Pending questions and approvals stay available in their chats.")
                }
                if tasks.isEmpty { Panel { Label("You're caught up.", systemImage: "checkmark.circle").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40) } }
                ForEach(tasks) { run in
                    ForEach(run.attention ?? []) { item in
                        Panel {
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: item.kind == "approval" ? "hand.raised" : item.kind == "review" ? "arrow.triangle.branch" : "questionmark.bubble").font(.system(size: 20)).foregroundStyle(item.kind == "review" ? Theme.accent : .orange)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(item.title).font(.system(size: 15, weight: .medium))
                                    Text("\(run.coworkers?.first { $0.id == item.ownerId }?.name ?? "Coworker") · \(run.title) · \(folderName(run.workspace))").font(.system(size: 12)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button(item.kind == "approval" ? "Review command" : item.kind == "review" ? "Review changes" : "Answer question") { store.openAttention(run: run, item: item) }
                                Button { store.dismissAttention(run: run, item: item) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .padding(4).disabled(!store.canClearInbox)
                                    .help("Dismiss from inbox").accessibilityLabel("Dismiss \(item.title) from inbox")
                            }
                        }
                    }
                }
            }.padding(32)
    }
}

private struct AgentApprovalCard: View {
    @EnvironmentObject private var store: EngineStore
    let runID: String
    let message: ChatMessage
    let request: AgentApprovalRequest
    let agentName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(agentName) needs approval", systemImage: "hand.raised").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            Text(request.summary).font(.system(size: 12))
            Text(arguments).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            Text("Runs in \(store.chatRun?.workspace ?? "this task's workspace"). Approval applies to this command once.").font(.system(size: 10)).foregroundStyle(.secondary)
            if let decision = request.decision {
                if let result = request.result { CheckResultView(result: result) }
                else if decision { ProgressView("Running approved command…").controlSize(.small) }
                else { Text("Declined. The command was not run.").font(.system(size: 11)).foregroundStyle(.secondary) }
            } else {
                HStack {
                    Button("Decline") { store.decideApproval(runID: runID, message: message, approved: false) }
                    Button("Approve once") { store.decideApproval(runID: runID, message: message, approved: true) }.buttonStyle(.borderedProminent)
                }.disabled(store.busy || store.demo || store.pendingQuestionReplies.contains(request.id))
            }
        }.padding(14).background(.orange.opacity(0.045), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.25)))
    }
    private var arguments: String {
        guard let data = try? JSONSerialization.data(withJSONObject: request.argv, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return request.argv.joined(separator: "\n") }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct ChangesInspectorView: View {
    @EnvironmentObject private var store: EngineStore
    var scrollable = true
    @State private var selectedPath = ""
    @State private var feedback = ""
    @State private var feedbackOwner = ""
    @State private var testCommand = ""
    @State private var error: String?
    private var files: [ChangedFile] { store.chatRun?.changes?.files ?? [] }
    private var file: ChangedFile? { files.first { $0.path == selectedPath } ?? files.first }
    var body: some View {
        Group { if scrollable { ScrollView { content } } else { content } }
            .onAppear { feedbackOwner = file?.ownerId ?? "" }
            .onChange(of: file?.path) { _, _ in feedbackOwner = file?.ownerId ?? ""; feedback = "" }
    }
    private var content: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Changes").font(.system(size: 16, weight: .semibold)); Spacer(); Button { store.refreshChanges() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(store.busy || store.chatRun == nil) }
                if let run = store.chatRun {
                    if let branch = run.changes?.branch, !branch.isEmpty { Label(branch, systemImage: "arrow.triangle.branch").font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    Text(run.workspaceInfo?.isolated == true ? "Task changes since this checkout was created" : "Shared folder diff against HEAD").font(.system(size: 10)).foregroundStyle(.secondary)
                    if let error = run.changes?.error { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
                    if files.isEmpty { Text("No file changes to review.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(files) { item in
                        Button { selectedPath = item.path; feedbackOwner = item.ownerId ?? store.effectiveCoworker?.id ?? ""; feedback = "" } label: {
                            HStack(spacing: 8) { Text(item.status).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Theme.accent); Text(item.path).font(.system(size: 11)).lineLimit(2); Spacer(); if let owner = store.coworkers.first(where: { $0.id == item.ownerId }) { Text(owner.name).font(.system(size: 10)).foregroundStyle(.secondary) } }
                                .padding(8).background(file?.path == item.path ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                    if let file {
                        Divider()
                        HStack { Text(file.path).font(.system(size: 12, weight: .medium)).lineLimit(2); Spacer(); Button { NSWorkspace.shared.open(URL(fileURLWithPath: run.workspace).appendingPathComponent(file.path)) } label: { Image(systemName: "arrow.up.right") }.help("Open file") }
                        if scrollable { ScrollView([.horizontal, .vertical]) {
                            Text(diffText(file.diff)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 140, maxHeight: 360).background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 6)) }
                        else { Text(diffText(file.diff)).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 6)) }
                        if file.truncated { Text("Diff preview truncated. Open the file for the complete content.").font(.system(size: 10)).foregroundStyle(.secondary) }
                        TextField("Review feedback for this file…", text: $feedback, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                        Picker("Send to", selection: $feedbackOwner) { Text("Choose coworker").tag(""); ForEach(store.coworkers) { worker in Text(worker.name).tag(worker.id) } }.font(.system(size: 11))
                        Button("Send feedback") { store.sendReviewFeedback(file: file, text: feedback, owner: feedbackOwner); feedback = "" }.disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feedbackOwner.isEmpty || store.busy || store.hasPendingQuestions || store.demo)
                    }
                    if !files.isEmpty { Button("Ask reviewer", action: store.askForReview).disabled(!store.canChangeChatModels || store.hasPendingQuestions).font(.system(size: 11)) }
                    Divider()
                    Text("Checks").font(.system(size: 13, weight: .semibold))
                    TextField("Test command, e.g. cargo test --locked", text: $testCommand).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    Button("Run check") { error = store.runCheck(testCommand) }.disabled(store.busy || store.demo || testCommand.isEmpty || store.hasPendingQuestions)
                    if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
                    ForEach(Array((run.changes?.checks ?? []).suffix(8).reversed())) { result in CheckResultView(result: result) }
                } else { Text("Start a chat to inspect its files, diffs and checks.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
    }
    private func diffText(_ source: String) -> AttributedString {
        var result = AttributedString()
        for line in source.components(separatedBy: "\n") {
            var text = AttributedString(line + "\n")
            if line.hasPrefix("+") { text.foregroundColor = .mint }
            else if line.hasPrefix("-") { text.foregroundColor = .red.opacity(0.8) }
            else if line.hasPrefix("@@") { text.foregroundColor = Theme.accent }
            result.append(text)
        }
        return result
    }
}

private struct CheckResultView: View {
    let result: CheckResult
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(result.output.isEmpty ? "No command output." : result.output).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(result.status == .completed ? "Passed" : result.status.label, systemImage: result.status == .completed ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(result.status == .completed ? .mint : .orange)
                Text(result.argv.joined(separator: " ")).font(.system(size: 10, design: .monospaced)).lineLimit(2)
                if let exit = result.exitCode { Text("Exit code \(exit)").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.font(.system(size: 11))
        }
    }
}

struct LayoutPreview: View {
    @EnvironmentObject private var store: EngineStore
    let width: CGFloat
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SidebarView(scrollable: false).frame(width: 212)
            Rectangle().fill(Theme.border).frame(width: 1)
            Group {
                if store.screen == "connections" { ConnectionsContent() }
                else if store.screen == "attention" { AttentionInboxView(scrollable: false) }
                else if store.screen == "history" { HistoryView() }
                else if store.chatting { WorkspaceChatView(run: store.chatRun, availableWidth: width - 213, teamWidth: width - 213 < 930 ? 242 : 270, preview: true) }
                else { WorkspaceContent(teamWidth: width - 213 < 930 ? 242 : 270) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }.background(Theme.background)
    }
}
