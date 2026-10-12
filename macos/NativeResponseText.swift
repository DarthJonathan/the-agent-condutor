import AppKit
import SwiftUI

// One native text view per response. SwiftUI owns the card and its controls;
// TextKit owns wrapping, tables and selection, without a selection overlay for
// every Markdown paragraph or a geometry/preference height feedback loop.
enum ResponseDocument: Equatable {
    enum Tone: Equatable { case primary, secondary, error }
    case markdown([ResponseBlock])
    case plain(String, size: CGFloat, tone: Tone)
}

struct NativeResponseText: NSViewRepresentable {
    let document: ResponseDocument
    init(blocks: [ResponseBlock]) { document = .markdown(blocks) }
    init(text: String, size: CGFloat = 12, tone: ResponseDocument.Tone = .primary) {
        document = .plain(text, size: size, tone: tone)
    }
    func makeNSView(context: Context) -> ResponseTextView {
        let view = ResponseTextView()
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        view.apply(document)
        return view
    }
    func updateNSView(_ view: ResponseTextView, context: Context) {
        let appearance: NSAppearance.Name = context.environment.colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != appearance { view.appearance = NSAppearance(named: appearance) }
        view.apply(document)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResponseTextView, context: Context) -> CGSize? {
        // SwiftUI probes the minimum width as well as the available width.
        // Laying out a long document one character per line during that probe
        // creates enormous, unused glyph layouts.
        if proposal.width == 0 { return .zero }
        // SwiftUI can measure before updateNSView. Install this version of the
        // response first so the size always describes the current message.
        nsView.apply(document)
        return nsView.measuredSize(width: proposal.width ?? 640)
    }
}

@MainActor
final class ResponseTextView: NSTextView {
    private var document: ResponseDocument?
    private var fragments: [NSAttributedString] = []
    private var measurements: [CGFloat: CGFloat] = [:]
    // Measure with an independent container. The attached NSTextView still has
    // its previous frame during SwiftUI's sizing pass; TextKit's code/table
    // blocks can otherwise wrap to that old width and underestimate the height.
    // Both layouts share the same text storage, keeping content and styles equal.
    private let measuringLayout = NSLayoutManager()
    private let measuringContainer = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
    private(set) var layoutPasses = 0

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.backgroundLayoutEnabled = false
        let container = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        measuringLayout.backgroundLayoutEnabled = false
        measuringContainer.widthTracksTextView = false
        measuringContainer.heightTracksTextView = false
        measuringContainer.lineFragmentPadding = 0
        storage.addLayoutManager(measuringLayout)
        measuringLayout.addTextContainer(measuringContainer)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        clipsToBounds = true
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        focusRingType = .none
        linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel("Message text")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The representable supplies the exact size. Do not resize the NSTextView
    // or publish SwiftUI state while measuring it.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0, textContainer?.containerSize.width != newSize.width {
            textContainer?.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    @discardableResult func apply(_ document: ResponseDocument) -> Bool {
        guard self.document != document, let storage = textStorage else { return false }
        let selection = selectedRange()
        var keptBlocks = 0
        var next: [NSAttributedString]
        if case .markdown(let blocks) = document {
            if case .markdown(let previous) = self.document {
                keptBlocks = zip(previous, blocks).prefix { $0 == $1 }.count
            }
            next = Array(fragments.prefix(keptBlocks))
            for block in blocks.dropFirst(keptBlocks) { next.append(NativeResponseFormatter.format(.markdown([block]))) }
            // Keep a growing code block's decoration stable too. Replacing its
            // identical paragraph style would invalidate every preceding line.
            if case .markdown(let previous) = self.document,
               keptBlocks < previous.count, keptBlocks < blocks.count,
               previous[keptBlocks].kind == blocks[keptBlocks].kind,
               case .code = blocks[keptBlocks].kind {
                next[keptBlocks] = reusingCodeStyle(fragments[keptBlocks], in: next[keptBlocks])
            }
        } else { next = [NativeResponseFormatter.format(document)] }
        let offset = fragments.prefix(keptBlocks).reduce(0) { $0 + $1.length }
        let tail = NSMutableAttributedString(string: "")
        for fragment in next.dropFirst(keptBlocks) { tail.append(fragment) }
        let oldTail = storage.attributedSubstring(from: NSRange(location: offset, length: storage.length - offset))
        let keptCharacters = matchingPrefix(oldTail, tail)
        let replacement = tail.attributedSubstring(from: NSRange(location: keptCharacters, length: tail.length - keptCharacters))
        storage.replaceCharacters(in: NSRange(location: offset + keptCharacters, length: storage.length - offset - keptCharacters), with: replacement)
        self.document = document
        fragments = next
        let count = storage.length
        let location = min(selection.location, count)
        let preservedSelection = NSRange(location: location, length: min(selection.length, count - location))
        if selectedRange() != preservedSelection {
            setSelectedRange(preservedSelection)
        }
        measurements.removeAll(keepingCapacity: true)
        return true
    }

