import AppKit
import XCTest

@testable import Pensieve

/// D-04. The three System Settings "Prefer tabs when opening documents" modes —
/// Never / Always / In Full Screen — driven end to end through the two live New
/// gestures: ⌘N (`AppController.createUntitledDocument`) and the native tab
/// bar's "+" (`DocumentWindowRegistry.newDocumentForTab`).
///
/// What makes these NON-FAKEABLE: the only thing injected is the PREFERENCE.
/// Every case routes it through the shipped policy
/// (`DocumentOpenPlacement.resolve(preference:sourceWindow:)`), including the
/// window→full-screen mapping, so a test cannot pass by naming the placement it
/// wants the way `resolveNewDocumentPlacement: { _ in .tabIn }` does. Setting
/// the real `NSWindow.userTabbingPreference` is a System Settings global no test
/// process may write — that half of the matrix is the operator's manual
/// checklist (`reports/manual-prefer-tabs-matrix.md` in the plan root).
final class DocumentOpenPlacementIntegrationTests: XCTestCase {

  // MARK: - The matrix

  fileprivate struct Mode {
    let name: String
    let preference: NSWindow.UserTabbingPreference
    let sourceIsFullScreen: Bool
    /// The whole point of the row: does this combination put the new document
    /// in the source window's tab group, or in a window of its own?
    let expectsTab: Bool
  }

  fileprivate static let matrix: [Mode] = [
    Mode(
      name: "Never · windowed source", preference: .manual, sourceIsFullScreen: false,
      expectsTab: false),
    Mode(
      name: "Never · full-screen source", preference: .manual, sourceIsFullScreen: true,
      expectsTab: false),
    Mode(
      name: "Always · windowed source", preference: .always, sourceIsFullScreen: false,
      expectsTab: true),
    Mode(
      name: "Always · full-screen source", preference: .always, sourceIsFullScreen: true,
      expectsTab: true),
    Mode(
      name: "In Full Screen · windowed source", preference: .inFullScreen,
      sourceIsFullScreen: false, expectsTab: false),
    Mode(
      name: "In Full Screen · full-screen source", preference: .inFullScreen,
      sourceIsFullScreen: true, expectsTab: true),
  ]

  // MARK: - A1 · ⌘N

  /// ⌘N over a window holding live work, once per matrix row. The gesture always
  /// reaches the factory; the mode decides only WHERE the built window lands.
  @MainActor
  func testCommandNPlacesTheNewDocumentByEverySystemSettingsMode() {
    for mode in Self.matrix {
      let rig = Rig(mode: mode)
      defer { rig.tearDown() }

      let appState = AppState()
      appState.documentSession = .untitled(title: "Original.md")
      appState.activeDocumentText = "original buffer"
      let originalIdentity = appState.documentSession.identity

      let controller = AppController(
        appState: appState,
        folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
        documentStore: makeTestDocumentStore(),
        documentWindowRegistry: rig.registry,
        resolveDocumentOpenPlacement: rig.placementResolver)
      rig.registry.registerController(controller, for: rig.sourceWindow)

      XCTAssertTrue(controller.createUntitledDocument(), mode.name)
      rig.assertPlacement(mode.name)

      XCTAssertEqual(
        appState.documentSession.identity, originalIdentity,
        "\(mode.name): New must not overwrite the buffer it fired from")
      XCTAssertEqual(appState.activeDocumentText, "original buffer", mode.name)
    }
  }

  // MARK: - A1 · tab bar "+"

  /// The same matrix through the other New gesture. Both gestures share one
  /// decision point, and this is the test that keeps them from drifting apart.
  @MainActor
  func testTabBarPlusPlacesTheNewDocumentByEverySystemSettingsMode() {
    for mode in Self.matrix {
      let rig = Rig(mode: mode)
      defer { rig.tearDown() }

      XCTAssertTrue(rig.registry.newDocumentForTab(from: rig.sourceWindow), mode.name)
      rig.assertPlacement(mode.name)
    }
  }

