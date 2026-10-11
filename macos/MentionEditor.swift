import AppKit
import SwiftUI

@MainActor
final class MentionCompletionController: ObservableObject {
    @Published private(set) var query: MentionQuery?
    @Published private(set) var suggestions: [AgentIdentity] = []
    @Published private(set) var selectedIndex = 0
    weak var textView: MentionInputTextView?
    var identities: [AgentIdentity] = []
    private var suppressed: (String, NSRange)?
    private var accepting = false

    func refresh() {
        guard !accepting, let textView else { return }
        if !textView.isEditable || textView.hasMarkedText() || (suppressed?.0 == textView.string && suppressed?.1 == textView.selectedRange()) {
            clear()
            return
        }
        let next = mentionQuery(in: textView.string, selection: textView.selectedRange())
        let options = next.map { matchingTeammates($0.query, identities: identities) } ?? []
        if next != query || options != suggestions { selectedIndex = 0 }
        if query != next { query = next }
        if suggestions != options { suggestions = options }
    }
    func dismiss() {
        if let textView { suppressed = (textView.string, textView.selectedRange()) }
        clear()
    }
    func resume() { suppressed = nil; refresh() }
    private func clear() {
        if query != nil { query = nil }
        if !suggestions.isEmpty { suggestions = [] }
        if selectedIndex != 0 { selectedIndex = 0 }
    }
    func highlight(_ index: Int) { if suggestions.indices.contains(index) && selectedIndex != index { selectedIndex = index } }
    @discardableResult func choose(_ identity: AgentIdentity) -> Bool {
        guard let textView, textView.isEditable,
              let current = mentionQuery(in: textView.string, selection: textView.selectedRange()),
              matchingTeammates(current.query, identities: identities).contains(identity),
              let insertion = mentionInsertion(identity, query: current, in: textView.string) else { dismiss(); return false }
        accepting = true
        textView.insertText(insertion.replacement, replacementRange: insertion.range)
        textView.setSelectedRange(insertion.selection)
        textView.scrollRangeToVisible(insertion.selection)
        textView.window?.makeFirstResponder(textView)
        accepting = false
        dismiss()
        return true
    }
    func handle(_ selector: Selector, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard query != nil, !suggestions.isEmpty, !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        switch NSStringFromSelector(selector) {
        case "moveDown:": selectedIndex = (selectedIndex + 1) % suggestions.count
        case "moveUp:": selectedIndex = (selectedIndex + suggestions.count - 1) % suggestions.count
        case "insertTab:", "insertNewline:":
            guard !modifiers.contains(.shift) else { dismiss(); return false }
            return choose(suggestions[selectedIndex])
        case "cancelOperation:": dismiss()
        default: return false
        }
        return true
    }
}

final class MentionInputTextView: NSTextView {
    weak var completionController: MentionCompletionController?
}

private struct NativeMentionEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let identities: [AgentIdentity]
    let controller: MentionCompletionController
    let enabled: Bool
    let fontSize: CGFloat
    let height: CGFloat
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.focusRingType = .none
        let editor = MentionInputTextView(frame: NSRect(x: 0, y: 0, width: 330, height: height))
        editor.isRichText = false
        editor.drawsBackground = false
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.font = .systemFont(ofSize: fontSize)
        editor.focusRingType = .none
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.containerSize = NSSize(width: 330, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: height)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.string = text
        editor.delegate = context.coordinator
        editor.completionController = controller
        controller.textView = editor
        controller.identities = identities
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        guard let editor = scroll.documentView as? MentionInputTextView else { return }
        editor.isEditable = enabled
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            editor.undoManager?.removeAllActions()
        }
        controller.identities = identities
        DispatchQueue.main.async { [weak editor, weak controller] in
            guard let editor, let controller else { return }
            if focused && enabled && editor.window?.firstResponder !== editor { editor.window?.makeFirstResponder(editor) }
            controller.refresh()
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeMentionEditor
        var updating = false
        init(parent: NativeMentionEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? MentionInputTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
            parent.controller.refresh()
        }
        func textViewDidChangeSelection(_ notification: Notification) { if !updating { parent.controller.refresh() } }
        func textDidBeginEditing(_ notification: Notification) {
            if !parent.focused { parent.focused = true }
            parent.controller.resume()
        }
        func textDidEndEditing(_ notification: Notification) {
            if parent.focused { parent.focused = false }
            parent.controller.dismiss()
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            parent.controller.handle(commandSelector, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        }
    }
}