    private func matchingPrefix(_ old: NSAttributedString, _ new: NSAttributedString) -> Int {
        let length = old.string.commonPrefix(with: new.string, options: .literal).utf16.count
        var position = 0
        while position < length {
            var oldRange = NSRange(), newRange = NSRange()
            let lhs = old.attributes(at: position, effectiveRange: &oldRange)
            let rhs = new.attributes(at: position, effectiveRange: &newRange)
            guard NSDictionary(dictionary: lhs).isEqual(NSDictionary(dictionary: rhs)) else { return position }
            position = min(length, NSMaxRange(oldRange), NSMaxRange(newRange))
        }
        return position
    }

    private func reusingCodeStyle(_ old: NSAttributedString, in new: NSAttributedString) -> NSAttributedString {
        var style: NSParagraphStyle?
        old.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: old.length)) { value, _, stop in
            if let paragraph = value as? NSParagraphStyle, !paragraph.textBlocks.isEmpty { style = paragraph; stop.pointee = true }
        }
        guard let style else { return new }
        let result = NSMutableAttributedString(attributedString: new)
        new.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: new.length)) { value, range, _ in
            if let paragraph = value as? NSParagraphStyle, !paragraph.textBlocks.isEmpty { result.addAttribute(.paragraphStyle, value: style, range: range) }
        }
        return result
    }

    func measuredSize(width proposedWidth: CGFloat) -> NSSize {
        let width = max(1, proposedWidth.isFinite ? floor(proposedWidth) : 640)
        if measurements[width] == nil {
            measuringContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            measuringLayout.ensureLayout(for: measuringContainer)
            if measurements.count >= 4 { measurements.removeAll(keepingCapacity: true) }
            measurements[width] = ceil(measuringLayout.usedRect(for: measuringContainer).maxY)
            layoutPasses += 1
        }
        return NSSize(width: width, height: max(1, measurements[width] ?? 0))
    }
}

@MainActor
enum NativeResponseFormatter {
    private struct Style {
        var size: CGFloat = 13
        var bold = false
        var mono = false
        var color: NSColor = .labelColor
        var indent: CGFloat = 0
        var firstIndent: CGFloat = 0
        var prefix = ""
        var spacing: CGFloat = 12
        var quote = false
    }

