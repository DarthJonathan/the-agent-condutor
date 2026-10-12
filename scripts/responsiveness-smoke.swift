import AppKit
import SwiftUI

// Exercise the real window layout while waiting, streaming and typing a mention.
// No engine, credentials, model calls or saved production state are used.
@main enum ResponsivenessSmoke {
    @MainActor static func main() throws {
        try verifyDelivery()
        if CommandLine.arguments.contains("--delivery-only") { return }
        let fixture = try String(contentsOfFile: "scripts/fixtures/markdown-response.md", encoding: .utf8)
        let probe = ResponsivenessProbe(fixture: fixture)
        if CommandLine.arguments.contains("--offscreen-scroll") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            probe.verifyOffscreenScroll()
            return
        }
        if CommandLine.arguments.contains("--render-only") {
            try probe.renderLayouts()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        app.delegate = probe
        probe.openWindow()
        withExtendedLifetime(probe) { app.run() }
        if probe.failed && !CommandLine.arguments.contains("--baseline") { exit(1) }
    }
    @MainActor private static func verifyDelivery() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var delivered: [String] = []
        let delivery = EventDelivery { event, _, _ in delivered.append(event.run?.prompt ?? event.type) }
        func enqueue(_ status: String, _ text: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["type": "run_updated", "run": ["id": "fixture-chat", "prompt": text, "workspace": "/fixture", "workflow": "Conversation", "created_at": "2026-10-11T10:00:00Z", "status": status, "stages": []]])
            delivery.enqueue(try decoder.decode(EngineEvent.self, from: data), rendered: [:], chat: [:])
        }
        try enqueue("Queued", "acknowledged")
        for i in 0..<1000 { try enqueue("Running", "token-\(i)") }
        try enqueue("WaitingForUser", "needs-answer")
        delivery.enqueue(try decoder.decode(EngineEvent.self, from: Data("{\"type\":\"notice\"}".utf8)), rendered: [:], chat: [:])
        try enqueue("Completed", "finished")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        guard delivered == ["acknowledged", "token-999", "needs-answer", "notice", "finished"] else { fatalError("UI backpressure lost a control event or delivered stale streaming snapshots: \(delivered)") }
        print("UI event delivery passed: 1,000 queued snapshots coalesced; start, question, notice and completion preserved")
        try verifyScrollDelivery(decoder: decoder)
    }

    @MainActor private static func verifyScrollDelivery(decoder: JSONDecoder) throws {
        var received: [String] = []
        let delivery = EventDelivery { event, _, _ in received.append(event.run?.prompt ?? event.type) }
        func enqueue(_ text: String, status: String = "Running", id: String = "scroll-chat", messages: [[String: Any]] = []) throws {
            let run: [String: Any] = ["id": id, "prompt": text, "workspace": "/fixture", "workflow": "Conversation", "created_at": "now", "status": status, "stages": [],
                                      "conversation": ["members": ["claude"], "lead": "claude", "messages": messages, "sessions": []]]
            delivery.enqueue(try decoder.decode(EngineEvent.self, from: JSONSerialization.data(withJSONObject: ["type": "run_updated", "run": run])), rendered: [:], chat: [:])
        }
        func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        try enqueue("seed"); settle()
        delivery.setScrolling(true)
        for i in 0..<1000 { try enqueue("scroll-token-\(i)") }
        settle()
        guard received == ["seed"] else { fatalError("Streaming text must not rebuild the chat during a live scroll") }
        delivery.setScrolling(false); settle()
        guard received == ["seed", "scroll-token-999"] else { fatalError("Ending a scroll must display the latest response exactly once") }

        delivery.setScrolling(true)
        try enqueue("before-question")
        let question: [String: Any] = ["id": "ask", "at": "now", "kind": "question", "author": "claude", "to": [], "text": "Choose the scope", "status": "WaitingForUser", "model": "fixture", "logs": [], "usage": ["input_tokens": 0, "output_tokens": 0],
                                       "question_request": ["id": "scope", "questions": [["id": "q", "header": "Scope", "question": "Which scope?", "options": [], "multi_select": false]]]]
        try enqueue("question", messages: [question]); settle()
        guard Array(received.suffix(2)) == ["before-question", "question"] else { fatalError("A question must be delivered immediately even when the run is still Running") }
        let approval: [String: Any] = ["id": "approve", "at": "now", "kind": "approval", "author": "claude", "to": [], "text": "Run checks?", "status": "WaitingForUser", "model": "fixture", "logs": [], "usage": ["input_tokens": 0, "output_tokens": 0],
                                       "approval_request": ["id": "command", "summary": "Run checks", "argv": ["cargo", "test"]]]
        try enqueue("approval", messages: [question, approval]); settle()
        guard received.last == "approval" else { fatalError("An approval must bypass the visual progress hold") }
        let handoff: [String: Any] = ["id": "review", "at": "now", "kind": "assistant", "author": "codex", "to": [], "text": "", "status": "Running", "model": "fixture", "logs": [], "usage": ["input_tokens": 0, "output_tokens": 0]]
        try enqueue("handoff", messages: [handoff]); settle()
        guard received.last == "handoff" else { fatalError("A teammate handoff must remain visible during scrolling") }
        try enqueue("held-review", messages: [handoff]); settle()
        guard received.last == "handoff" else { fatalError("Only the reviewer progress should be deferred") }
        try enqueue("cancelled", status: "Cancelled", messages: [handoff]); settle()
        guard Array(received.suffix(2)) == ["held-review", "cancelled"] else { fatalError("Cancellation must flush the latest text before its terminal state") }
        delivery.setScrolling(false); settle()
        guard received.last == "cancelled" else { fatalError("Resuming delivery must never restore a stale active snapshot") }

        try enqueue("first-seed", id: "first"); try enqueue("second-seed", id: "second"); settle()
        delivery.setScrolling(true)
        let count = received.count
        for i in 0..<1000 { try enqueue("first-\(i)", id: "first"); try enqueue("second-\(i)", id: "second") }
        settle()
        guard received.count == count else { fatalError("Background runs must not compete with live scrolling") }
        delivery.setScrolling(false); settle()
        guard Array(received.suffix(2)) == ["first-999", "second-999"] && received.count == count + 2 else { fatalError("Multiple runs must coalesce independently without losing their latest snapshots") }
        let before = received.count
        for i in 0..<100 { try enqueue("paced-\(i)", id: "first"); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.006)) }
        settle()
        guard received.last == "paced-99", received.count - before < 20 else { fatalError("Normal streaming must be paced while keeping the latest answer") }
        print("Scroll delivery passed: visual progress held, latest response restored, questions/approvals/handoffs/cancellation immediate, two runs bounded and streaming paced")
    }
}

