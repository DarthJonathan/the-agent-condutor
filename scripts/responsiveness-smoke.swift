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
        for frame in 0..<60 {
            var messages: [ChatMessage] = []
            for step in 0..<3 {
                messages.append(ChatMessage(id: "user-\(step)", at: at, kind: "user", author: nil, to: [], text: "Review the project and discuss the approach.", status: .completed, model: "", sessionId: nil, logs: [], usage: usage, error: nil))
                var message = ChatMessage(id: "reply-\(step)", at: at, kind: "assistant", author: workers[step].provider, to: [], text: fixture, status: .completed, model: "fixture-model", sessionId: nil, logs: [], usage: usage, error: nil)
                message.authorId = workers[step].id; messages.append(message)
            }
            var active = ChatMessage(id: "stream", at: at, kind: "assistant", author: .claude, to: [], text: frame < 20 ? "" : String(fixture.prefix((frame - 19) * 65)), status: .running, model: "fixture-model", sessionId: nil, logs: [], usage: usage, error: nil)
            active.authorId = workers[0].id; messages.append(active)
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
        print("Timing native chat layout at 1050 × 740"); fflush(stdout)
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
