import AppKit
import SwiftUI

// Exercise the real parse/delivery boundary without a window, engine or model.
@main enum RendererDeliverySmoke {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let renderer = EventRenderer()
        let gate = RenderGate()
        var received: [String] = []
        var renderedText: [String] = []
        let delivery = EventDelivery(render: { event in
            expect(!Thread.isMainThread, "Markdown parsing must run off the main thread")
            gate.waitIfNeeded(event.run?.prompt ?? "")
            return renderer.render(event)
        }) { event, _, chat in
            expect(Thread.isMainThread, "UI snapshots must arrive on the main thread")
            received.append(event.run?.prompt ?? event.type)
            renderedText.append(chat["live"]?.map { String($0.content.characters) }.joined() ?? "")
        }
        delivery.enqueue(try event("seed"))
        pump { received.last == "seed" }
        expect(renderer.parsedDocuments == 2, "The initial frame must parse both messages")

        var reader = TranscriptFollowState()
        reader.begin(); delivery.setScrolling(!reader.canFollow)
        for index in 0..<1000 { delivery.enqueue(try event("token-\(index)")) }
        // The gesture ends above the latest reply. Pausing between gestures
        // must not start parsing or updating a reply which is offscreen.
        reader.end(nearBottom: false); delivery.setScrolling(!reader.canFollow)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        expect(received == ["seed"] && renderer.parsedDocuments == 2, "Reading old replies must defer both parsing and UI updates after the gesture ends")
        reader.jumpToLatest(); delivery.setScrolling(!reader.canFollow)
        pump { received.last == "token-999" }
        expect(renderer.parsedDocuments == 3 && renderedText.last == "token-999", "Returning to Latest must parse and deliver only the newest reply")

        // New packets must coalesce while parsing is slow; do not build an
        // unbounded queue of expensive Markdown jobs behind the current frame.
        gate.arm("in-flight")
        delivery.enqueue(try event("in-flight"))
        pump { gate.started }
        delivery.setScrolling(true)
        for index in 0..<1000 { delivery.enqueue(try event("queued-\(index)")) }
        gate.release()
        pump { gate.finished }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        expect(received.last == "token-999", "An in-flight render must yield when history reading starts")
        delivery.setScrolling(false)
        pump { received.last == "queued-999" }
        expect(!received.contains("in-flight") && renderer.parsedDocuments == 5, "Slow rendering must retain only the newest pending frame")

        delivery.setScrolling(true)
        delivery.enqueue(try event("before-question"))
        delivery.enqueue(try event("question", question: true))
        pump { received.last == "question" }
        expect(Array(received.suffix(2)) == ["before-question", "question"], "Questions must flush preceding progress and arrive during history reading")
        delivery.enqueue(try event("approval", approval: true))
        pump { received.last == "approval" }
        delivery.enqueue(try event("finished", status: "Completed"))
        pump { received.last == "finished" }
        delivery.setScrolling(false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        expect(received.last == "finished", "Completion must not be followed by stale active output")

        // A terminal event can arrive while a progress parse is in flight.
        delivery.enqueue(try event("resumed"))
        pump { received.last == "resumed" }
        gate.arm("cancel-race")
        delivery.enqueue(try event("cancel-race"))
        pump { gate.started }
        delivery.setScrolling(true)
        delivery.enqueue(try event("cancelled", status: "Cancelled"))
        gate.release()
        pump { received.last == "cancelled" }
        delivery.setScrolling(false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        expect(!received.contains("cancel-race") && received.last == "cancelled", "Cancellation must invalidate an unfinished progress render")

        // Cache entries belong to chats, even when their connection is shared.
        let cached = EventRenderer()
        let first = try event("first", id: "one")
        let second = try event("second", id: "two")
        let queue = DispatchQueue(label: "renderer-cache-fixture")
        queue.sync {
            for _ in 0..<100 { _ = cached.render(first); _ = cached.render(second) }
        }
        expect(cached.parsedDocuments == 4, "Interleaved chats must preserve separate response caches")
        print("Renderer delivery passed: 2,000 progress packets coalesced before parsing, history reading held across gestures, Latest caught up once, in-flight renders yielded, questions/approvals/completion/cancellation preserved, interleaved chats cached")
    }
    private static func event(_ text: String, status: String = "Running", id: String = "render-chat", question: Bool = false, approval: Bool = false) throws -> EngineEvent {
        let usage: [String: Any] = ["input_tokens": 0, "output_tokens": 0]
        let user: [String: Any] = ["id": "user", "at": "now", "kind": "user", "to": [], "text": "Review the project", "status": "Completed", "model": "", "logs": [], "usage": usage]
        var live: [String: Any] = ["id": "live", "at": "now", "kind": "assistant", "author": "claude", "to": [], "text": text, "status": question || approval ? "WaitingForUser" : status, "model": "fixture", "logs": [], "usage": usage]
        if question { live["question_request"] = ["id": "scope", "questions": [["id": "scope", "header": "Scope", "question": "Which scope?", "options": [], "multi_select": false]]] }
        if approval { live["approval_request"] = ["id": "check", "summary": "Run checks?", "argv": ["cargo", "test"]] }
        let run: [String: Any] = ["id": id, "prompt": text, "workspace": "/fixture", "workflow": "Conversation", "created_at": "now", "status": status, "stages": [], "conversation": ["members": ["claude"], "lead": "claude", "messages": [user, live], "sessions": []]]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(EngineEvent.self, from: JSONSerialization.data(withJSONObject: ["type": "run_updated", "run": run]))
    }
    @MainActor private static func pump(until predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002)) }
        expect(predicate(), "Timed out waiting for an asynchronous render")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
}

// Test synchronization is lock protected; only the background renderer waits.
private final class RenderGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var token = ""
    private var began = false
    private var ended = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return began }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    func arm(_ text: String) { lock.lock(); token = text; began = false; ended = false; lock.unlock() }
    func waitIfNeeded(_ text: String) {
        lock.lock()
        let matching = token == text
        if matching { began = true }
        lock.unlock()
        if matching {
            guard semaphore.wait(timeout: .now() + 3) == .success else { fatalError("Test render gate timed out") }
            lock.lock(); ended = true; token = ""; lock.unlock()
        }
    }
    func release() { semaphore.signal() }
}
