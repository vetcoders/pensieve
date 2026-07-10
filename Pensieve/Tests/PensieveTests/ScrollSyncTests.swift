import AppKit
import XCTest

@testable import Pensieve

final class ScrollSyncTests: XCTestCase {

  @MainActor
  func testScrollSyncDefaultsOffAndPersists() throws {
    let suiteName = "Pensieve.ScrollSyncTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let freshModel = DocumentWindowModel(defaults: defaults)
    XCTAssertFalse(freshModel.scrollSyncEnabled)

    freshModel.scrollSyncEnabled = true
    XCTAssertTrue(DocumentWindowModel(defaults: defaults).scrollSyncEnabled)
    XCTAssertTrue(AppState(defaults: defaults).scrollSyncEnabled)

    let appState = AppState(defaults: defaults)
    appState.scrollSyncEnabled = false
    XCTAssertFalse(DocumentWindowModel(defaults: defaults).scrollSyncEnabled)
  }

  @MainActor
  func testProgrammaticPreviewScrollDoesNotFeedBackToEditor() {
    let coordinator = ScrollSyncCoordinator(unlockScheduler: { _ in })
    let preview = RecordingPreviewTarget()
    var feedbackAttempts = 0

    coordinator.isEnabled = true
    coordinator.attachPreviewTarget(preview)
    preview.onApply = {
      if coordinator.acceptsObservedScroll(from: .preview) {
        feedbackAttempts += 1
      }
    }

    coordinator.editorDidScroll(to: ScrollSyncPosition(progress: 0.42))

    XCTAssertEqual(preview.received, [ScrollSyncPosition(progress: 0.42)])
    XCTAssertEqual(
      feedbackAttempts,
      0,
      "Programmatic preview scroll fed back while the preview-side latch was active."
    )
  }

  @MainActor
  func testProgrammaticLatchClearsOnScheduledTurn() {
    var unlock: (() -> Void)?
    let coordinator = ScrollSyncCoordinator(unlockScheduler: { unlock = $0 })
    let preview = RecordingPreviewTarget()

    coordinator.isEnabled = true
    coordinator.attachPreviewTarget(preview)
    coordinator.editorDidScroll(to: ScrollSyncPosition(progress: 0.25))

    XCTAssertFalse(coordinator.acceptsObservedScroll(from: .preview))
    unlock?()
    XCTAssertTrue(coordinator.acceptsObservedScroll(from: .preview))
  }

  @MainActor
  func testDisabledCoordinatorDropsEditorScroll() {
    let coordinator = ScrollSyncCoordinator(unlockScheduler: { _ in })
    let preview = RecordingPreviewTarget()

    coordinator.attachPreviewTarget(preview)
    coordinator.editorDidScroll(to: ScrollSyncPosition(progress: 0.5))

    XCTAssertTrue(preview.received.isEmpty)
  }

  @MainActor
  func testEditorPercentPositionUsesScrollGeometryOnly() {
    let visible = NSRect(x: 0, y: 50, width: 320, height: 100)
    let position = MarkdownEditorSurface.scrollSyncPosition(
      visibleRect: visible,
      documentHeight: 300
    )

    XCTAssertEqual(position.progress, 0.25, accuracy: 0.001)

    let clamped = MarkdownEditorSurface.scrollSyncPosition(
      visibleRect: NSRect(x: 0, y: 900, width: 320, height: 100),
      documentHeight: 300
    )
    XCTAssertEqual(clamped.progress, 1)
  }

  @MainActor
  func testEditorBoundsSampleIsDeferredOutOfNotificationTurn() {
    let surface = MarkdownEditorSurface(
      text: longDocument(),
      fontSize: 14,
      scrollSyncDebounce: 0.01
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    defer { window.contentView = nil }

    window.contentView = surface.scrollView
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    surface.scrollView.layoutSubtreeIfNeeded()

    let coordinator = ScrollSyncCoordinator()
    let preview = RecordingPreviewTarget()
    coordinator.attachPreviewTarget(preview)
    surface.configureScrollSync(coordinator: coordinator, enabled: true)

    surface.scheduleScrollSyncSample()
    XCTAssertTrue(preview.received.isEmpty)

    let exp = expectation(description: "scroll sync sample")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1.0)

    XCTAssertEqual(preview.received.count, 1)
  }

  private func longDocument() -> String {
    (1...160)
      .map { "Line \($0): scroll sync geometry probe." }
      .joined(separator: "\n")
  }
}

private final class RecordingPreviewTarget: ScrollSyncPreviewTarget {
  var received: [ScrollSyncPosition] = []
  var onApply: (() -> Void)?

  func applyScrollSyncPosition(_ position: ScrollSyncPosition) {
    received.append(position)
    onApply?()
  }
}