  /// The term that is NOT a mode: with no source window there is no tab group to
  /// join, so every mode — Always included — has to build a window.
  @MainActor
  func testEveryModeOpensAWindowWhenTheGestureHasNoSourceWindow() {
    for preference in Self.allPreferences {
      let untitledWindow = Self.makeWindow()
      defer { untitledWindow.close() }

      var factoryCalls = 0
      var merges = 0
      var activations = 0
      let registry = DocumentWindowRegistry(
        canMutateWindowTabs: { true },
        scheduleDeferredMainWork: { _ in XCTFail("New must not defer here") },
        scheduleLauncherWindowSweep: { _ in },
        mergeWindowIntoTabs: { _, _ in merges += 1 },
        orderAndActivateWindow: { _ in activations += 1 },
        applicationWindows: { [untitledWindow] },
        resolveNewDocumentPlacement: { window in
          DocumentOpenPlacement.resolve(preference: preference, sourceWindow: window)
        },
        makeDocumentWindow: { _, _ in
          factoryCalls += 1
          return untitledWindow
        })

      let appState = AppState()
      appState.documentSession = .untitled(title: "Original.md")
      appState.activeDocumentText = "original buffer"
      let controller = AppController(
        appState: appState,
        folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
        documentStore: makeTestDocumentStore(),
        documentWindowRegistry: registry,
        resolveDocumentOpenPlacement: { window in
          DocumentOpenPlacement.resolve(preference: preference, sourceWindow: window)
        })
      // Deliberately NOT registered against a window, and no host provider: this
      // is the controller shape whose New gesture has nothing to tab into.
      XCTAssertNil(registry.window(hosting: controller))

      XCTAssertTrue(controller.createUntitledDocument())
      XCTAssertEqual(factoryCalls, 1)
      XCTAssertEqual(merges, 0, "there is no source group to merge into")
      XCTAssertEqual(activations, 1)
    }
  }

  // MARK: - A2 · recovered draft never blocks New

  /// A dirty RECOVERED draft is the buffer the operator reported multiplying, so
  /// New over it is tested twice over: it must not raise the save question in any
  /// mode, and it must not leave a second copy of the draft behind. The clone
  /// count is asserted against the real `RecoveryStore` directory — the same list
  /// the launcher's Recovered Drafts section reads.
  @MainActor
  func testNewOverADirtyRecoveredDraftNeverPromptsOrClonesItInAnyMode() throws {
    for mode in Self.matrix {
      let rig = Rig(mode: mode)
      defer { rig.tearDown() }

      let recoveryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PensievePreferTabsMatrix-\(UUID().uuidString)", isDirectory: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: recoveryRoot) }
      let recoveryStore = RecoveryStore(directoryURL: recoveryRoot)
      let draft = try recoveryStore.saveDraft(
        id: nil, title: "umowa.md", text: "contract text that must survive")
      XCTAssertEqual(recoveryStore.loadDrafts().count, 1, "\(mode.name): one draft was seeded")

      let appState = AppState()
      appState.documentSession.restoreUntitled(
        title: draft.title, text: draft.text, recoveryID: draft.id)
      let originalIdentity = appState.documentSession.identity

      var savePrompts = 0
      var saveSheets = 0
      let controller = AppController(
        appState: appState,
        folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
        documentStore: makeTestDocumentStore(
          recoveryStore: recoveryStore,
          dirtySessionPrompt: { _ in
            savePrompts += 1
            return .cancel
          }),
        documentWindowRegistry: rig.registry,
        resolveDocumentOpenPlacement: rig.placementResolver,
        confirmSaveChanges: { _, _, _, _ in saveSheets += 1 })
      rig.registry.registerController(controller, for: rig.sourceWindow)

      XCTAssertTrue(controller.createUntitledDocument(), mode.name)
      rig.assertPlacement(mode.name)

      XCTAssertEqual(savePrompts, 0, "\(mode.name): New must never ask the save question")
      XCTAssertEqual(saveSheets, 0, "\(mode.name): New must never raise the save sheet")
      XCTAssertEqual(
        appState.documentSession.identity, originalIdentity,
        "\(mode.name): the recovered draft's identity survives New")
      XCTAssertEqual(appState.activeDocumentText, "contract text that must survive", mode.name)
      XCTAssertTrue(appState.activeDocumentDirty, mode.name)
      XCTAssertEqual(
        recoveryStore.loadDrafts().count, 1,
        "\(mode.name): New must not add a second copy of the recovered draft")
      XCTAssertEqual(recoveryStore.loadDrafts().first?.id, draft.id, mode.name)
    }
  }