    static func format(_ document: ResponseDocument) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        switch document {
        case .plain(let text, let size, let tone):
            let color: NSColor = tone == .error ? .systemRed : tone == .secondary ? .secondaryLabelColor : .labelColor
            paragraph(AttributedString(text), style: Style(size: size, color: color, spacing: 0), into: result)
        case .markdown(let blocks):
            for block in blocks { append(block, style: Style(), into: result) }
        }
        return result
    }

    private static func append(_ block: ResponseBlock, style: Style, into result: NSMutableAttributedString) {
        var style = style
        switch block.kind {
        case .heading(let level):
            style.size = level == 1 ? 23 : level == 2 ? 19 : 16
            style.bold = true
            paragraph(block.content, style: style, into: result)
        case .text, .tableCell:
            paragraph(block.content, style: style, into: result)
        case .code(let language):
            if let language, !language.isEmpty {
                var caption = style
                caption.size = 10; caption.color = .secondaryLabelColor; caption.spacing = 4
                paragraph(AttributedString(String(language.prefix(64))), style: caption, into: result)
            }
            style.size = 12; style.mono = true
            let panel = NSTextBlock()
            panel.setContentWidth(100, type: .percentageValueType)
            panel.setWidth(10, type: .absoluteValueType, for: .padding)
            panel.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1)
            paragraph(block.content, style: style, textBlocks: [panel], into: result)
        case .list, .tableRow:
            for child in block.children { append(child, style: style, into: result) }
        case .listItem(let number, let checked):
            let marker = checked.map { $0 ? "☑" : "☐" } ?? number.map { "\($0)." } ?? "•"
            style.firstIndent = style.indent
            style.indent += 22
            style.prefix = marker + "\t"
            style.spacing = 7
            for child in block.children {
                if case .list = child.kind {
                    var nested = style
                    nested.firstIndent = nested.indent; nested.prefix = ""
                    append(child, style: nested, into: result)
                } else { append(child, style: style, into: result) }
                style.prefix = ""; style.firstIndent = style.indent
            }
        case .quote:
            style.indent += 14; style.firstIndent = style.indent
            style.color = .secondaryLabelColor; style.quote = true
            for child in block.children { append(child, style: style, into: result) }
        case .divider:
            style.color = .separatorColor; style.spacing = 10
            paragraph(AttributedString("────────────────────────"), style: style, into: result)
        case .table(let columns):
            appendTable(rows: block.children, columns: columns, style: style, into: result)
        }
    }

    private static func appendTable(rows: [ResponseBlock], columns: [PresentationIntent.TableColumn.Alignment],
                                    style: Style, into result: NSMutableAttributedString) {
        guard !columns.isEmpty else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        for (rowIndex, row) in rows.enumerated() {
            let header: Bool
            if case .tableRow(let isHeader) = row.kind { header = isHeader } else { header = false }
            for (column, alignment) in columns.enumerated() {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setContentWidth(100 / CGFloat(columns.count), type: .percentageValueType)
                cell.setWidth(9, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(NSColor(calibratedWhite: 0.26, alpha: 1))
                cell.backgroundColor = header ? NSColor(calibratedWhite: 0.14, alpha: 1) : rowIndex.isMultiple(of: 2) ? NSColor(calibratedWhite: 0.105, alpha: 1) : .clear
                var cellStyle = style
                cellStyle.bold = header; cellStyle.prefix = ""; cellStyle.indent = 0; cellStyle.firstIndent = 0; cellStyle.spacing = 0
                let content = row.children.first { if case .tableCell(let index) = $0.kind { return index == column }; return false }?.content ?? AttributedString(" ")
                let textAlignment: NSTextAlignment = alignment == .center ? .center : alignment == .right ? .right : .left
                paragraph(content.characters.isEmpty ? AttributedString(" ") : content, style: cellStyle,
                          textBlocks: [cell], alignment: textAlignment, into: result)
            }
        }
        paragraph(AttributedString(""), style: Style(size: 4, spacing: 4), into: result)
    }

    private static func paragraph(_ content: AttributedString, style: Style, textBlocks: [NSTextBlock] = [],
                                  alignment: NSTextAlignment = .left, into result: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.mono ? 2 : 3
        paragraph.paragraphSpacing = style.spacing
        paragraph.firstLineHeadIndent = style.firstIndent
        paragraph.headIndent = style.indent
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: style.indent)]
        paragraph.alignment = alignment
        paragraph.lineBreakMode = style.mono ? .byCharWrapping : .byWordWrapping
        paragraph.textBlocks = textBlocks
        if style.quote && textBlocks.isEmpty {
            let quote = NSTextBlock()
            quote.setContentWidth(100, type: .percentageValueType)
            quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            quote.setBorderColor(NSColor(srgbRed: 0.52, green: 0.65, blue: 0.98, alpha: 0.65), for: .minX)
            quote.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minX)
            paragraph.textBlocks = [quote]
        }
        let start = result.length
        if !style.prefix.isEmpty {
            result.append(NSAttributedString(string: style.prefix, attributes: [.font: NSFont.systemFont(ofSize: style.size), .foregroundColor: style.color]))
        }
        for run in content.runs {
            let intent = run.inlinePresentationIntent
            let mono = style.mono || intent?.contains(.code) == true
            let bold = style.bold || intent?.contains(.stronglyEmphasized) == true
            var font = mono ? NSFont.monospacedSystemFont(ofSize: style.size, weight: bold ? .semibold : .regular)
                : NSFont.systemFont(ofSize: style.size, weight: bold ? .semibold : .regular)
            if intent?.contains(.emphasized) == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color]
            if intent?.contains(.code) == true && !style.mono { attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
            if intent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(content[run.range].characters), attributes: attributes))
        }
        // Include a terminator in the same table/text block so TextKit treats
        // every cell as a complete paragraph. Preserve code's existing newline.
        if content.characters.last != "\n" {
            result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: style.size), .foregroundColor: style.color]))
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: result.length - start))
    }
}

