import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

@MainActor
final class PensieveSettingsWindowControllerTests: XCTestCase {
  func testControllerSealsTheSettingsWindowFromTabbingAndRestoration() {
    let window = makeWindow()
    window.title = "General"
    window.tabbingMode = .preferred
    window.tabbingIdentifier = WindowChromeRecipe.documentTabbingIdentifier
    window.isRestorable = true
    let controller = PensieveSettingsWindowController(
      window: window,
      selection: PensieveSettingsSelection())
    defer { close(window) }

    XCTAssertEqual(window.title, "Settings")
    XCTAssertEqual(window.identifier, PensieveSettingsWindowController.windowIdentifier)
    XCTAssertEqual(
      window.accessibilityIdentifier(),
      PensieveSettingsWindowController.windowIdentifier.rawValue)
    XCTAssertEqual(window.tabbingMode, .disallowed)
    XCTAssertEqual(window.tabbingIdentifier, "")
    XCTAssertFalse(window.isRestorable)
    XCTAssertFalse(window.isReleasedWhenClosed)
    XCTAssertFalse(
      DocumentWindowOwnership.isDocumentHost(window),
      "Settings must never become a document-tab host")
    XCTAssertTrue(controller.window === window)
  }

  func testCloseAndRepeatedPresentationReuseOneNativeWindowAndSelectTheRequestedPane() {
    let window = makeWindow()
    let selection = PensieveSettingsSelection()
    let controller = PensieveSettingsWindowController(window: window, selection: selection)
    defer { close(window) }

    let first = controller.prepareForPresentation(section: .ai)
    XCTAssertTrue(first === window)
    XCTAssertEqual(selection.selectedSection, .ai)

    window.close()
    let reopened = controller.prepareForPresentation(section: .general)

    XCTAssertTrue(reopened === first, "close/reopen created a second Settings NSWindow")
    XCTAssertTrue(controller.window === first)
    XCTAssertEqual(selection.selectedSection, .general)
    XCTAssertEqual(reopened.tabbingMode, .disallowed)
    XCTAssertFalse(reopened.isRestorable)
  }

  func testCommandCommaSelectsGeneralAndOnboardingSelectsAI() {
    var requestedSections: [PensieveSettingsSection] = []
    let applicationLane = ApplicationCommandLane(
      resolveTermination: { .terminateCancel },
      terminate: {},
      showAbout: {},
      showSettings: {
        requestedSections.append($0)
        return .presented
      })
    let onboardingLane = ProviderOnboardingSettingsLane {
      requestedSections.append($0)
      return .presented
    }

    XCTAssertEqual(applicationLane.openSettings(), .presented)
    XCTAssertEqual(onboardingLane.configure(), .presented)

    XCTAssertEqual(requestedSections, [.general, .ai])
  }

  func testNativeModalStateBlocksEveryAppKitModalRelationship() {
    let allowed = PensieveSettingsNativeModalState(
      hasApplicationModalWindow: false,
      hasAttachedSheet: false,
      hasSheetParent: false)
    XCTAssertFalse(allowed.blocksSettingsPresentation)

    for blocked in [
      PensieveSettingsNativeModalState(
        hasApplicationModalWindow: true,
        hasAttachedSheet: false,
        hasSheetParent: false),
      PensieveSettingsNativeModalState(
        hasApplicationModalWindow: false,
        hasAttachedSheet: true,
        hasSheetParent: false),
      PensieveSettingsNativeModalState(
        hasApplicationModalWindow: false,
        hasAttachedSheet: false,
        hasSheetParent: true),
    ] {
      XCTAssertTrue(blocked.blocksSettingsPresentation)
    }
  }

