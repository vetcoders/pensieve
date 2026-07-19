import AppKit
import XCTest

@testable import Pensieve

/// Structural smoke for the toolbelt declutter: the appearance controls are
/// preview-scoped, and the appearance-menu pickers keep auto-populating from the
/// `CaseIterable` theme axes.
final class EditorToolbeltTests: XCTestCase {
  // MARK: - Appearance visibility gate

  func testAppearanceControlsHiddenInPureSourceMode() {
    XCTAssertFalse(EditorToolbelt.showsAppearanceControls(for: .source))
  }

  func testAppearanceControlsHiddenInFocusMode() {
    // Focus is a source-editing surface — no preview pane, no appearance item.
    XCTAssertFalse(EditorToolbelt.showsAppearanceControls(for: .focus))
  }

  func testAppearanceControlsVisibleWhenPreviewPaneExists() {
    XCTAssertTrue(EditorToolbelt.showsAppearanceControls(for: .preview))
    XCTAssertTrue(EditorToolbelt.showsAppearanceControls(for: .split))
  }

  func testEveryEditorModeHasAnExplicitAppearanceDecision() {
    // Adding a new EditorMode must consciously land on one side of the gate;
    // this pins today's full mapping so a new case shows up as a test edit.
    let visible = EditorMode.allCases.filter(EditorToolbelt.showsAppearanceControls(for:))
    XCTAssertEqual(Set(visible), Set([.preview, .split]))
  }

  // MARK: - Appearance-menu pickers stay CaseIterable-driven

  func testFlavorAxisAutoPopulates() {
    XCTAssertFalse(ThemeManager.Theme.allCases.isEmpty)
    XCTAssertTrue(ThemeManager.Theme.allCases.contains(.gfm))
  }

  func testSkinAxisAutoPopulates() {
    // The menu renders one row per case — every skin needs a display name
    // and a symbol, and the ids the picker tags on must stay unique.
    let skins = ThemeManager.PreviewTheme.allCases
    XCTAssertFalse(skins.isEmpty)
    XCTAssertEqual(Set(skins.map(\.id)).count, skins.count)
    for skin in skins {
      XCTAssertFalse(skin.displayName.isEmpty)
      XCTAssertFalse(skin.systemImage.isEmpty)
    }
  }

  // MARK: - Inline edit toolbelt policy

  func testEditToolbeltVisibleForEditableSourceSplitAndFocusBuffers() {
    XCTAssertTrue(EditorToolbelt.showsEditToolbelt(for: .source, hasEditableBuffer: true))
    XCTAssertTrue(EditorToolbelt.showsEditToolbelt(for: .split, hasEditableBuffer: true))
    XCTAssertTrue(EditorToolbelt.showsEditToolbelt(for: .focus, hasEditableBuffer: true))
  }

  func testEditToolbeltHiddenForPreviewOnlyAndEmptyBuffers() {
    XCTAssertFalse(EditorToolbelt.showsEditToolbelt(for: .preview, hasEditableBuffer: true))

    for mode in EditorMode.allCases {
      XCTAssertFalse(EditorToolbelt.showsEditToolbelt(for: mode, hasEditableBuffer: false))
    }
  }

  // MARK: - Inline toolbelt ↔ floating bar shared contract

  func testEditActionListIsTheSharedAllCasesOrder() {
    // The inline toolbar, floating selection bar, and editor context menu
    // ALL iterate `MarkdownFormat.allCases` - this pins the shared order so a
    // reorder (or a fork into a second array) shows up as a test edit.
    XCTAssertEqual(
      MarkdownFormat.allCases,
      [.bold, .strike, .italic, .quote, .code, .link, .bulletedList, .numberedList])
  }

  func testEveryEditActionRendersInInlineToolbelt() {
    let expectedToolbarIdentifiers = [
      "pensieve.toolbar.format.bold",
      "pensieve.toolbar.format.strike",
      "pensieve.toolbar.format.italic",
      "pensieve.toolbar.format.quote",
      "pensieve.toolbar.format.code",
      "pensieve.toolbar.format.link",
      "pensieve.toolbar.format.bulletedList",
      "pensieve.toolbar.format.numberedList",
    ]

    // Inline buttons need a label, a symbol, and stable accessibility ids;
    // empty metadata would render a blank row without failing the build.
    for format in MarkdownFormat.allCases {
      XCTAssertFalse(format.label.isEmpty)
      XCTAssertFalse(format.systemImageName.isEmpty)
    }
    XCTAssertEqual(
      MarkdownFormat.allCases.map(\.toolbarAccessibilityIdentifier),
      expectedToolbarIdentifiers)
  }

  // MARK: - Titlebar order contract

