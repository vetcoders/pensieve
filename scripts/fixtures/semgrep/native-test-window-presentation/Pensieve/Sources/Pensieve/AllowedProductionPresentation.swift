import AppKit

func productionPresentationIsOutsideTheUnitTestContract(window: NSWindow) {
  window.makeKeyAndOrderFront(nil)
}
