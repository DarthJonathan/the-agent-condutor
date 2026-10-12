import Foundation
import SwiftUI

// No window, engine or model calls. Exercise saved response compatibility and
// the inputs that keep completed cards stable when a teammate starts working.
@main enum ResponseSmoke {
    @MainActor static func main() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let usage: [String: Any] = ["input_tokens": 10, "output_tokens": 5]
        let worker = Coworker(provider: .codex, name: "Alex", mention: "alex", role: .builder)
        let peer = Coworker(provider: .codex, name: "Noah", mention: "noah", role: .reviewer)
        var record: [String: Any] = ["id": "reply", "at": "2026-10-12T06:00:00Z", "kind": "assistant", "author": "codex", "author_id": worker.id,
                                   "to": [], "text": "Completed answer", "status": "Completed", "model": "fixture-model", "logs": [], "usage": usage]
        func decode(_ value: [String: Any]) throws -> ChatMessage {
            try decoder.decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let legacy = try decode(record)
        expect(legacy.reasoning == nil, "Old saved chat messages must still decode")
        record["reasoning"] = "Provider's public summary"
        let message = try decode(record)
        expect(message.reasoning == "Provider's public summary" && message.text == "Completed answer", "Reasoning and answer must decode separately")
        let stage = try decoder.decode(Stage.self, from: JSONSerialization.data(withJSONObject: ["provider": "codex", "model": "fixture", "status": "Completed", "output": "Answer", "reasoning": "Summary", "logs": [], "usage": usage]))
        expect(stage.reasoning == "Summary" && stage.output == "Answer", "Parallel and handoff stages must retain reasoning")

        let logs = [LogEntry(at: "now", kind: "Tool", text: "Reading files")] + (0..<1000).map { _ in LogEntry(at: "now", kind: "Info", text: "System: thinking_tokens") }
            + [LogEntry(at: "now", kind: "Info", text: "Agent is reasoning"), LogEntry(at: "now", kind: "Tool", text: "Tests finished")]
        expect(visibleActivityLogs(logs).map(\.text) == ["Reading files", "Thinking…", "Tests finished"], "Saved token heartbeats must coalesce without losing tool activity")

        let blocks = responseBlocks(message.text)
        func conversation(_ messages: [ChatMessage], workers: [Coworker]) -> TaskConversation {
            TaskConversation(members: [.codex], lead: .codex, messages: messages, sessions: [], coworkers: workers, leadId: worker.id, mailbox: [])
        }
        let before = ChatMessagePresentation(message: message, conversation: conversation([message], workers: [worker, peer]), blocks: blocks)
        record["id"] = "peer-response"; record["author_id"] = peer.id; record["text"] = ""; record["status"] = "Running"
        for index in 0..<1000 {
            record["reasoning"] = "Peer progress \(index)"
            let streaming = try decode(record)
            let after = ChatMessagePresentation(message: message, conversation: conversation([message, streaming], workers: [worker, peer]), blocks: blocks)
            expect(before == after, "A teammate's stream must not invalidate the completed card")
        }
        var renamed = worker; renamed.name = "Atlas"
        let renamedCard = ChatMessagePresentation(message: message, conversation: conversation([message], workers: [renamed, peer]), blocks: blocks)
        expect(before != renamedCard && renamedCard.authorName == "Atlas", "Renaming the sender must update its card")
        record["id"] = "reply"; record["author_id"] = worker.id; record["text"] = message.text; record["status"] = "Completed"
        expect(before != ChatMessagePresentation(message: try decode(record), conversation: conversation([message], workers: [worker, peer]), blocks: blocks), "Reasoning changes must update their own card")
        expect(before != ChatMessagePresentation(message: message, conversation: conversation([message], workers: [worker, peer]), blocks: responseBlocks("New answer")), "Rendered answer changes must be displayed")

        record["question_request"] = ["id": "ask", "questions": [["id": "q", "header": "Scope", "question": "Which scope?", "options": [["id": "small", "label": "Small", "description": "Focused change"]], "multi_select": false]]]
        let waiting = try decode(record)
        var request = record["question_request"] as! [String: Any]
        request["answers"] = [["question_id": "q", "option_ids": ["small"], "text": "", "skipped": false]]
        record["question_request"] = request
        expect(waiting != (try decode(record)), "Answered question cards must invalidate")
        record["approval_request"] = ["id": "approve", "summary": "Run tests", "argv": ["cargo", "test"]]
        let pending = try decode(record)
        record["approval_request"] = ["id": "approve", "summary": "Run tests", "argv": ["cargo", "test"], "decision": true]
        expect(pending != (try decode(record)), "Approval decisions must invalidate")
        print("Response compatibility, reasoning separation, 1,000 heartbeat cleanup, stable handoff cards, rename, question and approval updates passed")
    }
    private static func expect(_ value: Bool, _ reason: String) { if !value { fatalError(reason) } }
}
