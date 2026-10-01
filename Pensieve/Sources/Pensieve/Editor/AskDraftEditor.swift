import AppKit
import SwiftUI

/// The composer owns Return; Shift-Return remains native multiline editing.
struct AskDraftEditor: NSViewRepresentable {
  @Binding var text: String
  var isEnabled: Bool
  var onSubmit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    let view = AskDraftTextView()
    view.isRichText = false
    view.drawsBackground = false
    view.font = .preferredFont(forTextStyle: .body)
    view.textColor = .labelColor
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    view.delegate = context.coordinator
    view.setAccessibilityLabel("Ask question")
    view.setAccessibilityIdentifier("pensieve.ask.draft")
    scroll.documentView = view
    updateNSView(scroll, context: context)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let view = scroll.documentView as? AskDraftTextView else { return }
    if view.string != text { view.string = text }
    view.isEditable = isEnabled
    view.onSubmit = onSubmit
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: AskDraftEditor
    init(_ parent: AskDraftEditor) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      guard let view = notification.object as? NSTextView else { return }
      parent.text = view.string
    }
  }
}

final class AskDraftTextView: NSTextView {
  var onSubmit: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
    if event.keyCode == 36 || event.keyCode == 76, modifiers.isEmpty, !hasMarkedText() {
      if isEditable, !event.isARepeat { onSubmit?() }
      return
    }
    super.keyDown(with: event)
  }
}
