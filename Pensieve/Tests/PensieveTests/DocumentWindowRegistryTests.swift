import AppKit
import XCTest

@testable import Pensieve

final class DocumentWindowRegistryTests: XCTestCase {
  @MainActor
  func testOpeningSameStandardizedFileTwiceFocusesExistingWindow() throws {
    let window = Self.makeWindow()
    defer { window.close() }
    let canonical = URL(fileURLWithPath: "/tmp/pensieve-same-file.md").standardizedFileURL
    let aliased = URL(fileURLWithPath: "/tmp/identity/../pensieve-same-file.md")
    var factoryCalls = 0
    var activations = 0
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("open should not defer") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in activations += 1 },
      currentMergeTarget: { nil },
      makeDocumentWindow: { _, _ in
        factoryCalls += 1
        return window
      })

    registry.open(DocumentRef(id: canonical))
    registry.open(DocumentRef(id: aliased))

    XCTAssertEqual(factoryCalls, 1)
    XCTAssertEqual(activations, 2)
    XCTAssertEqual(registry.openDocuments.map(\.identity), [.file(canonical)])
  }

  @MainActor
  func testDraftDescriptorsPublishAndSaveAsTransitionsAtomically() throws {
    let window = Self.makeWindow()
    let recoveredWindow = Self.makeWindow()
    defer {
      window.close()
      recoveredWindow.close()
    }
    let registry = Self.makeIdentityRegistry()
    let draftID = DocumentIdentity.untitled(UUID())
    let recoveredID = DocumentIdentity.recovered(UUID())
    let savedURL = URL(fileURLWithPath: "/tmp/pensieve-descriptor-saved.md").standardizedFileURL

    XCTAssertTrue(
      registry.attach(
        window,
        identity: draftID,
        documentID: nil,
        title: "Untitled.md",
        isDirty: true,
        hasEditableBuffer: true))
    XCTAssertEqual(registry.openDocuments.map(\.identity), [draftID])
    XCTAssertEqual(registry.openDocuments.first?.displayTitle, "Untitled.md")
    XCTAssertNil(registry.openDocuments.first?.fileURL)
    XCTAssertTrue(registry.openDocuments.first?.window === window)
    XCTAssertTrue(
      registry.attach(
        recoveredWindow,
        identity: recoveredID,
        documentID: nil,
        title: "Recovered.md",
        isDirty: true,
        hasEditableBuffer: true))

    XCTAssertTrue(
      registry.attach(
        window,
        identity: .file(savedURL),
        documentID: savedURL,
        title: "saved",
        representedURL: savedURL,
        isDirty: false,
        hasEditableBuffer: true))

    XCTAssertEqual(registry.openDocuments.count, 2)
    XCTAssertEqual(registry.openDocuments.map(\.identity), [.file(savedURL), recoveredID])
    XCTAssertEqual(registry.openDocuments.first?.identity, .file(savedURL))
    XCTAssertEqual(registry.openDocuments.first?.fileURL, savedURL)
    XCTAssertTrue(registry.openDocuments.first?.window === window)
  }

  @MainActor
  func testRecoveredAndIndependentUntitledSessionsNeverCollapse() throws {
    let firstWindow = Self.makeWindow()
    let secondWindow = Self.makeWindow()
    let recoveredWindow = Self.makeWindow()
    defer {
      firstWindow.close()
      secondWindow.close()
      recoveredWindow.close()
    }
    let registry = Self.makeIdentityRegistry()
    let first = DocumentIdentity.untitled(UUID())
    let second = DocumentIdentity.untitled(UUID())
    let recovered = DocumentIdentity.recovered(UUID())

    XCTAssertTrue(
      registry.attach(
        firstWindow, identity: first, documentID: nil, title: "Untitled.md",
        hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        secondWindow, identity: second, documentID: nil, title: "Untitled.md",
        hasEditableBuffer: true))
    XCTAssertTrue(
      registry.attach(
        recoveredWindow, identity: recovered, documentID: nil, title: "Recovered.md",
        isDirty: true, hasEditableBuffer: true))

    XCTAssertEqual(registry.openDocuments.map(\.identity), [first, second, recovered])
  }

  @MainActor
  func testForcedDuplicateIdentityIsRejectedAndCloseRemovesOnlyItsDescriptor() throws {
    let forcedID = UUID()
    let forced = DocumentIdentity.untitled(forcedID)
    let firstSession = DocumentSession.untitled(identityID: forcedID)
    let duplicateSession = DocumentSession.untitled(identityID: forcedID)
    let firstWindow = Self.makeWindow()
    let duplicateWindow = Self.makeWindow()
    defer {
      firstWindow.close()
      duplicateWindow.close()
    }
    var closed: [ObjectIdentifier] = []
    let registry = Self.makeIdentityRegistry { closed.append(ObjectIdentifier($0)) }

    XCTAssertEqual(firstSession.identity, duplicateSession.identity)
    XCTAssertTrue(
      registry.attach(
        firstWindow, identity: firstSession.identity, documentID: nil,
        title: "First.md", hasEditableBuffer: true))
    XCTAssertFalse(
      registry.attach(
        duplicateWindow, identity: duplicateSession.identity, documentID: nil,
        title: "Duplicate.md", hasEditableBuffer: true))
    XCTAssertEqual(registry.openDocuments.count, 1)
    XCTAssertTrue(registry.openDocuments.first?.window === firstWindow)

    registry.closeDocument(forced)
    XCTAssertEqual(closed, [ObjectIdentifier(firstWindow)])
    registry.reconcileClosedWindow(firstWindow)
    XCTAssertTrue(registry.openDocuments.isEmpty)
  }

  @MainActor
  func testRejectedDuplicateReattachesAfterOwnerWindowCloses() throws {
    let forcedID = UUID()
    let forced = DocumentIdentity.untitled(forcedID)
    let ownerWindow = Self.makeWindow()
    let duplicateWindow = Self.makeWindow()
    defer {
      ownerWindow.close()
      duplicateWindow.close()
    }
    var closed: [ObjectIdentifier] = []
    let registry = Self.makeIdentityRegistry { closed.append(ObjectIdentifier($0)) }

    // Owner takes the identity; the duplicate is rejected while the owner holds it.
    XCTAssertTrue(
      registry.attach(
        ownerWindow, identity: forced, documentID: nil,
        title: "Owner.md", hasEditableBuffer: true))
    XCTAssertFalse(
      registry.attach(
        duplicateWindow, identity: forced, documentID: nil,
        title: "Duplicate.md", hasEditableBuffer: true))
    XCTAssertEqual(registry.openDocuments.count, 1)
    XCTAssertTrue(registry.openDocuments.first?.window === ownerWindow)

    // Owner closes → the identity is freed from the registry.
    registry.closeDocument(forced)
    XCTAssertEqual(closed, [ObjectIdentifier(ownerWindow)])
    registry.reconcileClosedWindow(ownerWindow)
    XCTAssertTrue(registry.openDocuments.isEmpty)

    // The duplicate's coordinator retries attach (cache was never committed on
    // rejection): it must now be accepted and land in Open Files, not stay
    // orphaned outside the registry.
    XCTAssertTrue(
      registry.attach(
        duplicateWindow, identity: forced, documentID: nil,
        title: "Duplicate.md", hasEditableBuffer: true))
    XCTAssertEqual(registry.openDocuments.map(\.identity), [forced])
    XCTAssertTrue(registry.openDocuments.first?.window === duplicateWindow)
  }

  @MainActor
  func testOpenTabDocumentIDsRoundTripAcrossOpenAttachSwitchAndWillCloseReconcile() throws {
    let alphaID = URL(fileURLWithPath: "/tmp/pensieve-open-tabs-alpha.md").standardizedFileURL
    let betaID = URL(fileURLWithPath: "/tmp/pensieve-open-tabs-beta.md").standardizedFileURL
    let window = Self.makeWindow()
    defer { window.close() }
    var deferredWork: [() -> Void] = []

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      makeDocumentWindow: { ref, _ in
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
    XCTAssertEqual(
      deferredWork.count,
      1,
      "the process-wide close route must request one deferred launcher reconciliation")
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
  func testGlobalCloseOfLastDocumentSchedulesLauncherReopen() throws {
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-global-close.md").standardizedFileURL
    let documentWindow = Self.makeWindow()
    let launcherWindow = Self.makeWindow()
    defer {
      documentWindow.close()
      launcherWindow.close()
    }

    var deferredWork: [() -> Void] = []
    var factoryRefs: [DocumentRef?] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [documentWindow] },
      makeDocumentWindow: { ref, _ in
        factoryRefs.append(ref)
        return ref == nil ? launcherWindow : documentWindow
      })

    registry.open(DocumentRef(id: documentID))
    registry.handleWindowClosed(documentWindow, tombstonePolicy: .reusableWindow)

    XCTAssertEqual(deferredWork.count, 1, "the process-wide close route must request reopening")
    guard let reopen = deferredWork.first else {
      return XCTFail("the process-wide close route did not request reopening")
    }
    reopen()
    XCTAssertEqual(factoryRefs.compactMap { $0 }.map(\.id), [documentID])
    XCTAssertEqual(factoryRefs.filter { $0 == nil }.count, 1)

    XCTAssertTrue(
      registry.attach(documentWindow, documentID: documentID),
      "a reusable scene window must remain eligible to reattach after global close")
  }

  @MainActor
  func testGlobalCloseBeforeFactoryWiringKeepsDeferredLauncherRequest() throws {
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-early-global-close.md").standardizedFileURL
    let documentWindow = Self.makeWindow()
    let launcherWindow = Self.makeWindow()
    defer {
      documentWindow.close()
      launcherWindow.close()
    }

    var deferredWork: [() -> Void] = []
    var launcherFactoryCalls = 0
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [documentWindow] })

    XCTAssertTrue(registry.attach(documentWindow, documentID: documentID))
    registry.handleWindowClosed(documentWindow, tombstonePolicy: .reusableWindow)

    XCTAssertTrue(
      deferredWork.isEmpty,
      "the reopen cannot execute until the scene root wires the window factory")

    registry.makeDocumentWindow = { ref, _ in
      XCTAssertNil(ref)
      launcherFactoryCalls += 1
      return launcherWindow
    }
    XCTAssertEqual(
      deferredWork.count,
      1,
      "wiring the factory must release the one pending close-lifecycle request")
    guard let reopen = deferredWork.first else {
      return XCTFail("the early global close dropped its deferred launcher request")
    }
    reopen()

    XCTAssertEqual(launcherFactoryCalls, 1)
  }

  @MainActor
  func testDuplicateFactoryAndGlobalCloseSignalsScheduleOneLauncherReopen() throws {
    let documentID = URL(fileURLWithPath: "/tmp/pensieve-dual-close.md").standardizedFileURL
    let documentWindow = Self.makeWindow()
    let launcherWindow = Self.makeWindow()
    defer {
      documentWindow.close()
      launcherWindow.close()
    }

    var deferredWork: [() -> Void] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [] },
      makeDocumentWindow: { ref, _ in ref == nil ? launcherWindow : documentWindow })

    registry.open(DocumentRef(id: documentID))
    registry.handleWindowClosed(documentWindow, tombstonePolicy: .factoryWindow)
    registry.handleWindowClosed(documentWindow, tombstonePolicy: .reusableWindow)

    XCTAssertEqual(
      deferredWork.count, 1,
      "factory callback plus willClose must coalesce into one deferred launcher request")
    XCTAssertFalse(
      registry.attach(documentWindow, documentID: documentID),
      "a factory-tombstoned window must reject a late SwiftUI reattach")
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
      makeDocumentWindow: { ref, _ in
        factoryRefs.append(ref)
        return launcherWindow
      }
    )

    registry.openLauncherWindow(intent: .coldLaunch)

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
      makeDocumentWindow: { ref, _ in
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
    XCTAssertEqual(deferredWork.count, 1)
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
      makeDocumentWindow: { ref, _ in
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
      makeDocumentWindow: { _, _ in launcherWindow }
    )

    XCTAssertFalse(
      registry.applicationHasLiveWindow(),
      "an invisible untracked SwiftUI placeholder must not suppress the cold-start launcher")

    registry.openLauncherWindow(intent: .coldLaunch)

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
      makeDocumentWindow: { ref, _ in
        factoryRefs.append(ref)
        return ref?.id == alphaID ? alphaWindow : betaWindow
      }
    )

    registry.open(DocumentRef(id: alphaID))
    registry.open(DocumentRef(id: betaID))
    registry.handleDocumentWindowClosed(alphaWindow)
    XCTAssertTrue(deferredWork.isEmpty)
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
      makeDocumentWindow: { ref, _ in
        factoryRefs.append(ref)
        return docWindow
      }
    )

    registry.open(DocumentRef(id: docID))
    registry.beginTermination()
    registry.handleApplicationWindowClosed(docWindow)
    XCTAssertTrue(deferredWork.isEmpty)
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
  func testInPlaceSwitchToDuplicateReleasesStaleMappingOnRejection() throws {
    let alphaID = URL(fileURLWithPath: "/tmp/pensieve-stale-alpha.md").standardizedFileURL
    let betaID = URL(fileURLWithPath: "/tmp/pensieve-stale-beta.md").standardizedFileURL
    let switchingWindow = Self.makeWindow()
    let betaOwner = Self.makeWindow()
    defer {
      switchingWindow.close()
      betaOwner.close()
    }
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("attach should not defer outside modal UI") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil })

    // switchingWindow shows alpha; betaOwner owns beta.
    XCTAssertTrue(registry.attach(switchingWindow, documentID: alphaID))
    XCTAssertTrue(registry.attach(betaOwner, documentID: betaID))
    XCTAssertEqual(Set(registry.openTabDocumentIDs), [alphaID, betaID])

    // switchingWindow switches in place onto beta, which betaOwner already owns.
    XCTAssertFalse(
      registry.attach(switchingWindow, documentID: betaID),
      "an in-place switch onto an already-owned document must be rejected")

    // The rejection must release switchingWindow's stale alpha mapping: only
    // betaOwner's beta remains, so `open(alpha)` no longer targets this window.
    XCTAssertEqual(
      registry.openTabDocumentIDs,
      [betaID],
      "the rejected in-place switch must drop the window's stale previous-document mapping")
  }

  @MainActor
  func testDeferredAttachPreservesDirtyMetadataThroughModalTurn() throws {
    let docID = URL(fileURLWithPath: "/tmp/pensieve-deferred-dirty.md").standardizedFileURL
    let window = Self.makeWindow()
    defer { window.close() }

    var canMutate = false
    var deferredWork: [() -> Void] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { canMutate },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil })

    // A dirty file-backed attach arrives while a modal panel blocks tab
    // mutation: the descriptor publishes dirty, and the tab work is deferred.
    XCTAssertTrue(
      registry.attach(
        window,
        identity: .file(docID),
        documentID: docID,
        title: "dirty",
        representedURL: docID,
        isDirty: true,
        hasEditableBuffer: true))
    XCTAssertEqual(registry.openDocuments.first?.isDirty, true)
    XCTAssertEqual(deferredWork.count, 1)

    // Modal closes; the deferred attach runs. It must NOT re-publish the
    // descriptor as clean.
    canMutate = true
    for work in deferredWork { work() }

    XCTAssertEqual(
      registry.openDocuments.first?.isDirty,
      true,
      "the deferred attach must preserve the dirty metadata, not overwrite it with the default clean state")
  }

  /// The launcher sweep is a DEFERRED `asyncAfter`: once armed it cannot be cancelled, so a sweep
  /// scheduled moments before the user quits fires INSIDE the termination sequence's pumped run loop.
  /// Reaping a window there posts `NSWindow.willCloseNotification`, whose handler saves the window's
  /// document — a brand-new managed write arriving after the sequence has already flushed its windows
  /// and drained the index, i.e. behind the terminal checkpoint. `beginTermination()` already
  /// suppressed launcher REOPEN; it had to suppress the reap as well.
  ///
  /// Both halves are asserted against the same fixture, because "nothing was closed" is only evidence
  /// if the identical sweep closes something when the app is not terminating.
  @MainActor
  func testDeferredLauncherSweepStopsReapingOnceTerminationHasBegun() throws {
    let running = try makeSweepFixture()
    defer { running.dispose() }
    XCTAssertEqual(
      running.sweeps.count, 1,
      "fixture precondition: presenting a document must arm exactly one launcher sweep")
    running.sweeps.removeFirst()()
    XCTAssertEqual(
      running.closedIDs, [ObjectIdentifier(running.launcher)],
      "fixture precondition: while the app is running, the sweep must reap the redundant launcher — "
        + "otherwise the terminating case below proves nothing")

    let terminating = try makeSweepFixture()
    defer { terminating.dispose() }
    XCTAssertEqual(terminating.sweeps.count, 1)
    terminating.registry.beginTermination()
    terminating.sweeps.removeFirst()()
    XCTAssertTrue(
      terminating.closedIDs.isEmpty,
      "a sweep that fires during the quit must close nothing: every close posts willCloseNotification, "
        + "and that save would land after the termination sequence already drained and checkpointed")
  }

  /// A registry with one redundant empty launcher beside a presented document window, plus captured
  /// sweep closures — the exact state `closeEmptyLauncherWindows(except:)` arms during a normal open.
  @MainActor
  private final class SweepFixture {
    let registry: DocumentWindowRegistry
    let launcher: NSWindow
    let documentWindow: NSWindow
    var sweeps: [() -> Void] = []
    var closedIDs: [ObjectIdentifier] = []

    init(launcher: NSWindow, documentWindow: NSWindow, documentID: URL) {
      self.launcher = launcher
      self.documentWindow = documentWindow
      // Built before `registry` so the closures below can capture it; the registry is the only thing
      // that ever calls them, and it is created on the next line.
      var recordSweep: ((@escaping () -> Void) -> Void)!
      var recordClose: ((NSWindow) -> Void)!
      registry = DocumentWindowRegistry(
        canMutateWindowTabs: { true },
        scheduleDeferredMainWork: { _ in },
        scheduleLauncherWindowSweep: { recordSweep($0) },
        mergeWindowIntoTabs: { _, _ in },
        orderAndActivateWindow: { _ in },
        currentMergeTarget: { nil },
        applicationWindows: { [launcher, documentWindow] },
        closeWindow: { recordClose($0) },
        makeDocumentWindow: { _, _ in documentWindow })
      recordSweep = { [weak self] work in self?.sweeps.append(work) }
      recordClose = { [weak self] window in self?.closedIDs.append(ObjectIdentifier(window)) }
      registry.open(DocumentRef(id: documentID))
    }

    func dispose() {
      launcher.close()
      documentWindow.close()
    }
  }

  @MainActor
  private func makeSweepFixture() throws -> SweepFixture {
    SweepFixture(
      // "Pensieve" with no represented URL is what makes it an UNTRACKED empty launcher, the shape
      // the sweep is allowed to reap.
      launcher: Self.makeWindow(title: "Pensieve"),
      documentWindow: Self.makeWindow(),
      documentID: URL(fileURLWithPath: "/tmp/pensieve-termination-sweep-\(UUID().uuidString).md")
        .standardizedFileURL)
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

  @MainActor
  private static func makeIdentityRegistry(
    closeWindow: @escaping @MainActor (NSWindow) -> Void = { _ in }
  ) -> DocumentWindowRegistry {
    DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("attach should not defer") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      closeWindow: closeWindow)
  }
}
