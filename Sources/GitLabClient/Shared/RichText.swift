import SwiftUI
import AppKit
import GitLabClientCore

/// Turns the URLs, `!12`, `#34` and `@name` that GitLab would link into real links.
enum RichText {
    /// Adds links to the runs the Markdown parser left plain. Code spans and existing links are
    /// left alone. Without a resolver only URLs are linked.
    static func addingLinks(to text: AttributedString, resolver: LinkResolver?) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            let piece = AttributedString(text[run.range])
            guard run.link == nil, run.inlinePresentationIntent?.contains(.code) != true else { result += piece; continue }
            let plain = String(piece.characters)
            let found = LinkDetector.matches(in: plain).compactMap { match in target(for: match, resolver: resolver).map { (match, $0) } }
            guard !found.isEmpty else { result += piece; continue }
            var cursor = plain.startIndex
            for (match, target) in found {
                if cursor < match.range.lowerBound { result += segment(plain[cursor..<match.range.lowerBound], run.attributes) }
                var link = segment(plain[match.range], run.attributes)
                link.link = target.url
                if case .mention = match.kind { link.backgroundColor = Color.accentColor.opacity(0.12) }
                result += link
                cursor = match.range.upperBound
            }
            if cursor < plain.endIndex { result += segment(plain[cursor...], run.attributes) }
        }
        return result
    }

    static func target(for match: LinkDetector.Match, resolver: LinkResolver?) -> LinkTarget? {
        if let resolver { return resolver.target(for: match.kind) }
        if case .url(let text) = match.kind { return URL(string: text).map(LinkTarget.web) }
        return nil
    }

    /// Inline Markdown with links added, for comments and one-line notes.
    static func inline(_ text: String, resolver: LinkResolver?) -> AttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return addingLinks(to: parsed, resolver: resolver)
    }

    private static func segment(_ text: Substring, _ attributes: AttributeContainer) -> AttributedString {
        var segment = AttributedString(String(text))
        segment.setAttributes(attributes)
        return segment
    }
}

/// Routes in-app links (merge requests of the open project) to a handler and the rest to the
/// default browser.
struct LinkRouting: ViewModifier {
    let openMergeRequest: @MainActor (Int) -> Void

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            if case .mergeRequest(let iid) = LinkTarget(url: url) {
                openMergeRequest(iid)
                return .handled
            }
            return .systemAction
        })
    }
}

extension View {
    func routesLinks(_ openMergeRequest: @escaping @MainActor (Int) -> Void) -> some View {
        modifier(LinkRouting(openMergeRequest: openMergeRequest))
    }
}

/// Plain-text Markdown editor that colors links and references as you type.
struct LinkHighlightingEditor: NSViewRepresentable {
    @Binding var text: String
    var resolver: LinkResolver?
    var controller: EditorController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.string = text
        controller.textView = view
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        context.coordinator.highlight(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LinkHighlightingEditor

        init(parent: LinkHighlightingEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            highlight(view)
        }

        /// Colors matches in place; the text itself never changes. No `.link` attribute, so a
        /// click still places the cursor; the editor's "Found" row and Preview open the links.
        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let text = view.string
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor], range: whole)
            let code = text.ranges(of: #/`[^`\n]+`/#)
            for span in code {
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: NSRange(span, in: text))
            }
            for match in LinkDetector.matches(in: text) where !code.contains(where: { $0.overlaps(match.range) }) {
                guard RichText.target(for: match, resolver: parent.resolver) != nil else { continue }
                let range = NSRange(match.range, in: text)
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                if case .mention = match.kind {
                    storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.12), range: range)
                }
            }
            storage.endEditing()
            view.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor]
        }
    }
}

/// Lets toolbar buttons insert Markdown at the cursor of a `LinkHighlightingEditor`.
@MainActor
final class EditorController {
    weak var textView: NSTextView?

    func insert(_ snippet: String) {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        view.insertText(snippet, replacementRange: view.selectedRange())
    }

    /// Wraps the selection (or a placeholder) in `before` and `after`.
    func wrap(_ before: String, _ after: String, placeholder: String) {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let selected = (view.string as NSString).substring(with: range)
        let inner = selected.isEmpty ? placeholder : selected
        view.window?.makeFirstResponder(view)
        view.insertText(before + inner + after, replacementRange: range)
        view.setSelectedRange(NSRange(location: range.location + (before as NSString).length, length: (inner as NSString).length))
    }
}
