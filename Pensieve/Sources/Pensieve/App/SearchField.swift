import AppKit
import SwiftUI

struct NativeSearchField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var focusToken: Int = 0
  var focusOnAppear: Bool = false
  var accessibilityIdentifier: String
  var onSubmit: (() -> Void)?

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField(frame: .zero)
    field.placeholderString = placeholder
    field.target = context.coordinator
    field.action = #selector(Coordinator.didSubmit(_:))
    field.delegate = context.coordinator
    field.sendsSearchStringImmediately = true
    field.sendsWholeSearchString = false
    field.bezelStyle = .squareBezel
    field.controlSize = .small
    field.setAccessibilityIdentifier(accessibilityIdentifier)
    // The find bar is mounted on demand (⌘F), so a fresh field must claim first
    // responder when it appears — the focusToken alone is swallowed by the
    // coordinator on first mount. Deferred so the field is already in a window.
    if focusOnAppear {
      DispatchQueue.main.async { [weak field] in
        field?.window?.makeFirstResponder(field)
      }
    }
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text {
      field.stringValue = text
    }
    if context.coordinator.lastFocusToken != focusToken {
      context.coordinator.lastFocusToken = focusToken
      DispatchQueue.main.async {
        field.window?.makeFirstResponder(field)
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: NativeSearchField
    var lastFocusToken: Int

    init(parent: NativeSearchField) {
      self.parent = parent
      self.lastFocusToken = parent.focusToken
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      parent.text = field.stringValue
    }

    @objc func didSubmit(_ sender: NSSearchField) {
      parent.text = sender.stringValue
      parent.onSubmit?()
    }
  }
}