  func testTitlebarOrderSeparatesShareDispatchAndStartsEditRowWithRichMarkdownToggle() {
    let expectedOrder =
      [
        EditorToolbelt.shareIdentifier,
        EditorToolbelt.dispatchIdentifier,
        EditorToolbelt.undoIdentifier,
        EditorToolbelt.redoIdentifier,
        EditorToolbelt.richMarkdownToggleIdentifier,
      ]
      + MarkdownFormat.allCases.map(\.toolbarAccessibilityIdentifier)
      + [
        EditorToolbelt.modePickerIdentifier,
        EditorToolbelt.appearanceIdentifier,
        EditorToolbelt.reloadIdentifier,
        EditorToolbelt.autoReloadIdentifier,
        EditorToolbelt.scrollSyncIdentifier,
        EditorToolbelt.dictationIdentifier,
        EditorToolbelt.autocompleteIdentifier,
      ]

    XCTAssertEqual(
      EditorToolbelt.visibleToolbarIdentifierOrder(for: .split, hasEditableBuffer: true),
      expectedOrder)
  }

  func testTitlebarFamiliesPreserveSemanticOrder() {
    XCTAssertEqual(
      EditorToolbelt.visibleToolbarFamilyOrder(for: .split, hasEditableBuffer: true),
      [.documentDispatch, .history, .editing, .view, .previewRuntime, .assistants])

    XCTAssertEqual(
      EditorToolbelt.visibleToolbarFamilyOrder(for: .source, hasEditableBuffer: false),
      [.documentDispatch, .view, .previewRuntime, .assistants])
  }

  func testTitlebarOrderKeepsModesTrailingWhenEditRowIsUnavailable() {
    XCTAssertEqual(
      EditorToolbelt.visibleToolbarIdentifierOrder(for: .preview, hasEditableBuffer: true),
      [
        EditorToolbelt.shareIdentifier,
        EditorToolbelt.dispatchIdentifier,
        EditorToolbelt.modePickerIdentifier,
        EditorToolbelt.appearanceIdentifier,
        EditorToolbelt.reloadIdentifier,
        EditorToolbelt.autoReloadIdentifier,
        EditorToolbelt.scrollSyncIdentifier,
        EditorToolbelt.dictationIdentifier,
        EditorToolbelt.autocompleteIdentifier,
      ])

    XCTAssertEqual(
      EditorToolbelt.visibleToolbarIdentifierOrder(for: .source, hasEditableBuffer: false),
      [
        EditorToolbelt.shareIdentifier,
        EditorToolbelt.dispatchIdentifier,
        EditorToolbelt.modePickerIdentifier,
        EditorToolbelt.reloadIdentifier,
        EditorToolbelt.autoReloadIdentifier,
        EditorToolbelt.scrollSyncIdentifier,
        EditorToolbelt.dictationIdentifier,
        EditorToolbelt.autocompleteIdentifier,
      ])
  }
}

@MainActor
final class EditorToolbeltTestsHistory: XCTestCase {
  @MainActor
  private final class HistoryProbe: NSObject {
    let undoManager: UndoManager
    private(set) var value = 0

    init(undoManager: UndoManager) {
      self.undoManager = undoManager
    }

    func setValue(_ newValue: Int) {
      let previous = value
      undoManager.registerUndo(withTarget: self) { target in
        target.setValue(previous)
      }
      value = newValue
    }
  }

  func testHistoryActionsUseStandardResponderSelectorsAndLabels() {
    XCTAssertEqual(
      NSStringFromSelector(ToolbarResponderHistoryState.Action.undo.selector), "undo:")
    XCTAssertEqual(
      NSStringFromSelector(ToolbarResponderHistoryState.Action.redo.selector), "redo:")

    for action in ToolbarResponderHistoryState.Action.allCases {
      XCTAssertFalse(action.label.isEmpty)
      XCTAssertFalse(action.systemImage.isEmpty)
      XCTAssertFalse(action.accessibilityIdentifier.isEmpty)
    }
  }

  func testHistoryRefreshNotificationsCannotFeedBackThroughUndoCheckpoint() {
    XCTAssertFalse(
      ToolbarResponderHistoryState.refreshNotificationNames.contains(.NSUndoManagerCheckpoint),
      "reading canUndo/canRedo emits a checkpoint, so observing it creates an infinite refresh loop"
    )
    XCTAssertTrue(
      ToolbarResponderHistoryState.refreshNotificationNames.contains(
        .NSUndoManagerDidCloseUndoGroup),
      "closed undo groups must still refresh toolbar availability"
    )
  }