struct TranscriptFollowState {
    private(set) var following = true
    private(set) var liveScrolling = false
    var canFollow: Bool { following && !liveScrolling }
    mutating func begin() { liveScrolling = true; following = false }
    mutating func moved(nearBottom: Bool) { following = nearBottom }
    mutating func end(nearBottom: Bool) { liveScrolling = false; following = nearBottom }
    mutating func jumpToLatest() { liveScrolling = false; following = true }
}

enum TranscriptScrollEvent { case began, moved(nearBottom: Bool), ended(nearBottom: Bool) }

struct TranscriptScrollObserver: NSViewRepresentable {
    let onEvent: (TranscriptScrollEvent) -> Void
    func makeNSView(context: Context) -> TranscriptScrollObserverView { TranscriptScrollObserverView() }
    func updateNSView(_ view: TranscriptScrollObserverView, context: Context) { view.onEvent = onEvent; view.connect() }
    static func dismantleNSView(_ view: TranscriptScrollObserverView, coordinator: Void) { view.disconnect() }
}

@MainActor
final class TranscriptScrollObserverView: NSView {
    var onEvent: ((TranscriptScrollEvent) -> Void)?
    private weak var observedScroll: NSScrollView?
    private var generation = 0
    private var lastNearBottom: Bool?
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
    override func layout() { super.layout(); connect() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func connect() {
        guard let scroll = enclosingScrollView, observedScroll !== scroll else { return }
        NotificationCenter.default.removeObserver(self)
        observedScroll = scroll; generation += 1; lastNearBottom = nil
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(started), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(moved), name: NSScrollView.didLiveScrollNotification, object: scroll)
        center.addObserver(self, selector: #selector(ended), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }
    func disconnect() {
        NotificationCenter.default.removeObserver(self)
        observedScroll = nil; onEvent = nil; generation += 1; lastNearBottom = nil
    }
    static func isNearBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return true }
        let visible = scroll.documentVisibleRect
        let remaining = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
        return remaining <= 48
    }
    @objc private func started() { lastNearBottom = nil; send(.began) }
    @objc private func moved() {
        guard let scroll = observedScroll else { return }
        let nearBottom = Self.isNearBottom(scroll)
        guard lastNearBottom != nearBottom else { return }
        lastNearBottom = nearBottom
        send(.moved(nearBottom: nearBottom))
    }
    @objc private func ended() { if let scroll = observedScroll { send(.ended(nearBottom: Self.isNearBottom(scroll))) } }
    private func send(_ event: TranscriptScrollEvent) {
        let generation = generation
        // User-scroll notifications can be delivered inside an AppKit layout
        // transaction. Publish only after it returns, and ignore detached views.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onEvent?(event)
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
