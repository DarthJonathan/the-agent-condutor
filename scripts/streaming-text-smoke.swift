import AppKit
import Foundation

// Synthetic replies only: no window, desktop events, engine or credentials.
@main enum StreamingTextSmoke {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let fixture = try String(contentsOfFile: "scripts/fixtures/markdown-response.md", encoding: .utf8)
        let prefix = fixture + "\n\n" + (0..<110).map {
            "### Finding \($0)\n\nKeep completed paragraphs and their native layout while the agent writes its next finding. A teammate can continue working in a separate session while you read and scroll through this reply."
        }.joined(separator: "\n\n")
        let snapshots = (0..<120).map { responseBlocks(prefix + "\n\nLive finding: " + String(repeating: "additional detail ", count: $0 + 1)) }
        let text = ResponseTextView()
        text.apply(.markdown(snapshots[0]))
        text.setFrameSize(text.measuredSize(width: 740))
        let table = firstTable(in: text)
        expect(table != nil, "The streaming fixture must contain a real native table")
        let selection = NSRange(location: 15, length: 20)
        text.setSelectedRange(selection)
        var times: [TimeInterval] = []
        for blocks in snapshots.dropFirst() {
            let started = ProcessInfo.processInfo.systemUptime
            text.apply(.markdown(blocks))
            text.setFrameSize(text.measuredSize(width: 740))
            times.append(ProcessInfo.processInfo.systemUptime - started)
            expect(text.string == NativeResponseFormatter.format(.markdown(blocks)).string, "Streaming must display the entire latest answer")
            expect(text.selectedRange() == selection, "Updates below a selection must preserve it")
            if !CommandLine.arguments.contains("--baseline") { expect(firstTable(in: text) === table, "An unchanged table must keep its native formatting and layout") }
        }
        let sorted = times.sorted()
        print(String(format: "Streaming native updates: 119 growing replies with a %.0f KB prefix; mean %.2f ms, p95 %.2f ms, maximum %.2f ms", Double(prefix.utf8.count) / 1024, times.reduce(0, +) / Double(times.count) * 1000, sorted[112] * 1000, sorted.last! * 1000))

        // Rewrite earlier text, close inline markup, grow a large code block,
        // change Unicode clusters, shrink the reply and switch text styles.
        let rewrites = ["**bold** and *italic*", "**bold** and *italic* with [a link](https://example.com)",
                        "A changed opening paragraph.\n\n" + fixture, "Emoji 🧑🏽‍💻 and e\u{301}", "Emoji 🧑‍💻 and é",
                        "```swift\n" + String(repeating: "let value = 42\n", count: 600),
                        "```swift\n" + String(repeating: "let value = 42\n", count: 600) + "print(value)\n```", "Short reply"]
        for content in rewrites {
            let document = ResponseDocument.markdown(responseBlocks(content))
            text.apply(document)
            text.setFrameSize(text.measuredSize(width: 340))
            verifyFormat(text, expected: NativeResponseFormatter.format(document))
            guard let layout = text.layoutManager, let container = text.textContainer else { fatalError("Missing layout") }
            layout.ensureLayout(for: container)
            expect(layout.usedRect(for: container).maxY <= text.bounds.height + 1, "Incremental edits must retain the full measured height")
        }
        for document in [ResponseDocument.plain("A growing summary 🧑", size: 12, tone: .secondary),
                         .plain("A growing summary 🧑🏽‍💻", size: 12, tone: .secondary),
                         .plain("A growing summary 🧑🏽‍💻", size: 15, tone: .error), .plain("", size: 12, tone: .primary)] {
            text.apply(document)
            verifyFormat(text, expected: NativeResponseFormatter.format(document))
        }
        print("Streaming format checks passed: unchanged table, selection, rewritten markup, long code, Unicode, shrinking and style changes")
    }

    @MainActor private static func firstTable(in text: ResponseTextView) -> NSTextTable? {
        var table: NSTextTable?
        text.textStorage?.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) { value, _, stop in
            if let paragraph = value as? NSParagraphStyle, let cell = paragraph.textBlocks.first as? NSTextTableBlock {
                table = cell.table; stop.pointee = true
            }
        }
        return table
    }
    @MainActor private static func verifyFormat(_ text: ResponseTextView, expected: NSAttributedString) {
        guard let actual = text.textStorage else { fatalError("Missing text storage") }
        let expected = NSTextStorage(attributedString: expected)
        expected.fixAttributes(in: NSRange(location: 0, length: expected.length))
        expect(actual.string == expected.string, "Incremental formatting must match a fresh document")
        var index = 0
        while index < actual.length {
            var lhsRange = NSRange(), rhsRange = NSRange()
            let lhs = actual.attributes(at: index, effectiveRange: &lhsRange)
            let rhs = expected.attributes(at: index, effectiveRange: &rhsRange)
            for key in [NSAttributedString.Key.font, .foregroundColor, .backgroundColor, .link, .strikethroughStyle] {
                let left = lhs[key].map { NSDictionary(dictionary: [key: $0]) } ?? NSDictionary()
                let right = rhs[key].map { NSDictionary(dictionary: [key: $0]) } ?? NSDictionary()
                expect(left.isEqual(right), "Streaming must preserve \(key.rawValue) at character \(index)")
            }
            if let left = lhs[.paragraphStyle] as? NSParagraphStyle, let right = rhs[.paragraphStyle] as? NSParagraphStyle {
                expect(left.alignment == right.alignment && left.headIndent == right.headIndent && left.firstLineHeadIndent == right.firstLineHeadIndent && left.lineSpacing == right.lineSpacing && left.paragraphSpacing == right.paragraphSpacing && left.textBlocks.count == right.textBlocks.count, "Streaming must preserve paragraph and block formatting")
            }
            index = min(NSMaxRange(lhsRange), NSMaxRange(rhsRange))
        }
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ reason: String) { if !value() { fatalError(reason) } }
}