  func testAvailabilityTracksActiveTextViewUndoManagerWithoutAnotherStack() throws {
    let surface = MarkdownEditorSurface(text: "history", fontSize: 14)
    let undoManager = try XCTUnwrap(surface.textView.undoManager)
    let probe = HistoryProbe(undoManager: undoManager)

    XCTAssertEqual(
      ToolbarResponderHistoryState.availability(for: surface.textView),
      .init(canUndo: false, canRedo: false))

    probe.setValue(1)
    XCTAssertEqual(
      ToolbarResponderHistoryState.availability(for: surface.textView),
      .init(canUndo: true, canRedo: false))

    undoManager.undo()
    XCTAssertEqual(probe.value, 0)
    XCTAssertEqual(
      ToolbarResponderHistoryState.availability(for: surface.textView),
      .init(canUndo: false, canRedo: true))

    undoManager.redo()
    XCTAssertEqual(probe.value, 1)
    XCTAssertEqual(
      ToolbarResponderHistoryState.availability(for: surface.textView),
      .init(canUndo: true, canRedo: false))
  }
}

/// Regression at the floating-format-bar positioning seam (operator evidence
/// 2026-07-05 18:47: the bar ghosted UNDER the translucent titlebar). The
/// `allowed` rect models `visibleRect ∩ contentLayoutRect` in the flipped
/// text-view space: content spans y 0…600 but the top 52pt strip (y < 52)
/// lies under the chrome, so allowed = (0, 52, 800, 548).
final class EditorToolbeltFloatingClampTests: XCTestCase {
  private let allowed = NSRect(x: 0, y: 52, width: 800, height: 548)
  private let barSize = NSSize(width: 200, height: 28)

  func testBarPrefersAboveSelectionWhenRoomExists() {
    let selection = NSRect(x: 100, y: 300, width: 120, height: 17)
    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: true)
    // Flipped space: "above" the selection = smaller y; 300 - 28 - 6 = 266.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 266))
  }

  func testBarDropsBelowSelectionWhenAnchorTouchesChromeEdge() {
    // Selection first line just under the toolbar edge — no room above
    // inside the allowed region, so the bar flips below: 77 + 6 = 83.
    let selection = NSRect(x: 100, y: 60, width: 120, height: 17)
    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: true)
    XCTAssertEqual(origin, NSPoint(x: 100, y: 83))
  }

  func testBarPinsAtChromeEdgeWhenSelectionScrollsUnderTitlebar() {
    // The ghosting bug: the anchor scrolled under the chrome (y < allowed.minY).
    // The bar must pin at the chrome edge, never follow through it.
    let origin = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 100, y: 10), size: barSize, allowed: allowed)
    XCTAssertEqual(origin.y, allowed.minY)
    XCTAssertEqual(origin.x, 100)
  }

  func testBarStaysInsideTrailingEdge() {
    let origin = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 790, y: 300), size: barSize, allowed: allowed)
    // 800 - 200 - 4 margin = 596.
    XCTAssertEqual(origin, NSPoint(x: 596, y: 300))
  }

  func testBarStaysInsideBottomEdge() {
    let origin = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 100, y: 590), size: barSize, allowed: allowed)
    // allowed.maxY(600) - height(28) = 572.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 572))
  }

  func testDegenerateAllowedRectStillReturnsFiniteOrigin() {
    // A collapsed window must not send the bar to ±∞ or crash the clamp.
    let tiny = NSRect(x: 0, y: 52, width: 120, height: 20)
    let origin = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 300, y: 300), size: barSize, allowed: tiny)
    XCTAssertEqual(origin, NSPoint(x: 4, y: 52))
  }
}

/// Chrome-truth companion to the pure clamp suite above: the pieces the
/// geometry tests cannot see — the unflipped `accessoryOrigin` branch, the
/// full origin→clamp pin path, and `accessoryAllowedRect` reading a REAL
/// `window.contentLayoutRect` under a full-size content view (the same
/// boundary rule as the preview glass strip).
@MainActor
final class FormattingAccessoryChromeTruthTests: XCTestCase {
  private let barSize = NSSize(width: 200, height: 28)

