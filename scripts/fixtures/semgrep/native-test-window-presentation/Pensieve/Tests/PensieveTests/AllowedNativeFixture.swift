import AppKit

func allowedNativeFixture(window: NSWindow) {
  let message = "window.makeKeyAndOrderFront(nil)"
  // window.orderFront(nil)
  _ = NSWindow(
    contentRect: .zero,
    styleMask: [.titled],
    backing: .buffered,
    defer: true)
  _ = NSPanel(
    contentRect: .zero,
    styleMask: [.titled],
    backing: .buffered,
    defer: true)
  window.orderOut(nil)
  window.close()
  window.setIsVisible(false)
  window.isVisible = false
  _ = message
}

func allowedDeferredTaflaFixture(service: TranscriptionService) {
  _ = TranscriptionTaflaPanelController(
    service: service,
    panelFactory: {
      NSPanel(
        contentRect: .zero,
        styleMask: [.titled],
        backing: .buffered,
        defer: true)
    },
    presentPanel: { _ in },
    dismissPanel: { _ in })
}
