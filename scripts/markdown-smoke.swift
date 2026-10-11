import AppKit
import SwiftUI

@main
enum MarkdownSmoke {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixture = try String(contentsOf: root.appendingPathComponent("scripts/fixtures/markdown-response.md"), encoding: .utf8)
        let blocks = responseBlocks(fixture)
        let flat = flatten(blocks)
        let table = flat.first { if case .table = $0.kind { return true }; return false }!
        expect(table.children.count == 7, "The six-agent example must form one table with a header and six rows")
        if case .table(let columns) = table.kind {
            expect(columns == [.left, .left, .center], "Table alignment must survive parsing")
        }
        expect(table.children[1].children.map(\.text) == ["Claude", "Claude Code CLI (claude --print, headless)", "Ready"], "Cells must preserve their text without raw delimiters")
        expect(table.children[1].children[0].content.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Bold formatting must survive inside table cells")
        expect(table.children[1].children[1].content.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "Inline code must survive inside table cells")
        let numbered = flat.compactMap { block -> Int? in if case .listItem(let number, _) = block.kind { return number }; return nil }
        expect(numbered == [1, 2], "Ordered lists must keep separate items and numbers")
        let list = flat.first { if case .listItem(number: 1, checked: nil) = $0.kind { return true }; return false }!
        expect(list.children.contains { if case .list = $0.kind { return true }; return false }, "Nested lists must stay inside their parent item")
        let tasks = flat.compactMap { block -> Bool? in if case .listItem(_, let checked) = block.kind { return checked }; return nil }
        expect(tasks == [true, false], "Task lists must preserve their checked state")
        expect(flat.contains { if case .text = $0.kind { return $0.text == "Preserve the conversation." }; return false }, "Checkbox markers must be separated from task text")
        expect(flat.contains { if case .quote = $0.kind { return $0.children.count == 2 }; return false }, "Quotes must retain their paragraphs")
        expect(flat.contains { if case .divider = $0.kind { return true }; return false }, "Thematic breaks must render as dividers")
        let code = flat.first { if case .code(language: "rust") = $0.kind { return true }; return false }!
        expect(code.text == "fn main() {\n    println!(\"Hello from Conductor\");\n}\n", "Code must retain its exact indentation and punctuation")
        let inline = flat.last!
        expect(inline.content.runs.contains { $0.link?.absoluteString == "https://example.com/docs" }, "Links must retain their URL")
        expect(inline.content.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true }, "Strikethrough must retain inline formatting")

        let escaped = responseBlocks("| A | B |\n| --- | --- |\n| left\\|right | `a\\|b` |\n| lone |\n")
        let escapedTable = escaped.first!
        expect(escapedTable.children[1].children.map(\.text) == ["left|right", "a|b"], "Escaped pipes must stay inside cells, including inline code")
        expect(escapedTable.children[2].children.first?.text == "lone", "A short row must keep its existing cell")
        expect(!responseBlocks("| A | B |\n| not a separator | row |\n").contains { if case .table = $0.kind { return true }; return false }, "Ordinary pipes must not be mistaken for a table")
        let fenced = responseBlocks("~~~text\n| A | B |\n| --- | --- |\n```\n~~~\n")
        expect(fenced.count == 1 && fenced[0].text.contains("```"), "Tables and alternate fences inside code must stay literal")
        let unclosed = responseBlocks("```swift\nlet greeting = \"hello\"\n")
        expect(unclosed.count == 1 && unclosed[0].text == "let greeting = \"hello\"\n", "An incomplete streamed fence must already render as code")
        expect(responseBlocks("#hashtag").first?.text == "#hashtag", "A hashtag must not be mistaken for a heading")
        expect(responseBlocks("Setext heading\n===\n").contains { if case .heading(1) = $0.kind { return true }; return false }, "Setext headings must render as headings")
        let ordered = flatten(responseBlocks("3. Third\n4. Fourth\n"))
        expect(ordered.contains { if case .listItem(number: 3, checked: nil) = $0.kind { return true }; return false }, "Lists starting after one must keep their actual number")
        for length in 1...fixture.count {
            let partial = responseBlocks(String(fixture.prefix(length)))
            expect(!partial.isEmpty, "Every streamed prefix must retain displayable content")
        }
        print("Markdown checks passed: tables, alignment, escaped pipes, nested and numbered lists, tasks, quotes, dividers, links, inline formatting, code, and streamed prefixes")

        if CommandLine.arguments.contains("--render") {
            let store = EngineStore(options: LaunchOptions())
            let content = VStack(alignment: .leading, spacing: 15) {
                ForEach(blocks) { ResponseBlockContent(block: $0) }
            }.padding(28).frame(width: 760, alignment: .leading).background(Theme.panel)
                .environmentObject(store).environment(\.colorScheme, .dark).tint(Theme.accent)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Markdown layout rendering failed") }
            let destination = root.appendingPathComponent("target/markdown-preview.png")
            try data.write(to: destination)
            print("Rendered \(destination.path)")
        }
    }
    private static func flatten(_ blocks: [ResponseBlock]) -> [ResponseBlock] { blocks.flatMap { [$0] + flatten($0.children) } }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
}
