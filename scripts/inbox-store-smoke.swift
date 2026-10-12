import AppKit
import Foundation
import SwiftUI

@main
enum InboxStoreSmoke {
    @MainActor static func main() {
        do { try run() }
        catch { print("Swift Inbox/history failed: \(error)"); fflush(stdout); exit(1) }
    }
    @MainActor static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count > 1 else { fatalError("Pass the directory printed by inbox-smoke.py") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let initial = try decoder.decode(EngineEvent.self, from: Data(contentsOf: fixture.appendingPathComponent("initial-state.json")))
        let records = try decoder.decode([RunRecord].self, from: Data(contentsOf: fixture.appendingPathComponent("initial-runs.json")))
        let store = EngineStore(options: LaunchOptions())
        store.apply(initial, rendered: [:], chat: [:])
        store.connected = true
        let first = records[0], other = records[1]
        store.continueChat(first)
        expect(first.summary.attention == initial.runs?[0].attention, "Swift and Rust must agree on legacy review revisions")
        expect(store.attentionCount == 4 && store.hasPendingQuestions, "Show the saved questions, approvals and reviews")
        if CommandLine.arguments.contains("--native-preview") {
            store.screen = "attention"; try preview(store, name: "inbox-ui-preview")
            store.screen = "history"; try preview(store, name: "history-ui-preview")
            store.screen = "workspace"
        }
        let review = first.summary.attention!.first { $0.kind == "review" }!
        store.dismissAttention(run: first.summary, item: review)
        expect(store.clearingInbox && store.attentionCount == 4, "Wait for the engine's saved acknowledgement before hiding anything")
        let dismissal: [String: Any] = ["run_id": first.id, "id": review.id, "revision": review.key.revision]
        store.apply(try event("attention_dismissed", ["items": [dismissal]], decoder), rendered: [:], chat: [:])
        expect(!store.clearingInbox && store.attentionCount == 3 && store.selectedRun?.summary.attention?.count == 2, "Individual dismissal must update the list, badge and selected chat consistently")
        expect(store.hasPendingQuestions && store.selectedRun?.conversation?.pendingApprovals.count == 1, "Dismissing must never answer or approve")
        store.clearInbox()
        let clear = store.runs.flatMap { run in (run.attention ?? []).map { ["run_id": run.id, "id": $0.id, "revision": $0.key.revision] } }
        store.apply(try event("attention_dismissed", ["items": clear], decoder), rendered: [:], chat: [:])
        expect(store.attentionCount == 0 && store.hasPendingQuestions && store.selectedRun?.summary.attention?.isEmpty == true, "Clear inbox must retain the chat's pending forms")
        expect(!store.canClearInbox, "An empty inbox cannot be cleared again")

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("initial-runs.json"))) as! [[String: Any]]
        var freshJSON = raw[0]
        var conversation = freshJSON["conversation"] as! [String: Any]
        var workers = conversation["coworkers"] as! [[String: Any]]
        workers[0]["review_id"] = UUID().uuidString.lowercased()
        conversation["coworkers"] = workers
        freshJSON["conversation"] = conversation
        freshJSON["dismissed_attention"] = (store.selectedRun?.dismissedAttention ?? []).map { ["id": $0.id, "revision": $0.revision] }
        let fresh = try decoder.decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: freshJSON))
        store.apply(try event("run_updated", ["run": freshJSON], decoder), rendered: [:], chat: [:])
        expect(store.attentionCount == 1, "A new completed review must reappear")
        store.apply(try event("attention_dismissed", ["items": [dismissal]], decoder), rendered: [:], chat: [:])
        expect(store.attentionCount == 1 && store.selectedRun?.summary.attention == fresh.summary.attention, "An old clear cannot hide the new review")
        let newReview = fresh.summary.attention!.first { $0.kind == "review" }!
        store.apply(try event("attention_dismissed", ["items": [["run_id": first.id, "id": newReview.id, "revision": newReview.key.revision]]], decoder), rendered: [:], chat: [:])
        store.apply(try event("attention_dismissed", ["items": [dismissal]], decoder), rendered: [:], chat: [:])
        expect(store.attentionCount == 0 && store.selectedRun?.summary.attention?.isEmpty == true, "A delayed old acknowledgement cannot undo a newer saved dismissal")

        var active = fresh.summary
        active = RunSummary(id: active.id, title: active.title, workspace: active.workspace, workflow: active.workflow, createdAt: active.createdAt, status: .running, providers: active.providers, totalTokens: active.totalTokens)
        expect(!store.canDeleteRun(active), "Live work must be stopped before deletion")
        store.requestDeleteRun(fresh.summary)
        expect(store.chatToDelete?.id == first.id, "Requesting delete must present a confirmation")
        store.chatToDelete = nil
        expect(store.runs.count == 2, "Cancelling confirmation must preserve history")
        store.prompt = "Keep my draft"
        store.deleteRun(other.summary)
        expect(store.deletingRuns.contains(other.id) && store.runs.count == 2, "Keep a chat until deletion is saved")
        store.apply(try event("run_deleted", ["run_id": other.id], decoder), rendered: [:], chat: [:])
        expect(store.selectedRunID == first.id && store.prompt == "Keep my draft" && store.runs.count == 1, "Deleting another chat must preserve the active selection and draft")
        store.screen = "history"
        store.shareTaskID = first.id; store.isolationMode = "share_task"
        store.focusedMessageID = "old-focus"; store.setTranscriptReadingHistory(true)
        store.deleteRun(fresh.summary)
        store.apply(try event("run_deleted", ["run_id": first.id], decoder), rendered: [:], chat: [:])
        expect(store.runs.isEmpty && store.attentionCount == 0 && store.selectedRun == nil && store.selectedRunID == nil && store.composingNewTask, "Deleting the selected chat must clear history, Inbox and selection")
        expect(store.screen == "history" && store.focusedMessageID == nil && !store.transcriptReadingHistory && store.shareTaskID.isEmpty && store.isolationMode == "shared", "Clear deleted chat navigation, rendering and shared-task references")
        store.apply(try event("run_detail", ["run": freshJSON], decoder), rendered: [:], chat: [:])
        expect(store.runs.isEmpty, "Delayed detail cannot resurrect deleted history")

        // Buffered rendering snapshots must also yield to a deletion.
        var seen: [String] = []
        let delivery = EventDelivery { event, _, _ in seen.append(event.type) }
        delivery.setScrolling(true)
        delivery.enqueue(try event("run_updated", ["run": freshJSON], decoder))
        delivery.enqueue(try event("run_deleted", ["run_id": first.id], decoder))
        let deadline = Date().addingTimeInterval(2)
        while !seen.contains("run_deleted") && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        delivery.enqueue(try event("run_detail", ["run": freshJSON], decoder))
        delivery.setScrolling(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        expect(seen == ["run_deleted"], "A deletion must invalidate held and late transcript updates")
        let large = EngineStore(options: LaunchOptions())
        large.apply(initial, rendered: [:], chat: [:]); large.connected = true
        large.runs = [first.summary]
        large.runs[0].attention = (0..<1001).map { index in
            AttentionItem(id: "question-\(index)", messageId: nil, ownerId: nil, kind: "question", title: "Question \(index)")
        }
        large.clearInbox()
        let all = large.runs[0].attention!.map { ["run_id": first.id, "id": $0.id, "revision": $0.key.revision] }
        large.apply(try event("attention_dismissed", ["items": Array(all.prefix(500))], decoder), rendered: [:], chat: [:])
        expect(large.clearingInbox && large.attentionCount == 501, "Large clears stay pending until every saved batch arrives")
        large.apply(try event("attention_dismissed", ["items": Array(all.dropFirst(500).prefix(500))], decoder), rendered: [:], chat: [:])
        large.apply(try event("attention_dismissed", ["items": Array(all.suffix(1))], decoder), rendered: [:], chat: [:])
        expect(!large.clearingInbox && large.attentionCount == 0, "Large history must clear beyond one request")
        print("Swift Inbox/history passed: engine/model parity, durable acknowledgement, pending forms, fresh review, confirmation, selected/unselected deletion, navigation cleanup and delayed-render protection.")
    }
    static func event(_ type: String, _ fields: [String: Any], _ decoder: JSONDecoder) throws -> EngineEvent {
        var value = fields; value["type"] = type
        return try decoder.decode(EngineEvent.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static func expect(_ result: @autoclosure () -> Bool, _ reason: String) {
        if !result() { print("Swift Inbox/history failed: \(reason)"); fflush(stdout); exit(1) }
    }
    @MainActor static func preview(_ store: EngineStore, name: String) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 940), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView().environmentObject(store).environment(\.colorScheme, .dark).tint(Theme.accent))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 940)
        window.contentView = host
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No native bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "target/\(name).png"))
        window.close()
    }
}
