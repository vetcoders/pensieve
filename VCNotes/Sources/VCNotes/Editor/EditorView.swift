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

// MARK: - Placeholder NSViewRepresentable (Wave C-2 replaces with TextKit 2)

struct EditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    @Binding var isDirty: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let textLayoutManager = NSTextLayoutManager()
        let textContentStorage = MarkdownTextStorage()
        textContentStorage.addTextLayoutManager(textLayoutManager)
        
        let textStorage = NSTextStorage()
        textContentStorage.textStorage = textStorage
        
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textLayoutManager.textContainer = textContainer
        
        let textView = MarkdownTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        
        textView.setupGutter(layoutManager: textLayoutManager)
        
        textContentStorage.fontSize = fontSize
        textView.gutter?.fontSize = fontSize
        
        textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        textContentStorage.refreshHighlighting()
        
        context.coordinator.textView = textView
        context.coordinator.textContentStorage = textContentStorage
        
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? MarkdownTextView,
              let textContentStorage = context.coordinator.textContentStorage,
              let textStorage = textContentStorage.textStorage else { return }
              
        if textContentStorage.fontSize != fontSize {
            textContentStorage.fontSize = fontSize
            textView.gutter?.fontSize = fontSize
            textView.gutter?.needsDisplay = true
        }
        
        if textStorage.string != text {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
            textContentStorage.refreshHighlighting()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorRepresentable
        weak var textView: MarkdownTextView?
        weak var textContentStorage: MarkdownTextStorage?
        
        init(_ parent: EditorRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let textStorage = textView.textStorage else { return }
            parent.text = textStorage.string
            parent.isDirty = true
            NotificationCenter.default.post(name: .vcDocumentChanged, object: nil)
        }
    }
}
