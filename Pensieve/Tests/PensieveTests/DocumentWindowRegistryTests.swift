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
  func testOpenLauncherWindowCreatesAndActivatesUntitledLauncher() throws {
    let launcherWindow = Self.makeWindow()
    var factoryRefs: [DocumentRef?] = []
    var activatedWindows: [NSWindow] = []
    defer { launcherWindow.close() }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("launcher open should not defer") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { activatedWindows.append($0) },
      makeDocumentWindow: { ref in
        factoryRefs.append(ref)
        return launcherWindow
      }
    )

    registry.openLauncherWindow()

    XCTAssertEqual(factoryRefs.count, 1)
    XCTAssertNil(factoryRefs[0], "cold start must request an untitled launcher window")
    XCTAssertEqual(
      activatedWindows.map { ObjectIdentifier($0) },
      [ObjectIdentifier(launcherWindow)])
    XCTAssertEqual(launcherWindow.title, "Pensieve")
    XCTAssertNil(launcherWindow.representedURL)
    XCTAssertEqual(registry.openTabDocumentIDs, [])
  }

  @MainActor
  func testClosingTheLastDocumentWindowReopensALauncher() throws {
    let docID = URL(fileURLWithPath: "/tmp/pensieve-last-doc.md").standardizedFileURL
    let docWindow = Self.makeWindow()
    let launcherWindow = Self.makeWindow()
    defer {
      docWindow.close()
      launcherWindow.close()
    }

    var factoryRefs: [DocumentRef?] = []
    var deferredWork: [() -> Void] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [] },
      makeDocumentWindow: { ref in
        factoryRefs.append(ref)
        return ref == nil ? launcherWindow : docWindow
      }
    )

    registry.open(DocumentRef(id: docID))
    XCTAssertEqual(factoryRefs.count, 1, "opening a document builds exactly one window")
    XCTAssertEqual(factoryRefs[0]?.id, docID)

    // Closing the LAST document window must not leave the app windowless: it
    // reopens an empty launcher so the user can start a new document (⌘N).
    registry.handleDocumentWindowClosed(docWindow)
    for work in deferredWork { work() }

    XCTAssertTrue(
      factoryRefs.contains { $0 == nil },
      "closing the last document window must reopen an empty launcher")
  }

  @MainActor
  func testGlobalWillCloseReopensLauncherAndReapIgnoresPhantomScene() throws {
    let docID = URL(fileURLWithPath: "/tmp/pensieve-scene-close.md").standardizedFileURL
    let docWindow = Self.makeWindow()
    let phantomScene = Self.makeWindow(title: "<untitled>")
    let launcherWindow = Self.makeWindow()
    defer {
      docWindow.close()
      phantomScene.close()
      launcherWindow.close()
    }

    var factoryRefs: [DocumentRef?] = []
    var deferredWork: [() -> Void] = []
    var sweepWork: [() -> Void] = []
    var closedIDs: [ObjectIdentifier] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { sweepWork.append($0) },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [phantomScene, launcherWindow] },
      closeWindow: { closedIDs.append(ObjectIdentifier($0)) },
      makeDocumentWindow: { ref in
        factoryRefs.append(ref)
        return ref == nil ? launcherWindow : docWindow
      }
    )

    registry.open(DocumentRef(id: docID))
    registry.handleApplicationWindowClosed(docWindow)

    while !deferredWork.isEmpty {
      deferredWork.removeFirst()()
    }
    while !sweepWork.isEmpty {
      sweepWork.removeFirst()()
    }
    while !deferredWork.isEmpty {
      deferredWork.removeFirst()()
    }

    XCTAssertEqual(
      factoryRefs.filter { $0 == nil }.count,
      1,
      "closing the final reusable scene via Command-W must create exactly one launcher")
    XCTAssertTrue(
      registry.applicationHasLiveWindow(),
      "the replacement launcher must remain the app's live window")
    XCTAssertFalse(
      closedIDs.contains(ObjectIdentifier(launcherWindow)),
      "an invisible phantom scene must not let the reap sweep delete the only launcher")
  }

  @MainActor
  func testColdStartPhantomSceneDoesNotCountAsLiveWindow() throws {
    let phantomScene = Self.makeWindow(title: "<untitled>")
    let launcherWindow = Self.makeWindow()
    defer {
      phantomScene.close()
      launcherWindow.close()
    }

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      applicationWindows: { [phantomScene, launcherWindow] },
      makeDocumentWindow: { _ in launcherWindow }
    )

    XCTAssertFalse(
      registry.applicationHasLiveWindow(),
      "an invisible untracked SwiftUI placeholder must not suppress the cold-start launcher")

    registry.openLauncherWindow()

    XCTAssertTrue(
      registry.applicationHasLiveWindow(),
      "a tracked launcher remains live even before AppKit makes it visible")
  }

  @MainActor
  func testClosingOneOfSeveralDocumentWindowsDoesNotReopenALauncher() throws {
    let alphaID = URL(fileURLWithPath: "/tmp/pensieve-keep-alpha.md").standardizedFileURL
    let betaID = URL(fileURLWithPath: "/tmp/pensieve-keep-beta.md").standardizedFileURL
    let alphaWindow = Self.makeWindow()
    let betaWindow = Self.makeWindow()
    defer {
      alphaWindow.close()
      betaWindow.close()
    }

    var factoryRefs: [DocumentRef?] = []
    var deferredWork: [() -> Void] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [alphaWindow, betaWindow] },
      makeDocumentWindow: { ref in
        factoryRefs.append(ref)
        return ref?.id == alphaID ? alphaWindow : betaWindow
      }
    )

    registry.open(DocumentRef(id: alphaID))
    registry.open(DocumentRef(id: betaID))
    registry.handleDocumentWindowClosed(alphaWindow)
    for work in deferredWork { work() }

    XCTAssertFalse(
      factoryRefs.contains { $0 == nil },
      "a launcher must NOT spawn while another document window remains open")
  }

  @MainActor
  func testTerminatingSuppressesLauncherReopenOnLastWindowClose() throws {
    let docID = URL(fileURLWithPath: "/tmp/pensieve-terminate-doc.md").standardizedFileURL
    let docWindow = Self.makeWindow()
    defer { docWindow.close() }

    var factoryRefs: [DocumentRef?] = []
    var deferredWork: [() -> Void] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [] },
      makeDocumentWindow: { ref in
        factoryRefs.append(ref)
        return docWindow
      }
    )

    registry.open(DocumentRef(id: docID))
    registry.beginTermination()
    registry.handleApplicationWindowClosed(docWindow)
    for work in deferredWork { work() }

    XCTAssertFalse(
      factoryRefs.contains { $0 == nil },
      "Quit must not resurrect a launcher as the last window tears down")
  }

  @MainActor
  func testReapKeepsTheOnlyWindowButReapsRedundantLaunchersBesideASurvivor() throws {
    let launcherA = Self.makeWindow()
    let launcherB = Self.makeWindow()
    let survivor = Self.makeWindow()
    defer {
      launcherA.close()
      launcherB.close()
      survivor.close()
    }

    var closedIDs: [ObjectIdentifier] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      closeWindow: { closedIDs.append(ObjectIdentifier($0)) }
    )

    // Every window is reapable → keep one so the app is never windowless.
    registry.reapLaunchersKeepingLastWindow([launcherA], among: [launcherA])
    XCTAssertTrue(
      closedIDs.isEmpty,
      "reaping the only window would leave the app windowless — it must be kept")

    // A tracked content window survives → reap the redundant launcher beside it.
    registry.attach(
      survivor,
      documentID: URL(fileURLWithPath: "/tmp/pensieve-reap-survivor.md"))
    registry.reapLaunchersKeepingLastWindow([launcherB], among: [launcherB, survivor])
    XCTAssertEqual(
      closedIDs, [ObjectIdentifier(launcherB)],
      "a redundant launcher must still be reaped when another window survives")
  }

  @MainActor
  private static func makeWindow(title: String = "") -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .zero)
    window.title = title
    return window
  }
}
