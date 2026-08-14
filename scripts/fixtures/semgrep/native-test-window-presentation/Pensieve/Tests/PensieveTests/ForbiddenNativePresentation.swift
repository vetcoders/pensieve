import AppKit

func forbiddenNativePresentation(
  window: NSWindow,
  child: NSWindow,
  controller: NSWindowController,
  application: NSApplication
) {
  window.makeKeyAndOrderFront(nil)
  window.orderFront(nil)
  window.orderFrontRegardless()
  window.order(.above, relativeTo: 0)
  controller.showWindow(nil)
  window.beginSheet(child)
  window.beginCriticalSheet(child)
  window.beginSheetModal(child)
  NSViewController().presentAsSheet(NSViewController())
  NSViewController().presentAsModalWindow(NSViewController())
  NSViewController().presentViewControllerAsSheet(NSViewController())
  NSViewController().presentViewControllerAsModalWindow(NSViewController())
  NSViewController().presentViewController(
    NSViewController(),
    asPopoverRelativeTo: .zero,
    of: NSView(),
    preferredEdge: .maxY,
    behavior: .transient)
  NSViewController().presentAsPopover(
    relativeTo: .zero,
    of: NSView(),
    preferredEdge: .maxY,
    behavior: .transient)
  window.addChildWindow(child, ordered: .above)
  window.addTabbedWindow(child, ordered: .above)
  window.setIsVisible(true)
  window.isVisible = true
  application.runModal(for: window)
  NSApplication.shared.activate(ignoringOtherApps: true)
  NSApp.activate(ignoringOtherApps: true)
  _ = window.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
  _ = window.perform(Selector("makeKeyAndOrderFront:"), with: nil)
  _ = NSWindow()
  _ = NSPanel()
  _ = NSWindow(
    contentRect: .zero,
    styleMask: [.titled],
    backing: .buffered,
    defer: false)
  _ = NSPanel(
    contentRect: .zero,
    styleMask: [.titled],
    backing: .buffered,
    defer: false)
}

func forbiddenEagerTaflaFixture(service: TranscriptionService) {
  _ = TranscriptionTaflaPanelController(service: service)
}

func forbiddenTaflaFixtureUsingProductionPresentation(service: TranscriptionService) {
  _ = TranscriptionTaflaPanelController(
    service: service,
    panelFactory: {
      NSPanel(
        contentRect: .zero,
        styleMask: [.titled],
        backing: .buffered,
        defer: true)
    })
}

func forbiddenTaflaFixtureUsingProductionDismissal(service: TranscriptionService) {
  _ = TranscriptionTaflaPanelController(
    service: service,
    panelFactory: {
      NSPanel(
        contentRect: .zero,
        styleMask: [.titled],
        backing: .buffered,
        defer: true)
    },
    presentPanel: { _ in })
}

func forbiddenTaflaFixtureUsingProductionPresentationOnly(service: TranscriptionService) {
  _ = TranscriptionTaflaPanelController(
    service: service,
    panelFactory: {
      NSPanel(
        contentRect: .zero,
        styleMask: [.titled],
        backing: .buffered,
        defer: true)
    },
    dismissPanel: { _ in })
}