struct MentionComposer: View {
    @Binding var text: String
    @Binding var focused: Bool
    let identities: [AgentIdentity]
    let enabled: Bool
    let fontSize: CGFloat
    let height: CGFloat
    let accessibilityLabel: String
    @StateObject private var completion = MentionCompletionController()
    var body: some View {
        NativeMentionEditor(text: $text, focused: $focused, identities: identities, controller: completion,
                            enabled: enabled, fontSize: fontSize, height: height, accessibilityLabel: accessibilityLabel)
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if !completion.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mention a teammate").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.bottom, 3)
                        ForEach(Array(completion.suggestions.enumerated()), id: \.element.id) { index, identity in
                            Button { completion.choose(identity) } label: {
                                HStack(spacing: 10) {
                                    Text(String(identity.name.prefix(1)).uppercased()).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(identity.provider.tint).frame(width: 28, height: 28)
                                        .background(identity.provider.tint.opacity(0.13), in: Circle())
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(identity.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                                        Text(identity.provider.name).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text("@\(identity.mention)").font(.system(size: 11)).foregroundStyle(Theme.accent)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == completion.selectedIndex ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).focusable(false).onHover { hovering in if hovering { completion.highlight(index) } }
                                .accessibilityLabel("Mention \(identity.name), \(identity.provider.name), @\(identity.mention)")
                        }
                        Text("↑↓ choose · Tab or Return insert · Esc dismiss").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.top, 3)
                    }.padding(8).frame(width: 330).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                        .alignmentGuide(.top) { $0[.bottom] + 8 }
                }
            }.zIndex(10)
    }
}

@MainActor
func verifyNativeMentionEditor() -> Bool {
    func find(_ view: NSView) -> MentionInputTextView? {
        if let editor = view as? MentionInputTextView { return editor }
        for child in view.subviews { if let editor = find(child) { return editor } }
        return nil
    }
    guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView,
          let editor = find(root), let controller = editor.completionController else { return false }
    let original = editor.string
    editor.window?.makeFirstResponder(editor)
    editor.insertText("Please ask @", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    controller.refresh()
    guard controller.suggestions.count == 4, controller.suggestions[1].mention == "alex" else { return false }
    guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: editor.window?.windowNumber ?? 0, context: nil,
                                     characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125),
          let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: editor.window?.windowNumber ?? 0, context: nil,
                                    characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48),
          let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: editor.window?.windowNumber ?? 0, context: nil,
                                      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return false }
    editor.keyDown(with: down)
    editor.keyDown(with: tab)
    guard editor.string == "Please ask @alex " && controller.suggestions.isEmpty else { return false }
    editor.insertText("@cod", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    controller.refresh()
    guard controller.suggestions.map(\.mention) == ["alex"] else { return false }
    editor.keyDown(with: enter)
    guard editor.string == "@alex " && controller.suggestions.isEmpty else { return false }
    editor.insertText("@ma", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    controller.refresh()
    guard controller.handle(NSSelectorFromString("cancelOperation:")) && controller.suggestions.isEmpty else { return false }
    editor.insertText("y", replacementRange: editor.selectedRange())
    controller.refresh()
    let reopened = controller.suggestions.map(\.mention) == ["maya"]
    editor.insertText(original, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    controller.dismiss()
    if reopened { print("Native @ autocomplete passed: named teammates, engine aliases, arrow/Tab/Return selection and Escape") }
    return reopened
}
