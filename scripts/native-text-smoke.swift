import AppKit
import SwiftUI

// Exercise TextKit and an offscreen hosting/scroll hierarchy. No visible window,
// desktop events, engine, credentials or production state are involved.
@main enum NativeTextSmoke {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fixture = try String(contentsOfFile: "scripts/fixtures/markdown-response.md", encoding: .utf8)
        let document = ResponseDocument.markdown(responseBlocks(fixture))
        let formatted = NativeResponseFormatter.format(document)
        var cells: [(NSRange, NSTextTableBlock, NSTextAlignment)] = []
        var links: [URL] = []
        var mono = false
        var strike = false
        formatted.enumerateAttributes(in: NSRange(location: 0, length: formatted.length)) { attributes, range, _ in
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle,
               let cell = paragraph.textBlocks.first as? NSTextTableBlock {
                if !cells.contains(where: { $0.1 === cell }) { cells.append((range, cell, paragraph.alignment)) }
            }
            if let link = attributes[.link] as? URL { links.append(link) }
            if let font = attributes[.font] as? NSFont, font.fontDescriptor.symbolicTraits.contains(.monoSpace) { mono = true }
            if attributes[.strikethroughStyle] != nil { strike = true }
        }
        expect(cells.count == 21, "The seven-row, three-column table must use native table cells")
        expect(cells.filter { $0.1.startingColumn == 2 }.allSatisfy { $0.2 == .center }, "Cell alignment must survive native formatting")
        expect(links.contains(URL(string: "https://example.com/docs")!), "Links must remain clickable")
        expect(mono && strike, "Inline code, fenced code and strikethrough must retain formatting")
        expect(formatted.string.contains("1.\tInspect") && formatted.string.contains("☑\tPreserve"), "Ordered and task list markers must render")
        expect(formatted.string.contains("    println!(\"Hello from Conductor\");"), "Code indentation must survive")
        expect(!formatted.string.contains("| Agent |"), "Tables must not display raw Markdown delimiters")

