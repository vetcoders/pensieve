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
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.delegate = context.coordinator
        textView.string = text

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        let newFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != newFont {
            textView.font = newFont
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorRepresentable
        init(_ parent: EditorRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.isDirty = true
            NotificationCenter.default.post(name: .vcDocumentChanged, object: nil)
        }
    }
}