  func testBlockedPresentationDoesNotSelectActivateOrOrderSettings() {
    let window = makeWindow()
    let blocker = makeWindow()
    let selection = PensieveSettingsSelection(selectedSection: .general)
    var presentedWindows: [NSWindow] = []
    var reportedResults: [PensieveSettingsPresentationResult] = []
    var reportedOwner: NSWindow?
    let controller = PensieveSettingsWindowController(
      window: window,
      selection: selection,
      blockingNativeModalOwner: { blocker },
      presentWindow: { presentedWindows.append($0) },
      reportBlockedPresentation: { result, owner in
        reportedResults.append(result)
        reportedOwner = owner
        return true
      })
    defer {
      close(blocker)
      close(window)
    }

    XCTAssertEqual(controller.show(section: .ai), .blockedByNativeModalSurface)
    XCTAssertEqual(selection.selectedSection, .general)
    XCTAssertTrue(presentedWindows.isEmpty)
    XCTAssertEqual(reportedResults, [.blockedByNativeModalSurface])
    XCTAssertTrue(reportedOwner === blocker)
    XCTAssertNil(selection.presentationError)
    assertUnpublished(window)
    assertUnpublished(blocker)
  }

  func testBlockedPresentationFallsBackToSettingsWhenNoDocumentReporterExists() {
    let window = makeWindow()
    let blocker = makeWindow()
    let selection = PensieveSettingsSelection(selectedSection: .general)
    let isBlocked = MainActorTestValue(true)
    var presentedWindows: [NSWindow] = []
    let controller = PensieveSettingsWindowController(
      window: window,
      selection: selection,
      blockingNativeModalOwner: { isBlocked.value ? blocker : nil },
      presentWindow: { presentedWindows.append($0) },
      reportBlockedPresentation: { _, _ in false })
    defer {
      close(blocker)
      close(window)
    }

    XCTAssertEqual(controller.show(section: .ai), .blockedByNativeModalSurface)
    XCTAssertEqual(
      selection.presentationError,
      PensieveSettingsPresentationResult.blockedByNativeModalSurface.userMessage)
    XCTAssertEqual(selection.selectedSection, .general)
    XCTAssertTrue(presentedWindows.isEmpty)
    assertUnpublished(window)
    assertUnpublished(blocker)

    isBlocked.value = false
    XCTAssertEqual(controller.show(section: .ai), .presented)
    XCTAssertNil(selection.presentationError)
    XCTAssertEqual(selection.selectedSection, .ai)
    XCTAssertEqual(presentedWindows.count, 1)
    assertUnpublished(window)
    assertUnpublished(blocker)
  }

  func testSettingsPresentationErrorCanBeDismissedWithoutAWindow() {
    let selection = PensieveSettingsSelection(
      presentationError: "Close the current dialog before opening Settings.")

    selection.dismissPresentationError()

    XCTAssertNil(selection.presentationError)
  }

  func testPreparingTheRetainedWindowDoesNotPretendTheStoredErrorWasPresented() {
    let window = makeWindow()
    let message = "Close the current dialog before opening Settings."
    let selection = PensieveSettingsSelection(presentationError: message)
    let controller = PensieveSettingsWindowController(window: window, selection: selection)
    defer { close(window) }

    _ = controller.prepareForPresentation(section: .ai)

    XCTAssertEqual(selection.presentationError, message)
    XCTAssertEqual(selection.selectedSection, .ai)
    assertUnpublished(window)
  }

  func testPresentedRequestUsesOneOrderingPrimitiveAfterPassingTheGateway() {
    let window = makeWindow()
    let selection = PensieveSettingsSelection()
    var presentedWindows: [NSWindow] = []
    let controller = PensieveSettingsWindowController(
      window: window,
      selection: selection,
      blockingNativeModalOwner: { nil },
      presentWindow: { presentedWindows.append($0) },
      reportBlockedPresentation: { _, _ in
        XCTFail("An allowed Settings request reported a block")
        return true
      })
    defer { close(window) }

    XCTAssertEqual(controller.show(section: .ai), .presented)
    XCTAssertEqual(selection.selectedSection, .ai)
    XCTAssertEqual(presentedWindows.count, 1)
    XCTAssertTrue(presentedWindows.first === window)
    assertUnpublished(window)
  }

