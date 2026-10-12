import AppKit
import SwiftUI

// Draw the real, completed chat at Retina scale in a never-ordered window.
// This exercises card decoration and offscreen replies, not just text sizing.
@main enum CompletedScrollSmoke {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = EngineStore(options: LaunchOptions())
        let workspace = FileManager.default.currentDirectoryPath
        store.settings.workspace = workspace; store.settings.workspaceFolders = [workspace]
        store.settings.workflow = .conversation; store.settings.chatIntroduced = true
        store.agents = Provider.allCases.map { AgentInfo(provider: $0, status: "ready", label: "Fixture", detail: "Fixture") }
        let workers = [Coworker(provider: .claude, name: "Maya", mention: "maya", role: .architect),
                       Coworker(provider: .codex, name: "Alex", mention: "alex", role: .builder)]
        let fixture = try String(contentsOfFile: "scripts/fixtures/markdown-response.md", encoding: .utf8)
        let reply = fixture + "\n\n" + (0..<120).map { index in
            "### Finding \(index + 1)\n\nThe builder should keep the change scoped to the requested task, verify the affected behavior, and send the reviewer the relevant files and test results. The reviewer can reply in its own session before the lead continues.\n\n```swift\nlet result = await coworker.review(files: changedFiles)\nassert(result.isComplete)\n```"
        }.joined(separator: "\n\n")
        let usage = Usage(inputTokens: 10, outputTokens: 10, costUsd: nil)
        let at = "2026-10-12T10:00:00Z"
        var messages: [ChatMessage] = []
        for step in 0..<12 {
            messages.append(ChatMessage(id: "user-\(step)", at: at, kind: "user", author: nil, to: [], text: "Review the previous result.", status: .completed, model: "", sessionId: nil, logs: [], usage: usage, error: nil))
            var message = ChatMessage(id: "reply-\(step)", at: at, kind: "assistant", author: workers[step % 2].provider, to: [], text: reply, status: .completed, model: "fixture-model", sessionId: nil, logs: [], usage: usage, error: nil)
            message.authorId = workers[step % 2].id
            messages.append(message)
        }
        var run = RunRecord(id: "completed-chat", prompt: "Review completed replies", workspace: workspace, workflow: .conversation, createdAt: at, finishedAt: at, status: .completed, stages: [])
        run.conversation = TaskConversation(members: [.claude, .codex], lead: .claude, messages: messages, sessions: [], coworkers: workers, leadId: workers[0].id, mailbox: [])
        store.loaded = true; store.connected = true
        store.runs = [run.summary]; store.continueChat(run)
        store.focusedMessageID = "user-0"
        store.renderedChat = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, responseBlocks($0.text)) })
        let host = NSHostingView(rootView: RootView().environmentObject(store).environment(\.colorScheme, .dark).tint(Theme.accent))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let hiddenWindow = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        hiddenWindow.contentView = host
        defer { withExtendedLifetime(hiddenWindow) {} }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        host.layoutSubtreeIfNeeded()
        guard !hiddenWindow.isVisible,
              let observer = descendants(host).compactMap({ $0 as? TranscriptScrollObserverView }).first,
              let scroll = observer.enclosingScrollView, let document = scroll.documentView,
              document.bounds.height > scroll.contentView.bounds.height * 20 else { fatalError("Missing long completed transcript") }
        let texts = descendants(host).compactMap { $0 as? ResponseTextView }
        let passes = texts.map(\.layoutPasses)
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(scroll.bounds.width * scale), pixelsHigh: Int(scroll.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Missing viewport bitmap") }
        bitmap.size = scroll.bounds.size
        print("Completed transcript: \(messages.count) cards, \(reply.utf8.count / 1024) KB per reply, document \(document.bounds.size), \(texts.count) native text views")
        if CommandLine.arguments.contains("--layers") {
            for view in descendants(host).filter({ $0.frame.height > 2000 }) {
                print("\(type(of: view)): frame \(view.frame.size), visible \(view.visibleRect.size), layer \(view.layer?.bounds.size ?? .zero), wantsLayer \(view.wantsLayer)")
            }
        }
        var frames: [Double] = []
        let count = CommandLine.arguments.contains("--profile") ? 300 : 90
        for step in 0..<count {
            let fraction = CGFloat(step % 90) / 89
            let y = (step / 90).isMultiple(of: 2) ? fraction : 1 - fraction
            let begin = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y * max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
            let nearBottom = TranscriptScrollObserverView.isNearBottom(scroll)
            guard store.transcriptReadingHistory == !nearBottom else { fatalError("The real chat must hold rendering while reading older replies and resume at Latest") }
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            }
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            frames.append((ProcessInfo.processInfo.systemUptime - begin) * 1000)
        }
        guard texts.map(\.layoutPasses) == passes else { fatalError("Scrolling measured completed replies again") }
        guard store.focusedMessageID == nil else { fatalError("Returning to Latest must clear an older Inbox navigation target") }
        let sorted = frames.sorted()
        print(String(format: "Completed chat Retina drawing: %d frames; mean %.2f ms, p95 %.2f ms, maximum %.2f ms", count, frames.reduce(0, +) / Double(count), sorted[Int(Double(count - 1) * 0.95)], sorted.last!))
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: "target/completed-scroll-preview.png")) }
        // Bounds tracking must not mistake layout growth or programmatic
        // following for the reader scrolling away from the latest message.
        store.focusedMessageID = nil
        let last = messages.count - 1
        for step in 1...12 {
            var active = ChatMessage(id: messages[last].id, at: at, kind: "assistant", author: messages[last].author, to: [], text: String(reply.prefix(step * 1500)), status: .running, model: "fixture-model", sessionId: nil, logs: [], usage: usage, error: nil)
            active.authorId = messages[last].authorId
            var updatedMessages = messages
            updatedMessages[last] = active
            var updatedRun = RunRecord(id: run.id, prompt: run.prompt, workspace: workspace, workflow: .conversation, createdAt: at, finishedAt: nil, status: .running, stages: [])
            updatedRun.conversation = TaskConversation(members: [.claude, .codex], lead: .claude, messages: updatedMessages, sessions: [], coworkers: workers, leadId: workers[0].id, mailbox: [])
            store.selectedRun = updatedRun
            store.renderedChat[active.id] = responseBlocks(active.text)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            host.layoutSubtreeIfNeeded()
            guard !store.transcriptReadingHistory, TranscriptScrollObserverView.isNearBottom(scroll) else { fatalError("Rendering a growing reply must keep automatic following enabled at Latest") }
        }
        print("Full chat following passed: 12 growing reply updates stayed at Latest; older-reply viewport movement paused delivery without live-scroll notifications")
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
