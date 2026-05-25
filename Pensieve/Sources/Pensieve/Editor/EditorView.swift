import SwiftUI
import AppKit

struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            MarkdownFormattingToolbelt { format in
                controller.applyMarkdownFormat(format)
            }

            EditorRepresentable(
                text: documentText,
                fontSize: appState.fontSize,
                formattingCommand: appState.pendingMarkdownFormatCommand,
                isDirty: documentDirty,
                onDocumentChanged: controller.documentDidChange
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var documentText: Binding<String> {
        Binding(
            get: { appState.documentSession.text },
            set: { appState.documentSession.text = $0 }
        )
    }

    private var documentDirty: Binding<Bool> {
        Binding(
            get: { appState.documentSession.isDirty },
            set: { appState.documentSession.isDirty = $0 }
        )
    }
}

struct MarkdownFormattingToolbelt: View {
    let apply: (MarkdownFormat) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(MarkdownFormat.allCases) { format in
                    Button {
                        apply(format)
                    } label: {
                        Image(systemName: format.systemImageName)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(format.label)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 32)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - TextKit bridge

struct EditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let formattingCommand: MarkdownFormatCommand?
    @Binding var isDirty: Bool
    let onDocumentChanged: @MainActor () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let surface = MarkdownEditorSurface(text: text, fontSize: fontSize)
        surface.onTextChanged = { newText in
            self.text = newText
            self.isDirty = true
            self.onDocumentChanged()
        }
        context.coordinator.surface = surface
        return surface.scrollView
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let surface = context.coordinator.surface else { return }
        surface.update(text: text, fontSize: fontSize)
        context.coordinator.apply(formattingCommand, to: surface)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var surface: MarkdownEditorSurface?
        private var lastAppliedFormattingCommandID: UUID?

        func apply(_ command: MarkdownFormatCommand?, to surface: MarkdownEditorSurface) {
            guard let command else { return }
            guard command.id != lastAppliedFormattingCommandID else { return }
            lastAppliedFormattingCommandID = command.id
            surface.applyMarkdownFormat(command.format)
        }
    }
}

final class MarkdownEditorSurface: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: MarkdownTextView
    let textStorage: NSTextStorage
    let textContentStorage: MarkdownTextStorage
    let textLayoutManager: NSTextLayoutManager
    let textContainer: NSTextContainer

    var onTextChanged: ((String) -> Void)?
    var isApplyingExternalText = false

    init(text: String, fontSize: CGFloat) {
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
        
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 10)

        scrollView.documentView = textView
        textView.setupGutter(layoutManager: textLayoutManager)

        super.init()
        
        textView.delegate = self
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
            isApplyingExternalText = true
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
            textContentStorage.refreshHighlighting()
            isApplyingExternalText = false
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingExternalText else { return }
        guard let changedTextView = notification.object as? NSTextView, changedTextView === textView else { return }
        onTextChanged?(textStorage.string)
    }

    @discardableResult
    func applyMarkdownFormat(_ format: MarkdownFormat) -> Bool {
        let range = textView.selectedRange()
        guard range.length > 0 else { return false }
        guard NSMaxRange(range) <= (textStorage.string as NSString).length else { return false }

        let selectedText = (textStorage.string as NSString).substring(with: range)
        let replacement = MarkdownFormatter.format(selectedText, as: format)
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }

        textStorage.replaceCharacters(in: range, with: replacement)
        textContentStorage.refreshHighlighting()
        textView.setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
        textView.didChangeText()
        return true
    }
}