  func testSettingsCommandSurfaceTakesPrecedenceOverALiveDocumentFallback() {
    XCTAssertEqual(
      PensieveCommandSurfaceRoute.resolve(
        settingsOwnsSurface: true,
        hasDocumentTarget: true),
      .settings)
    XCTAssertEqual(
      PensieveCommandSurfaceRoute.resolve(
        settingsOwnsSurface: false,
        hasDocumentTarget: true),
      .document)
    XCTAssertEqual(
      PensieveCommandSurfaceRoute.resolve(
        settingsOwnsSurface: false,
        hasDocumentTarget: false),
      .zeroWindow)
  }

  func testSettingsCloseLaneNeverNeedsADocumentController() {
    var closeCount = 0
    let lane = SettingsWindowCommandLane {
      closeCount += 1
    }

    lane.close()

    XCTAssertEqual(closeCount, 1)
  }

  func testSettingsControllerTracksCommandOwnershipByExactKeyWindowIdentity() {
    let settingsWindow = makeWindow()
    let documentWindow = makeWindow()
    let controller = PensieveSettingsWindowController(
      window: settingsWindow,
      selection: PensieveSettingsSelection(),
      blockingNativeModalOwner: { nil },
      presentWindow: { _ in },
      reportBlockedPresentation: { _, _ in true })
    defer {
      close(documentWindow)
      close(settingsWindow)
    }

    controller.synchronizeCommandSurfaceOwnership(keyWindow: settingsWindow)
    XCTAssertTrue(controller.ownsCommandSurface)

    controller.synchronizeCommandSurfaceOwnership(keyWindow: documentWindow)
    XCTAssertFalse(controller.ownsCommandSurface)

    controller.synchronizeCommandSurfaceOwnership(keyWindow: nil)
    XCTAssertFalse(controller.ownsCommandSurface)
    assertUnpublished(settingsWindow)
    assertUnpublished(documentWindow)
  }

  func testOnboardingSettingsTransitionWaitsForNativeSheetDetachmentAndRunsOnce() async {
    let parent = makeWindow()
    let sheet = makeWindow()
    let isDetached = MainActorTestValue(false)
    let transition = makeTransition(parent: parent, sheet: sheet) {
      isDetached.value
    }
    var completionCount = 0
    let completed = expectation(description: "Settings handoff completed")
    defer {
      transition.cancel()
      close(sheet)
      close(parent)
    }

    XCTAssertTrue(
      transition.arm(
        hostWindow: parent,
        onFailure: { failure in
          XCTFail("Settings handoff failed unexpectedly: \(failure)")
        },
        completion: {
          XCTAssertTrue(isDetached.value)
          completionCount += 1
          completed.fulfill()
        }))

    let foreignWindow = makeWindow()
    NotificationCenter.default.post(
      name: NSWindow.didEndSheetNotification,
      object: foreignWindow)
    close(foreignWindow)
    await nextMainQueueTurn()
    XCTAssertEqual(completionCount, 0, "Settings opened before AppKit detached the sheet")

    isDetached.value = true
    NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: parent)
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(completionCount, 1)

    NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: parent)
    NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: sheet)
    await nextMainQueueTurn()
    XCTAssertEqual(completionCount, 1, "The one-shot Settings handoff ran more than once")
  }

  func testOnboardingSettingsTransitionRefusesToOpenWithoutAnAttachedSheet() async {
    let parent = makeWindow()
    let transition = ProviderOnboardingSettingsTransition()
    var completionCount = 0
    defer {
      transition.cancel()
      close(parent)
    }

    XCTAssertFalse(
      transition.arm(
        hostWindow: parent,
        onFailure: { _ in
          XCTFail("An unarmed transition reported failure")
        },
        completion: {
          completionCount += 1
        }))

    await nextMainQueueTurn()
    XCTAssertEqual(completionCount, 0)
  }

  func testConfigureKeepsOnboardingOpenWhenNativeHandoffCannotArm() {
    let parent = makeWindow()
    let transition = ProviderOnboardingSettingsTransition()
    var isPresented = true
    var didShowSettings = false
    let view = ProviderOnboardingView(
      isPresented: Binding(
        get: { isPresented },
        set: { isPresented = $0 }),
      hostWindow: parent,
      settingsTransition: transition,
      settingsLane: ProviderOnboardingSettingsLane { _ in
        didShowSettings = true
        return .presented
      })
    defer {
      transition.cancel()
      close(parent)
    }

    XCTAssertFalse(view.beginConfiguration())
    XCTAssertTrue(isPresented, "Configure dismissed onboarding after native arming failed")
    XCTAssertFalse(didShowSettings)
  }

  func testOnboardingSettingsTransitionRechecksRelationshipsAfterDidEndSheet() async {
    let notificationCenter = NotificationCenter()
    let parent = makeWindow()
    let sheet = makeWindow()
    let isDetached = MainActorTestValue(false)
    let transition = makeTransition(
      notificationCenter: notificationCenter,
      parent: parent,
      sheet: sheet
    ) {
      isDetached.value
    }
    let completed = expectation(description: "Settings handoff completed after delayed bookkeeping")
    defer {
      transition.cancel()
      close(sheet)
      close(parent)
    }

    XCTAssertTrue(
      transition.arm(
        hostWindow: parent,
        onFailure: { failure in
          XCTFail("Settings handoff failed unexpectedly: \(failure)")
        },
        completion: {
          completed.fulfill()
        }))

    notificationCenter.post(name: NSWindow.didEndSheetNotification, object: parent)
    await nextMainQueueTurn()

    isDetached.value = true
    await fulfillment(of: [completed], timeout: 1)
  }

  func testOnboardingSettingsTransitionUsesNativeDetachmentWithoutWaitingForNotification()
    async
  {
    let notificationCenter = NotificationCenter()
    let parent = makeWindow()
    let sheet = makeWindow()
    let isDetached = MainActorTestValue(false)
    let transition = makeTransition(
      notificationCenter: notificationCenter,
      parent: parent,
      sheet: sheet
    ) {
      isDetached.value
    }
    var completionCount = 0
    let completed = expectation(description: "Settings handoff completed after native detachment")
    defer {
      transition.cancel()
      close(sheet)
      close(parent)
    }

    XCTAssertTrue(
      transition.arm(
        hostWindow: parent,
        onFailure: { failure in
          XCTFail("Settings handoff failed unexpectedly: \(failure)")
        },
        completion: {
          completionCount += 1
          completed.fulfill()
        }))

    isDetached.value = true
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(completionCount, 1)
  }

  func testInvalidRearmDoesNotEraseAnAlreadyArmedHandoff() async {
    let notificationCenter = NotificationCenter()
    let parent = makeWindow()
    let sheet = makeWindow()
    var hasAttachedSheet = true
    let isDetached = MainActorTestValue(false)
    let transition = ProviderOnboardingSettingsTransition(
      notificationCenter: notificationCenter,
      attachedSheetProvider: { window in
        window === parent && hasAttachedSheet ? sheet : nil
      },
      isDetachedProvider: { host, capturedSheet in
        host === parent && capturedSheet === sheet && isDetached.value
      })
    let completed = expectation(description: "Original handoff survived invalid rearm")
    defer {
      transition.cancel()
      close(sheet)
      close(parent)
    }

    XCTAssertTrue(
      transition.arm(
        hostWindow: parent,
        onFailure: { failure in
          XCTFail("Original Settings handoff failed unexpectedly: \(failure)")
        },
        completion: {
          completed.fulfill()
        }))
    hasAttachedSheet = false
    XCTAssertFalse(
      transition.arm(
        hostWindow: parent,
        onFailure: { _ in
          XCTFail("Invalid replacement handoff reported failure")
        },
        completion: {
          XCTFail("Invalid replacement handoff ran")
        }))

    isDetached.value = true
    notificationCenter.post(name: NSWindow.didEndSheetNotification, object: parent)
    await fulfillment(of: [completed], timeout: 1)
  }

  func testValidRearmReplacesTheCapturedPairAndStaleScheduledCheckCannotComplete() {
    let notificationCenter = NotificationCenter()
    let scheduler = TransitionScheduler()
    let parentA = makeWindow()
    let sheetA = makeWindow()
    let parentB = makeWindow()
    let sheetB = makeWindow()
    let detachedPair = MainActorTestValue<ObjectIdentifier?>(nil)
    let transition = ProviderOnboardingSettingsTransition(
      notificationCenter: notificationCenter,
      attachedSheetProvider: { window in
        switch window {
        case parentA: return sheetA
        case parentB: return sheetB
        default: return nil
        }
      },
      isDetachedProvider: { host, sheet in
        detachedPair.value == ObjectIdentifier(host)
          && host === parentB
          && sheet === sheetB
      },
      nowProvider: { scheduler.now },
      scheduleAfter: { delay, operation in
        scheduler.schedule(after: delay, operation: operation)
      },
      retryInterval: 0.05,
      timeout: 1)
    var completionA = 0
    var completionB = 0
    defer {
      transition.cancel()
      close(sheetB)
      close(parentB)
      close(sheetA)
      close(parentA)
    }

    XCTAssertTrue(
      transition.arm(
        hostWindow: parentA,
        onFailure: { failure in
          XCTFail("Replaced Settings handoff A failed unexpectedly: \(failure)")
        },
        completion: { completionA += 1 }))
    XCTAssertTrue(
      transition.arm(
        hostWindow: parentB,
        onFailure: { failure in
          XCTFail("Replacement Settings handoff B failed unexpectedly: \(failure)")
        },
        completion: { completionB += 1 }))
    detachedPair.value = ObjectIdentifier(parentB)

    scheduler.runNext()
    XCTAssertEqual(completionA, 0, "A stale scheduled check completed the replaced pair")
    XCTAssertEqual(completionB, 0)

    scheduler.runNext()
    XCTAssertEqual(completionA, 0)
    XCTAssertEqual(completionB, 1)
    XCTAssertTrue(scheduler.isEmpty)
  }

  func testConfigureReportsTerminalTransitionFailureWithoutAttachingAnotherSheet() {
    let notificationCenter = NotificationCenter()
    let scheduler = TransitionScheduler()
    let parent = makeWindow()
    let sheet = makeWindow()
    let transition = ProviderOnboardingSettingsTransition(
      notificationCenter: notificationCenter,
      attachedSheetProvider: { window in
        window === parent ? sheet : nil
      },
      isDetachedProvider: { _, _ in false },
      nowProvider: { scheduler.now },
      scheduleAfter: { delay, operation in
        scheduler.schedule(after: delay, operation: operation)
      },
      retryInterval: 0.05,
      timeout: 0.1)
    var isPresented = true
    var didShowSettings = false
    var failures: [ProviderOnboardingSettingsTransition.Failure] = []
    let view = ProviderOnboardingView(
      isPresented: Binding(
        get: { isPresented },
        set: { isPresented = $0 }),
      hostWindow: parent,
      settingsTransition: transition,
      settingsLane: ProviderOnboardingSettingsLane { _ in
        didShowSettings = true
        return .presented
      },
      onSettingsTransitionFailure: { failures.append($0) })
    defer {
      transition.cancel()
      close(sheet)
      close(parent)
    }

    XCTAssertTrue(view.beginConfiguration())
    XCTAssertFalse(isPresented, "Configure did not dismiss the armed onboarding sheet")
    XCTAssertEqual(scheduler.scheduledDelays, [0.05])

    scheduler.runNext()
    XCTAssertFalse(isPresented)
    scheduler.runNext()

    XCTAssertFalse(
      isPresented,
      "A terminal native failure asked SwiftUI to attach another onboarding sheet")
    XCTAssertFalse(didShowSettings)
    XCTAssertEqual(failures, [.sheetDidNotDetach])
  }

  func testConfigureReportsASecondModalBlockOnTheOriginatingDocumentSurface() {
    let notificationCenter = NotificationCenter()
    let scheduler = TransitionScheduler()
    let parent = makeWindow()
    let sheet = makeWindow()
    let isDetached = MainActorTestValue(false)
    let transition = ProviderOnboardingSettingsTransition(
      notificationCenter: notificationCenter,
      attachedSheetProvider: { window in
        window === parent ? sheet : nil
      },
      isDetachedProvider: { host, capturedSheet in
        host === parent && capturedSheet === sheet && isDetached.value
      },
      nowProvider: { scheduler.now },
      scheduleAfter: { delay, operation in
        scheduler.schedule(after: delay, operation: operation)
      },
      retryInterval: 0.05,
      timeout: 1)
    var isPresented = true
    var settingsRequests = 0
    var presentationFailures: [PensieveSettingsPresentationResult] = []
    let view = ProviderOnboardingView(
      isPresented: Binding(
        get: { isPresented },
        set: { isPresented = $0 }),
      hostWindow: parent,
      settingsTransition: transition,
      settingsLane: ProviderOnboardingSettingsLane { _ in
        settingsRequests += 1
        return .blockedByNativeModalSurface
      },
      onSettingsPresentationFailure: { presentationFailures.append($0) })
    defer {
      transition.cancel()
      close(sheet)
      close(parent)
    }

    XCTAssertTrue(view.beginConfiguration())
    XCTAssertFalse(isPresented)
    isDetached.value = true
    scheduler.runNext()

    XCTAssertEqual(settingsRequests, 1)
    XCTAssertEqual(presentationFailures, [.blockedByNativeModalSurface])
    XCTAssertEqual(parent.windowNumber, -1)
    XCTAssertEqual(sheet.windowNumber, -1)
  }

  func testTransitionReportsDetachTimeoutAfterBoundedWallClockRetries() {
    let notificationCenter = NotificationCenter()
    let scheduler = TransitionScheduler()
    let parent = makeWindow()
    let sheet = makeWindow()
    let transition = ProviderOnboardingSettingsTransition(
      notificationCenter: notificationCenter,
      attachedSheetProvider: { window in
        window === parent ? sheet : nil
      },
      isDetachedProvider: { _, _ in false },
      nowProvider: { scheduler.now },
      scheduleAfter: { delay, operation in
        scheduler.schedule(after: delay, operation: operation)
      },
      retryInterval: 0.25,
      timeout: 1)
    var failures: [ProviderOnboardingSettingsTransition.Failure] = []
    defer {
      transition.cancel()
      close(sheet)
      close(parent)
    }

    XCTAssertTrue(
      transition.arm(
        hostWindow: parent,
        onFailure: { failures.append($0) },
        completion: {
          XCTFail("A transition with a still-attached sheet completed")
        }))

    for expectedTime in [0.25, 0.5, 0.75] {
      scheduler.runNext()
      XCTAssertEqual(scheduler.now, expectedTime, accuracy: 0.001)
      XCTAssertTrue(failures.isEmpty)
    }
    scheduler.runNext()

    XCTAssertEqual(scheduler.now, 1, accuracy: 0.001)
    XCTAssertEqual(failures, [.sheetDidNotDetach])
    XCTAssertTrue(scheduler.isEmpty)
  }

  func testTransitionReportsDetachTimeoutAfterCapturedDidEnd() {
    let notificationCenter = NotificationCenter()
    let scheduler = TransitionScheduler()
    let parent = makeWindow()
    let sheet = makeWindow()
    let transition = ProviderOnboardingSettingsTransition(
      notificationCenter: notificationCenter,
      attachedSheetProvider: { window in
        window === parent ? sheet : nil
      },
      isDetachedProvider: { _, _ in false },
      nowProvider: { scheduler.now },
      scheduleAfter: { delay, operation in
        scheduler.schedule(after: delay, operation: operation)
      },
      retryInterval: 0.05,
      timeout: 0.1)
    var failures: [ProviderOnboardingSettingsTransition.Failure] = []
    defer {
      transition.cancel()
      close(sheet)
      close(parent)
    }

    XCTAssertTrue(
      transition.arm(
        hostWindow: parent,
        onFailure: { failures.append($0) },
        completion: {
          XCTFail("A still-attached sheet completed its transition")
        }))
    notificationCenter.post(name: NSWindow.didEndSheetNotification, object: parent)
    scheduler.runNext()
    scheduler.runNext()

    XCTAssertEqual(failures, [.sheetDidNotDetach])
    XCTAssertTrue(scheduler.isEmpty)
  }

  func testTransitionRetainsCapturedPairWithoutExternalStrongOwnersUntilFailure() {
    let notificationCenter = NotificationCenter()
    let scheduler = TransitionScheduler()
    var parent: NSWindow? = makeWindow()
    var sheet: NSWindow? = makeWindow()
    let retainedParent = WeakWindowBox(parent)
    let retainedSheet = WeakWindowBox(sheet)
    let sheetBox = WeakWindowBox(sheet)
    let transition = ProviderOnboardingSettingsTransition(
      notificationCenter: notificationCenter,
      attachedSheetProvider: { _ in sheetBox.window },
      isDetachedProvider: { _, _ in false },
      nowProvider: { scheduler.now },
      scheduleAfter: { delay, operation in
        scheduler.schedule(after: delay, operation: operation)
      },
      retryInterval: 0.05,
      timeout: 0.1)
    var failures: [ProviderOnboardingSettingsTransition.Failure] = []
    defer {
      transition.cancel()
      if let window = retainedSheet.window { close(window) }
      if let window = retainedParent.window { close(window) }
    }

    XCTAssertTrue(
      transition.arm(
        hostWindow: parent,
        onFailure: { failures.append($0) },
        completion: {
          XCTFail("A transition without native teardown completed")
        }))
    parent = nil
    sheet = nil

    XCTAssertNotNil(retainedParent.window, "The armed transition dropped its captured host")
    XCTAssertNotNil(retainedSheet.window, "The armed transition dropped its captured sheet")
    scheduler.runNext()
    XCTAssertNotNil(
      retainedParent.window, "A retry dropped its captured host before terminal resolution")
    XCTAssertNotNil(
      retainedSheet.window, "A retry dropped its captured sheet before terminal resolution")
    scheduler.runNext()

    XCTAssertEqual(failures, [.sheetDidNotDetach])
    XCTAssertTrue(scheduler.isEmpty)
  }

  func testSheetDetachmentFailureProvidesAnActionableNonModalMessage() {
    let message = ProviderOnboardingSettingsTransition.Failure.sheetDidNotDetach.userMessage

    XCTAssertTrue(message.contains("Settings could not open"))
    XCTAssertTrue(message.contains("Pensieve > Settings"))
  }

  private func makeTransition(
    notificationCenter: NotificationCenter = .default,
    parent: NSWindow,
    sheet: NSWindow,
    isDetached: @escaping @MainActor () -> Bool
  ) -> ProviderOnboardingSettingsTransition {
    ProviderOnboardingSettingsTransition(
      notificationCenter: notificationCenter,
      attachedSheetProvider: { window in
        window === parent ? sheet : nil
      },
      isDetachedProvider: { host, capturedSheet in
        host === parent && capturedSheet === sheet && isDetached()
      })
  }

  private func nextMainQueueTurn() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        continuation.resume()
      }
    }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -9000, y: -9000, width: 560, height: 600),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    assertUnpublished(window)
    return window
  }

  private func close(_ window: NSWindow) {
    assertUnpublished(window)
    window.close()
    assertUnpublished(window)
  }

  private func assertUnpublished(_ window: NSWindow) {
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(window.windowNumber, -1)
  }

  @MainActor
  private final class WeakWindowBox {
    weak var window: NSWindow?

    init(_ window: NSWindow?) {
      self.window = window
    }
  }

  @MainActor
  private final class TransitionScheduler {
    private struct ScheduledOperation {
      let delay: TimeInterval
      let operation: @MainActor () -> Void
    }

    private var operations: [ScheduledOperation] = []
    private(set) var now: TimeInterval = 0
    private(set) var scheduledDelays: [TimeInterval] = []

    var isEmpty: Bool { operations.isEmpty }

    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () -> Void) {
      scheduledDelays.append(delay)
      operations.append(ScheduledOperation(delay: delay, operation: operation))
    }

    func runNext() {
      guard !operations.isEmpty else {
        XCTFail("No scheduled transition check was available")
        return
      }
      let scheduled = operations.removeFirst()
      now += scheduled.delay
      scheduled.operation()
    }
  }
}