        let text = ResponseTextView()
        text.appearance = NSAppearance(named: .darkAqua)
        expect(text.apply(document), "The first document must be installed")
        let wide = text.measuredSize(width: 760)
        let narrow = text.measuredSize(width: 340)
        expect(narrow.height > wide.height && wide.height > 500, "Tables and text must wrap to the available width")
        text.setFrameSize(narrow)
        verifyDrawnBounds([text], label: "narrow table")
        text.setFrameSize(wide)
        verifyDrawnBounds([text], label: "wide table")
        let selection = NSRange(location: 15, length: 20)
        text.setSelectedRange(selection)
        let passes = text.layoutPasses
        for _ in 0..<1000 {
            expect(!text.apply(document), "Unchanged cards must keep their native text storage")
            expect(text.measuredSize(width: 760) == wide && text.measuredSize(width: 340) == narrow, "Cached measurements must stay stable")
        }
        expect(text.layoutPasses == passes && text.selectedRange() == selection, "Scrolling must not relayout unchanged text or reset selection")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        guard let layout = text.layoutManager, let container = text.textContainer else { fatalError("Missing TextKit layout") }
        layout.ensureLayout(for: container)
        let header = cells.filter { $0.1.startingRow == 0 }.sorted { $0.1.startingColumn < $1.1.startingColumn }
        let positions = header.map { layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: $0.0, actualCharacterRange: nil), in: container).minX }
        expect(positions[0] < positions[1] && positions[1] < positions[2], "Table columns must occupy separate horizontal positions")
        if let bitmap = text.bitmapImageRepForCachingDisplay(in: text.bounds) {
            text.cacheDisplay(in: text.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "target/native-markdown-preview.png"))
            }
        }
        print("Native Markdown passed: tables, alignment, lists, links, code, selection and 1,000 cached measurements")
        try verifyStreamingBounds(fixture: fixture)
        try verifyScroll(fixture: fixture)
        verifyFollowState()
    }

    @MainActor private static func verifyStreamingBounds(fixture: String) throws {
        let verification = """
        ### Verification

        ```text
        inclusive: currencyCeil(t·p)

        exclusive: if t·p exactly 2dp-representable then t·p + 0.01 else currencyCeil(t·p)
        ```

        Verification against the repo: `qMin = ceil(250/102) = 2.46`, last digit 6 even → inclusive `t = 2.455` → `t·p = 250.41` representable → **min = 250.41**. Check: 250.41/102 = 2.455 exactly → HALF_EVEN → 2.46 → 250.92 > 250 ✓; 250.40 → 2.454902 → 2.45 ✗. Exactly the threshold.

        """
        let reply = verification + (0..<20).map { "Paragraph \($0): The next coworker's card must appear below the entire reply, including all wrapped lines and code block padding." }.joined(separator: "\n\n")
        let host = NSHostingView(rootView: ReplyBoundsFixture(blocks: responseBlocks("Starting…")))
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 700)
        func update(_ content: String, width: CGFloat, label: String) {
            host.rootView = ReplyBoundsFixture(blocks: responseBlocks(content))
            host.setFrameSize(NSSize(width: width, height: 700))
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
            let texts = descendants(host).compactMap { $0 as? ResponseTextView }
            expect(texts.count == 2, "The reply bounds fixture must instantiate both coworker cards")
            verifyDrawnBounds(texts, label: label)
            let first = texts[0].convert(texts[0].bounds, to: host)
            let second = texts[1].convert(texts[1].bounds, to: host)
            expect(!first.intersects(second), "Coworker replies must not overlap at \(label)")
        }
        for step in 0..<30 {
            update(String(reply.prefix(min(reply.count, (step + 1) * 140))),
                   width: step % 3 == 0 ? 560 : step % 3 == 1 ? 1200 : 780, label: "resizing stream \(step)")
        }
        for step in 0..<30 {
            update(String(fixture.prefix(min(fixture.count, (step + 1) * 50))), width: 560, label: "fixed-width table stream \(step)")
        }
        let widths: [CGFloat] = [1200, 560, 780, 432, 1200, 560]
        for width in widths {
            update(fixture + "\n\n" + reply, width: width, label: "completed reply at \(width)")
        }
        update(verification, width: 900, label: "verification preview")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "target/native-reply-bounds-preview.png"))
            }
        }
        print("Reply bounds passed: streaming, fixed-width updates and completed reply resizing; full text fits and adjacent coworker cards stay separate")
    }

    @MainActor private static func verifyDrawnBounds(_ texts: [ResponseTextView], label: String) {
        for text in texts {
            guard let layout = text.layoutManager, let container = text.textContainer else { fatalError("Missing text layout") }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            expect(used.maxY <= text.bounds.height + 1,
                   "Reply overflow at \(label): drawn height \(used.maxY), allocated height \(text.bounds.height), width \(text.bounds.width)")
            expect(used.maxX <= text.bounds.width + 1, "Reply text must stay within its allocated width at \(label)")
        }
    }

    @MainActor private static func verifyScroll(fixture: String) throws {
        let long = fixture + "\n\n" + (0..<110).map { index in
            "### Finding \(index)\n\nThe reviewer examines the builder's changes and sends findings to the architect. A completed response keeps its text layout while another coworker is working. Select text, scroll to earlier messages, and then continue the conversation."
        }.joined(separator: "\n\n")
        let blocks = responseBlocks(long)
        let views = (0..<4).map { _ -> ResponseTextView in
            let view = ResponseTextView(); view.apply(.markdown(blocks)); return view
        }
        let nativeScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 780, height: 700))
        let document = FlippedDocument(frame: .zero)
        nativeScroll.documentView = document
        var y: CGFloat = 0
        for view in views {
            let size = view.measuredSize(width: 740)
            view.frame = NSRect(x: 0, y: y, width: size.width, height: size.height)
            document.addSubview(view); y += size.height + 16
        }
        document.setFrameSize(NSSize(width: 740, height: y))
        verifyViewportTracking(scroll: nativeScroll, document: document)
        let passes = views.map(\.layoutPasses)
        let begin = ProcessInfo.processInfo.systemUptime
        for step in 0..<600 {
            nativeScroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step % 150) / 149 * max(0, y - 700)))
            nativeScroll.reflectScrolledClipView(nativeScroll.contentView)
            nativeScroll.layoutSubtreeIfNeeded()
            for view in views { _ = view.measuredSize(width: 740) }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - begin
        expect(views.map(\.layoutPasses) == passes, "Viewport movement must reuse completed native text layouts")
        expect(elapsed < 3, "600 native scroll positions must complete without a hang")
        nativeScroll.contentView.scroll(to: .zero)
        expect(!TranscriptScrollObserverView.isNearBottom(nativeScroll), "Reading old messages must pause following")
        nativeScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y - nativeScroll.contentView.bounds.height)))
        expect(TranscriptScrollObserverView.isNearBottom(nativeScroll), "Returning to the latest message must allow following")

        // Unlike ImageRenderer, this creates the actual AppKit text views in a
        // SwiftUI scroll hierarchy. Keep it entirely offscreen.
        let host = NSHostingView(rootView: NativeTranscriptFixture(blocks: blocks, tail: "Waiting for a teammate"))
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 700)
        // A hosting view needs a window to assign the scroll document's bounds.
        // Never order this fixture window onto the user's desktop.
        let hiddenWindow = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        hiddenWindow.contentView = host
        defer { withExtendedLifetime(hiddenWindow) {} }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        let hostedText = descendants(host).compactMap { $0 as? ResponseTextView }
        let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first
        expect(hostedText.count >= 4 && scroll != nil, "The offscreen SwiftUI fixture must contain real native replies and a scroll view")
        expect(!hiddenWindow.isVisible, "The scroll fixture must stay off the user's desktop")
        expect((scroll?.documentView?.bounds.height ?? 0) > 700, "The hosted fixture must have a scrollable transcript")
        let hostedPasses = hostedText.map(\.layoutPasses)
        var greatestScrollY: CGFloat = 0
        let started = ProcessInfo.processInfo.systemUptime
        for step in 0..<300 {
            if let scroll, let document = scroll.documentView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step % 100) / 99 * max(0, document.bounds.height - 700)))
                scroll.reflectScrolledClipView(scroll.contentView)
                greatestScrollY = max(greatestScrollY, scroll.contentView.bounds.origin.y)
            }
            host.layoutSubtreeIfNeeded()
        }
        let hostedTime = ProcessInfo.processInfo.systemUptime - started
        expect(greatestScrollY > 700, "The viewport must move beyond the first reply")
        expect(hostedText.map(\.layoutPasses) == hostedPasses, "Scrolling the hosted transcript must not measure completed cards again")
        expect(hostedTime < 3, "The hosted transcript must remain responsive while scrolling")
        host.rootView = NativeTranscriptFixture(blocks: blocks, tail: "A teammate has replied.\n\n" + fixture)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        expect(hostedText.prefix(4).map(\.layoutPasses) == Array(hostedPasses.prefix(4)), "A teammate update must preserve existing response layouts")
        expect(descendants(host).compactMap { $0 as? ResponseTextView }.contains { $0.string.hasPrefix("A teammate has replied.") }, "The teammate update must actually reach its native text view")
        expect(descendants(host).compactMap { $0 as? ResponseTextView }.first { $0.string.hasPrefix("A teammate has replied.") }!.bounds.height > 500, "An updated reply must grow to its new text height without clipping")
        print(String(format: "Scroll checks passed: four %.0f KB responses, 600 native positions in %.1f ms, 300 hosted positions in %.1f ms", Double(long.utf8.count) / 1024, elapsed * 1000, hostedTime * 1000))
        if CommandLine.arguments.contains("--draw-scroll") {
            try verifyDrawScroll(view: nativeScroll, scroll: nativeScroll, label: "native")
            if let scroll { try verifyDrawScroll(view: host, scroll: scroll, label: "hosted") }
        }
    }

    @MainActor private static func verifyDrawScroll(view: NSView, scroll: NSScrollView, label: String) throws {
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                           pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let document = scroll.documentView else {
            fatalError("Missing viewport to draw")
        }
        bitmap.size = view.bounds.size
        let frameCount = 60
        var frames: [TimeInterval] = []
        for step in 0..<frameCount {
            let started = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step % 60) / 59 * max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            frames.append(ProcessInfo.processInfo.systemUptime - started)
        }
        let sorted = frames.sorted()
        print(String(format: "%@ Retina drawing: %d scroll frames; mean %.1f ms, p95 %.1f ms, maximum %.1f ms", label, frameCount, frames.reduce(0, +) / Double(frames.count) * 1000, sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000, sorted.last! * 1000))
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: "target/\(label)-scroll-drawing-preview.png"))
        }
    }

    private static func verifyFollowState() {
        var state = TranscriptFollowState()
        expect(state.canFollow, "New chats start at the latest message")
        state.begin(); state.moved(nearBottom: true)
        expect(!state.canFollow, "Stream updates cannot interrupt a live user scroll")
        state.end(nearBottom: false)
        expect(!state.canFollow, "Following must remain paused while reading history")
        state.moved(nearBottom: true)
        expect(state.canFollow, "Legacy mouse scrolling back to the bottom must resume following")
        state.begin(); state.end(nearBottom: true)
        expect(state.canFollow, "Trackpad scrolling back to the bottom must resume following")
        state.jumpToLatest(); expect(state.canFollow, "Jump to latest must resume following")
        print("User-scroll priority checks passed")
    }
    @MainActor private static func verifyViewportTracking(scroll: NSScrollView, document: NSView) {
        let observer = TranscriptScrollObserverView(frame: .zero)
        document.addSubview(observer)
        var state = TranscriptFollowState()
        var movements: [Bool] = []
        observer.onEvent = { event in
            if case .moved(let nearBottom) = event {
                movements.append(nearBottom); state.moved(nearBottom: nearBottom)
            }
        }
        // No live-scroll notifications: emulate actual clip movement from a
        // mouse wheel, momentum, or dragging the scrollbar.
        for step in 1...40 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step * 10)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        expect(!state.canFollow && movements == [false], "Actual viewport movement must pause rendering without publishing for every pixel")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        expect(state.canFollow && movements == [false, true], "Returning to the latest reply must resume delivery even without a live-scroll bracket")
        observer.disconnect(); observer.removeFromSuperview()
        print("Viewport tracking passed: wheel/scrollbar movement detected, per-pixel publications avoided, Latest restored")
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private static func expect(_ value: @autoclosure () -> Bool, _ reason: String) { if !value() { fatalError(reason) } }
}

private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }

private struct NativeTranscriptFixture: View {
    let blocks: [ResponseBlock]
    let tail: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(0..<4) { _ in NativeResponseText(blocks: blocks).padding(16) }
                NativeResponseText(text: tail).padding(16)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(red: 0.065, green: 0.07, blue: 0.075)).environment(\.colorScheme, .dark)
    }
}

private struct ReplyBoundsFixture: View {
    let blocks: [ResponseBlock]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ivy").font(.headline)
                    NativeResponseText(blocks: blocks).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(16).background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Eva  Codex → Ivy").font(.headline)
                    NativeResponseText(text: "Teammate reply")
                }.padding(16).background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(red: 0.065, green: 0.07, blue: 0.075)).environment(\.colorScheme, .dark)
    }
}
