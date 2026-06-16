import AppKit
import XCTest

@testable import Pensieve

final class DocumentWindowRegistryTests: XCTestCase {
  @MainActor
  func testOpenTabDocumentIDsRoundTripAcrossOpenAttachSwitchAndWillCloseReconcile() throws {
    let alphaID = URL(fileURLWithPath: "/tmp/pensieve-open-tabs-alpha.md").standardizedFileURL
    let betaID = URL(fileURLWithPath: "/tmp/pensieve-open-tabs-beta.md").standardizedFileURL
    let window = Self.makeWindow()
    defer { window.close() }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("open should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      makeDocumentWindow: { ref in
        XCTAssertEqual(ref?.id, alphaID)
        return window
      }
    )

    registry.open(DocumentRef(id: alphaID))
    registry.attach(window, documentID: alphaID)

    XCTAssertEqual(registry.openTabDocumentIDs, [alphaID])

    registry.attach(window, documentID: betaID)

    XCTAssertEqual(
      registry.openTabDocumentIDs,
      [betaID],
      "switching a window to another document must publish the actual live tab, not stale history")

    registry.reconcileClosedWindow(window)

    XCTAssertEqual(
      registry.openTabDocumentIDs,
      [],
      "the process-wide willClose reconciler must remove the closing window's document")
  }

  @MainActor
  func testWillCloseReconcileDoesNotTombstoneReusableWindows() throws {
    let alphaID = URL(fileURLWithPath: "/tmp/pensieve-reusable-alpha.md").standardizedFileURL
    let betaID = URL(fileURLWithPath: "/tmp/pensieve-reusable-beta.md").standardizedFileURL
    let window = Self.makeWindow()
    defer { window.close() }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("attach should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in }
    )

    registry.attach(window, documentID: alphaID)
    registry.reconcileClosedWindow(window)
    registry.attach(window, documentID: betaID)

    XCTAssertEqual(
      registry.openTabDocumentIDs,
      [betaID],
      "global willClose cleanup must not poison reusable AppKit/scene windows")
  }

  @MainActor
  func testCloseDocumentWindowClosesMappedWindowAndReliesOnReconcileForPublishedState() throws {
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-close-one.md").standardizedFileURL
    let missingID = URL(fileURLWithPath: "/tmp/pensieve-close-missing.md").standardizedFileURL
    let window = Self.makeWindow()
    defer { window.close() }

    var closedWindows: [NSWindow] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("attach should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      closeWindow: { closedWindows.append($0) }
    )

    registry.attach(window, documentID: documentID)
    registry.closeDocumentWindow(missingID)
    registry.closeDocumentWindow(documentID)

    XCTAssertEqual(closedWindows.map { ObjectIdentifier($0) }, [ObjectIdentifier(window)])
    XCTAssertEqual(
      registry.openTabDocumentIDs,
      [documentID],
      "closeDocumentWindow only requests the close; teardown is reconciled from AppKit willClose")

    registry.reconcileClosedWindow(window)

    XCTAssertEqual(registry.openTabDocumentIDs, [])
  }

  @MainActor
  func testCloseAllDocumentWindowsSnapshotsOpenTabsWhileCloseCallbacksMutateRegistry() throws {
    let alphaID = URL(fileURLWithPath: "/tmp/pensieve-close-all-alpha.md").standardizedFileURL
    let betaID = URL(fileURLWithPath: "/tmp/pensieve-close-all-beta.md").standardizedFileURL
    let alphaWindow = Self.makeWindow()
    let betaWindow = Self.makeWindow()
    defer {
      alphaWindow.close()
      betaWindow.close()
    }

    var closedWindowIDs: [ObjectIdentifier] = []
    var registry: DocumentWindowRegistry!
    registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("attach should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      closeWindow: { window in
        closedWindowIDs.append(ObjectIdentifier(window))
        registry.reconcileClosedWindow(window)
      }
    )

    registry.attach(alphaWindow, documentID: alphaID)
    registry.attach(betaWindow, documentID: betaID)

    XCTAssertEqual(registry.openTabDocumentIDs, [alphaID, betaID])

    registry.closeAllDocumentWindows()

    XCTAssertEqual(
      closedWindowIDs,
      [ObjectIdentifier(alphaWindow), ObjectIdentifier(betaWindow)])
    XCTAssertEqual(registry.openTabDocumentIDs, [])
  }

  @MainActor
  private static func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .zero)
    return window
  }
}
