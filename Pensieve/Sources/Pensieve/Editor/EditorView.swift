import SwiftUI
import AppKit

// MARK: - SwiftUI wrapper (Wave C-2 agent will replace internals with NSTextView+TextKit2)

struct EditorView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        EditorRepresentable(
            text: $appState.activeDocumentText,
            fontSize: appState.fontSize,
            isDirty: $appState.activeDocumentDirty
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - TextKit bridge

struct EditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    @Binding var isDirty: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let bridge = Self.makeBridge(text: text, fontSize: fontSize, delegate: context.coordinator)
        context.coordinator.bridge = bridge
        return bridge.scrollView
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let bridge = context.coordinator.bridge else { return }
        context.coordinator.isApplyingExternalText = true
        bridge.update(text: text, fontSize: fontSize)
        context.coordinator.isApplyingExternalText = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func makeBridge(text: String, fontSize: CGFloat, delegate: NSTextViewDelegate?) -> MarkdownEditorBridge {
        MarkdownEditorBridge(text: text, fontSize: fontSize, delegate: delegate)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorRepresentable
        var bridge: MarkdownEditorBridge?
        var isApplyingExternalText = false
        
        init(_ parent: EditorRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText else { return }
            guard let textView = notification.object as? NSTextView,
                  let textStorage = textView.textStorage else { return }
            parent.text = textStorage.string
            parent.isDirty = true
            NotificationCenter.default.post(name: .vcDocumentChanged, object: nil)
        }
    }
}

final class MarkdownEditorBridge {
    let scrollView: NSScrollView
    let textView: MarkdownTextView
    let textStorage: NSTextStorage
    let textContentStorage: MarkdownTextStorage
    let textLayoutManager: NSTextLayoutManager
    let textContainer: NSTextContainer

    init(text: String, fontSize: CGFloat, delegate: NSTextViewDelegate?) {
        textLayoutManager = NSTextLayoutManager()
        textContentStorage = MarkdownTextStorage()
        textStorage = NSTextStorage()

        textContentStorage.textStorage = textStorage
        textContentStorage.addTextLayoutManager(textLayoutManager)

        textContainer = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textLayoutManager.textContainer = textContainer

        scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        textView = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: scrollView.contentSize.height),
            textContainer: textContainer
        )
        textView.delegate = delegate
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 10)

        scrollView.documentView = textView
        textView.setupGutter(layoutManager: textLayoutManager)

        update(text: text, fontSize: fontSize)
    }

    func update(text: String, fontSize: CGFloat) {
        if textContentStorage.fontSize != fontSize {
            textContentStorage.fontSize = fontSize
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.gutter?.fontSize = fontSize
            textView.gutter?.needsDisplay = true
        }

        if textStorage.string != text {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
            textContentStorage.refreshHighlighting()
        }
    }
}