  func testUnflippedPlacementPrefersBelowSelection() {
    let allowed = NSRect(x: 0, y: 0, width: 800, height: 600)
    let selection = NSRect(x: 100, y: 100, width: 120, height: 17)
    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: false)
    // Unflipped space: "below" = larger y; maxY(117) + gap(6) = 123.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 123))
  }

  func testUnflippedPlacementFlipsAboveAtTopEdge() {
    let allowed = NSRect(x: 0, y: 0, width: 800, height: 600)
    let selection = NSRect(x: 100, y: 560, width: 120, height: 17)
    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: false)
    // Below would end at 583+28 = 611 > 600 → above: 560 - 28 - 6 = 526.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 526))
  }

  func testAccessoryOriginPinsIntoAllowedWhenSelectionSitsUnderChrome() {
    // Through the FULL path (origin choice + clamp), not the clamp alone: a
    // selection whose above AND below candidates both land in chrome must
    // still come back pinned at the chrome edge.
    let allowed = NSRect(x: 0, y: 52, width: 800, height: 548)
    let selection = NSRect(x: 100, y: 0, width: 120, height: 17)
    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: true)
    XCTAssertEqual(origin.y, allowed.minY)
  }

  func testAllowedRectWithoutWindowFallsBackToVisibleRect() {
    let surface = MarkdownEditorSurface(text: "hello chrome", fontSize: 14)
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    surface.scrollView.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      surface.textView.accessoryAllowedRect(), surface.textView.visibleRect)
  }

  func testAllowedRectExcludesTitlebarChromeInFullSizeContentWindow() {
    let surface = MarkdownEditorSurface(text: "hello chrome", fontSize: 14)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = surface.scrollView
    surface.scrollView.frame = window.contentView?.bounds ?? .zero
    surface.scrollView.layoutSubtreeIfNeeded()

    let textView = surface.textView
    let visible = textView.visibleRect
    let allowed = textView.accessoryAllowedRect()

    // Under .fullSizeContentView the text view underlaps the titlebar, so the
    // allowed region must start BELOW the chrome edge (flipped coords: larger
    // minY) — and that edge must be exactly the window's contentLayoutRect.
    XCTAssertGreaterThan(
      allowed.minY, visible.minY,
      "allowed rect must exclude the titlebar band the visible rect underlaps")
    XCTAssertEqual(allowed.maxY, visible.maxY, accuracy: 0.5)
    XCTAssertFalse(allowed.isEmpty)

    let contentTop = textView.convert(window.contentLayoutRect, from: nil).minY
    XCTAssertEqual(allowed.minY, contentTop, accuracy: 0.5)
  }
}

/// Regression for the dangling-undo-target SIGSEGV (crash report Pensieve
/// 2026-07-19-060545): the text view registers undo actions targeting `self`
/// into the WINDOW's undo manager, which outlives the view. When SwiftUI rebuilds
/// the editor representable, the freed view is still referenced by those entries
/// (NSUndoManager holds targets unsafe-unretained), so the first Cmd+Z afterwards
/// drives `undoNestedGroup → popAndInvoke → objc_msgSend` onto a dangling pointer.
/// Detaching the view from its window must scrub every entry targeting it from the
/// outgoing window's undo manager.
@MainActor
final class MarkdownTextViewUndoDetachTests: XCTestCase {
  func testDetachingFromWindowClearsUndoActionsTargetingTextView() throws {
    let surface = MarkdownEditorSurface(text: "detach", fontSize: 14)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = surface.scrollView
    surface.scrollView.frame = window.contentView?.bounds ?? .zero
    surface.scrollView.layoutSubtreeIfNeeded()

    let textView = surface.textView
    XCTAssertTrue(textView.window === window, "text view must be attached before the test starts")

    // The window's undo manager is the exact instance the text view registers into
    // while attached (`super.undoManager` resolves to it, no delegate override).
    let windowUndoManager = try XCTUnwrap(window.undoManager)
    XCTAssertTrue(
      textView.undoManager === windowUndoManager,
      "attached text view must share the window's undo manager")

    // Register an entry targeting the view — same shape as AppKit typing-undo and
    // `registerSmartPasteUndo` (both use a target of `self`).
    // Close the group deterministically: `removeAllActions(withTarget:)` scrubs a
    // block-based entry only once its group is closed, and AppKit's default
    // `groupsByEvent` closes groups on run-loop turns we do not spin here. Real teardown
    // happens on a later event with the group already closed — this reproduces that state.
    windowUndoManager.groupsByEvent = false
    windowUndoManager.beginUndoGrouping()
    windowUndoManager.registerUndo(withTarget: textView) { tv in
      _ = tv  // undo body is irrelevant; the dangling *target* is the crash surface.
    }
    windowUndoManager.endUndoGrouping()
    XCTAssertTrue(
      windowUndoManager.canUndo, "precondition: the registered entry must be live before detach")

    // Detach the whole editor subtree from the window (the SwiftUI teardown path).
    surface.scrollView.removeFromSuperview()
    XCTAssertNil(textView.window, "text view must be detached after removeFromSuperview")

    XCTAssertFalse(
      windowUndoManager.canUndo,
      "detaching the text view must clear its entries from the window's undo manager, "
        + "or the freed view is left as a dangling undo target (SIGSEGV on next Cmd+Z)")
  }
}