@MainActor final class ResponsivenessProbe: NSObject, NSApplicationDelegate {
    let store = EngineStore(options: LaunchOptions())
    private var window: NSWindow?
    private var pulse: Timer?
    private var update: Timer?
    private var lastPulse: TimeInterval = 0
    private var gaps: [TimeInterval] = []
    private var index = 0
    private var samples: [(RunRecord, [String: [ResponseBlock]])] = []
    var failed = false

    init(fixture: String) {
        super.init()
        let workspace = FileManager.default.currentDirectoryPath
        store.settings.workspace = workspace; store.settings.workspaceFolders = [workspace]
        store.settings.workflow = .conversation; store.settings.chatIntroduced = true
        store.agents = Provider.allCases.map { AgentInfo(provider: $0, status: "ready", label: "Fixture", detail: "Fixture") }
        let workers = [Coworker(provider: .claude, name: "Maya", mention: "maya", role: .architect),
                       Coworker(provider: .codex, name: "Alex", mention: "alex", role: .builder),
                       Coworker(provider: .codex, name: "Noah", mention: "noah", role: .reviewer)]
        let usage = Usage(inputTokens: 10, outputTokens: 10, costUsd: nil)
        let at = "2026-10-11T10:00:00Z"
        let longResponse = fixture + "\n\n" + (0..<70).map { index in
            "### Finding \(index + 1)\n\nThe builder should keep the change scoped to the requested task, verify the affected behavior, and send the reviewer the relevant files and test results. The reviewer can reply in its own session before the lead continues."
        }.joined(separator: "\n\n")
        for frame in 0..<60 {
            var messages: [ChatMessage] = []
            for step in 0..<2 {
                messages.append(ChatMessage(id: "user-\(step)", at: at, kind: "user", author: nil, to: [], text: "Review the project and discuss the approach.", status: .completed, model: "", sessionId: nil, logs: [], usage: usage, error: nil))
                var message = ChatMessage(id: "reply-\(step)", at: at, kind: "assistant", author: workers[step].provider, to: [], text: longResponse, status: .completed, model: "fixture-model", sessionId: nil, logs: [], usage: usage, error: nil)
                message.authorId = workers[step].id; messages.append(message)
            }
            var active = ChatMessage(id: "stream", at: at, kind: "assistant", author: .claude, to: [], text: frame < 10 ? "" : frame < 30 ? String(longResponse.prefix((frame - 9) * 900)) : longResponse, status: frame < 30 ? .running : .completed, model: "fixture-model", sessionId: nil, logs: [], usage: usage, error: nil)
            active.reasoning = "Inspect the implementation and decide which coworker should review it."
            active.authorId = workers[0].id; messages.append(active)
            if frame >= 30 {
                var request = ChatMessage(id: "handoff", at: at, kind: "request", author: .claude, to: [.codex], text: "Please review this result.\n\n" + longResponse, status: .completed, model: "", sessionId: nil, logs: [], usage: usage, error: nil)
                request.authorId = workers[0].id; request.recipientIds = [workers[2].id]; messages.append(request)
                var review = ChatMessage(id: "review", at: at, kind: "assistant", author: .codex, to: [.claude], text: frame < 40 ? "" : String(longResponse.prefix((frame - 39) * 900)), status: .running, model: "fixture-reviewer", sessionId: nil, logs: [], usage: usage, error: nil)
                review.authorId = workers[2].id; review.recipientIds = [workers[0].id]
                review.reasoning = "Check the builder's changes against the request."
                messages.append(review)
            }
            var run = RunRecord(id: "fixture-chat", prompt: "Discuss the implementation", workspace: workspace, workflow: .conversation, createdAt: at, finishedAt: nil, status: .running, stages: [])
            run.conversation = TaskConversation(members: [.claude, .codex], lead: .claude, messages: messages, sessions: [], coworkers: workers, leadId: workers[0].id, mailbox: [])
            samples.append((run, Dictionary(uniqueKeysWithValues: messages.map { ($0.id, responseBlocks($0.text)) })))
        }
        store.loaded = true; store.connected = true
        store.runs = [samples[0].0.summary]; store.continueChat(samples[0].0)
        store.renderedChat = samples[0].1
    }
    func openWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RootView().environmentObject(store).environment(\.colorScheme, .dark).tint(Theme.accent))
        window.title = "Conductor responsiveness fixture"
        window.center(); window.orderFront(nil); self.window = window
        print("Timing native chat layout at 1050 × 740 with long responses and a teammate handoff"); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
    }
    func renderLayouts() throws {
        var times: [Double] = []
        for index in stride(from: 0, to: samples.count, by: 10) {
            let (run, blocks) = samples[index]
            store.selectedRun = run; store.renderedChat = blocks
            store.inspectorTab = index == 40 ? "changes" : "team"
            let content = LayoutPreview(width: 1050).environmentObject(store).environment(\.colorScheme, .dark).tint(Theme.accent).frame(width: 1050, height: 740)
            let begin = ProcessInfo.processInfo.systemUptime
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            guard let image = renderer.cgImage else { fatalError("Could not render response layout") }
            times.append(ProcessInfo.processInfo.systemUptime - begin)
            if index == 50, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "target/responsiveness-layout.png"))
            }
        }
        print(String(format: "Offline layout render: %d snapshots; mean %.1f ms, maximum %.1f ms", times.count, times.reduce(0, +) / Double(times.count) * 1000, (times.max() ?? 0) * 1000))
        print("ImageRenderer omits AppKit controls; use the native window mode to check main-loop latency.")
    }
    func verifyOffscreenScroll() {
        let host = NSHostingView(rootView: RootView().environmentObject(store).environment(\.colorScheme, .dark).tint(Theme.accent))
        host.frame = NSRect(x: 0, y: 0, width: 1050, height: 740)
        // A never-ordered window gives SwiftUI a real scroll document without
        // opening anything on the desktop or driving the user's application.
        let hiddenWindow = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        hiddenWindow.contentView = host
        defer { withExtendedLifetime(hiddenWindow) {} }
        var maximum: TimeInterval = 0
        var observedText = 0
        var observerConnected = false
        for frame in stride(from: 0, to: samples.count, by: 5) {
            let (run, blocks) = samples[frame]
            store.runs = [run.summary]; store.selectedRun = run; store.renderedChat = blocks
            let begin = ProcessInfo.processInfo.systemUptime
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
            let nativeText = descendants(host).compactMap { $0 as? ResponseTextView }
            observedText = max(observedText, nativeText.count)
            guard let observer = descendants(host).compactMap({ $0 as? TranscriptScrollObserverView }).first,
                  let scroll = observer.enclosingScrollView, let document = scroll.documentView else {
                fatalError("The real chat must attach its user-scroll observer to the transcript")
            }
            observerConnected = true
            guard document.bounds.height > scroll.contentView.bounds.height else { fatalError("The fixture must actually scroll beyond the first reply") }
            let completed = nativeText.filter { $0.string.hasPrefix("Agent Conductor") }
            let passes = completed.map(\.layoutPasses)
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            for position in 0..<20 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(position) / 19 * max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                host.layoutSubtreeIfNeeded()
            }
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
            guard completed.map(\.layoutPasses) == passes else { fatalError("Manual scrolling invalidated a completed reply's native layout") }
            for text in nativeText {
                guard let layout = text.layoutManager, let container = text.textContainer else { fatalError("Missing native reply layout") }
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container)
                guard used.maxY <= text.bounds.height + 1, used.maxX <= text.bounds.width + 1 else {
                    fatalError("Full chat reply overflow at frame \(frame): drawn \(used), allocated \(text.bounds)")
                }
            }
            maximum = max(maximum, ProcessInfo.processInfo.systemUptime - begin)
        }
        guard observerConnected && observedText >= 6 && maximum < 1 else { fatalError("Offscreen chat layout stalled or did not instantiate its replies") }
        print(String(format: "Full chat offscreen scroll passed: waiting, streaming, handoff, %d native text views within card bounds, 240 scroll positions; maximum snapshot %.1f ms", observedText, maximum * 1000))
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func start() {
        lastPulse = ProcessInfo.processInfo.systemUptime
        pulse = Timer.scheduledTimer(timeInterval: 0.02, target: self, selector: #selector(measurePulse), userInfo: nil, repeats: true)
        update = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(updateResponse), userInfo: nil, repeats: true)
    }
    @objc private func measurePulse(_ timer: Timer) {
        let now = ProcessInfo.processInfo.systemUptime
        gaps.append(now - lastPulse); lastPulse = now
    }
    @objc private func updateResponse(_ timer: Timer) {
        if index == samples.count { finish(); return }
        let (run, blocks) = samples[index]
        store.runs = [run.summary]; store.selectedRun = run; store.renderedChat = blocks
        if index == 10 { store.prompt = "Please ask @" }
        if index == 20 { store.prompt = "" }
        if index == 35 { store.inspectorTab = "changes" }
        if index == 45 { store.inspectorTab = "team" }
        index += 1
    }
    private func finish() {
        pulse?.invalidate(); update?.invalidate()
        let sorted = gaps.sorted()
        let maxGap = sorted.last ?? 1
        let p95 = sorted.isEmpty ? 1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        failed = maxGap > 0.5 || p95 > 0.1 || gaps.count < 100
        print(String(format: "Responsiveness %@: %d updates, %d main-loop pulses; p95 %.1f ms, maximum %.1f ms", failed ? "FAILED" : "passed", index, gaps.count, p95 * 1000, maxGap * 1000))
        fflush(stdout)
        window?.orderOut(nil)
        NSApp.terminate(nil)
    }
}