  // MARK: - Rig

  /// One matrix row's worth of windows, registry and counters. Built per row so a
  /// leaked count from a previous mode cannot make the next one pass.
  @MainActor
  fileprivate final class Rig {
    let sourceWindow: NSWindow
    let untitledWindow: NSWindow
    let registry: DocumentWindowRegistry
    let placementResolver: AppController.DocumentPlacementResolver

    private let mode: Mode
    private let counters = Counters()

    init(mode: Mode) {
      self.mode = mode
      let sourceWindow =
        mode.sourceIsFullScreen
        ? FullScreenLikeWindow.make()
        : DocumentOpenPlacementIntegrationTests.makeWindow(title: "Source")
      let untitledWindow = DocumentOpenPlacementIntegrationTests.makeWindow()
      self.sourceWindow = sourceWindow
      self.untitledWindow = untitledWindow

      let resolver: AppController.DocumentPlacementResolver = { window in
        DocumentOpenPlacement.resolve(preference: mode.preference, sourceWindow: window)
      }
      self.placementResolver = resolver

      let counters = self.counters
      registry = DocumentWindowRegistry(
        canMutateWindowTabs: { true },
        scheduleDeferredMainWork: { _ in XCTFail("New must not defer — \(mode.name)") },
        scheduleLauncherWindowSweep: { _ in },
        mergeWindowIntoTabs: { target, joined in
          XCTAssertTrue(target === sourceWindow, mode.name)
          XCTAssertTrue(joined === untitledWindow, mode.name)
          counters.merges += 1
        },
        orderAndActivateWindow: { window in
          XCTAssertTrue(window === untitledWindow, mode.name)
          counters.activations += 1
        },
        applicationWindows: { [sourceWindow, untitledWindow] },
        resolveNewDocumentPlacement: resolver,
        makeDocumentWindow: { ref, intent in
          XCTAssertNil(ref, "\(mode.name): New asks the factory for an untitled window")
          XCTAssertEqual(intent, .newUntitledTab, mode.name)
          counters.factoryCalls += 1
          return untitledWindow
        })
    }

    func assertPlacement(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
      XCTAssertEqual(counters.factoryCalls, 1, label, file: file, line: line)
      XCTAssertEqual(
        counters.merges, mode.expectsTab ? 1 : 0,
        mode.expectsTab
          ? "\(label): the new document belongs in the source window's tab group"
          : "\(label): the new document belongs in a window of its own",
        file: file, line: line)
      XCTAssertEqual(
        counters.activations, 1, "\(label): the new document is presented exactly once",
        file: file, line: line)
      XCTAssertEqual(
        untitledWindow.tabbingIdentifier, WindowChromeRecipe.documentTabbingIdentifier,
        "\(label): a standalone New must stay mergeable, or Merge All Windows greys out",
        file: file, line: line)
    }

    func tearDown() {
      untitledWindow.close()
      // The full-screen stand-in is never ordered on screen and reports a mask
      // AppKit's own close path would try to act on, so it is only released.
      if !mode.sourceIsFullScreen { sourceWindow.close() }
    }
  }

  fileprivate final class Counters {
    var factoryCalls = 0
    var merges = 0
    var activations = 0
  }

  // MARK: - Helpers

  fileprivate static let allPreferences: [NSWindow.UserTabbingPreference] = [
    .manual, .always, .inFullScreen,
  ]

  @MainActor
  fileprivate static func makeWindow(title: String = "") -> NSWindow {
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

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensievePreferTabsMatrix-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }
}

/// A window that reports itself as full screen. Toggling real full screen needs a
/// display and an animation no headless test bundle has, and the production
/// policy reads exactly one thing — `styleMask.contains(.fullScreen)` — so that
/// is the one thing this stand-in overrides.
private final class FullScreenLikeWindow: NSWindow {
  override var styleMask: NSWindow.StyleMask {
    get { super.styleMask.union(.fullScreen) }
    set { super.styleMask = newValue }
  }

  @MainActor
  static func make() -> FullScreenLikeWindow {
    let window = FullScreenLikeWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .zero)
    window.title = "Source (full screen)"
    return window
  }
}
