import AppKit
import XCTest

@testable import Pensieve

/// End-to-end pins for the v1 New contract.
///
/// `Cmd+N`, `Cmd+T`, and the native tab bar's `+` are deterministic Pensieve
/// commands: an occupied document host receives a new native tab. Their
/// placement is deliberately independent of macOS's global "Prefer tabs when
/// opening documents" preference. Full-screen and windowed hosts exercise the
/// two source-window shapes that the removed preference policy distinguished.
final class NewDocumentTabIntegrationTests: XCTestCase {
  fileprivate struct Mode {
    let name: String
    let sourceIsFullScreen: Bool
  }

  fileprivate static let matrix: [Mode] = [
    Mode(name: "windowed source", sourceIsFullScreen: false),
    Mode(name: "full-screen source", sourceIsFullScreen: true),
  ]

  @MainActor
  func testCommandNAlwaysCreatesATabForEveryDocumentHostShape() {
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
        documentWindowRegistry: rig.registry)
      rig.registry.registerController(controller, for: rig.sourceWindow)

      XCTAssertTrue(controller.createUntitledDocument(), mode.name)
      rig.assertTabPlacement(mode.name)
      XCTAssertEqual(
        appState.documentSession.identity, originalIdentity,
        "\(mode.name): New must not overwrite the buffer it fired from")
      XCTAssertEqual(appState.activeDocumentText, "original buffer", mode.name)
    }
  }

  @MainActor
  func testTabBarPlusAlwaysCreatesATabForEveryDocumentHostShape() {
    for mode in Self.matrix {
      let rig = Rig(mode: mode)
      defer { rig.tearDown() }

      XCTAssertTrue(rig.registry.newDocumentForTab(from: rig.sourceWindow), mode.name)
      rig.assertTabPlacement(mode.name)
    }
  }

  @MainActor
  func testCommandNFailsClosedWhenOccupiedControllerHasNoSourceWindow() {
    let untitledWindow = Self.makeWindow()
    defer { untitledWindow.close() }

    var factoryCalls = 0
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("New must not defer here") },
      scheduleLauncherWindowSweep: { _ in },
      applicationWindows: { [untitledWindow] },
      makeDocumentWindow: { _, _ in
        factoryCalls += 1
        return untitledWindow
      })
    let appState = AppState()
    appState.documentSession = .untitled(title: "Original.md")
    appState.activeDocumentText = "original buffer"
    let originalIdentity = appState.documentSession.identity
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(),
      documentWindowRegistry: registry)

    XCTAssertNil(registry.window(hosting: controller))
    XCTAssertFalse(controller.createUntitledDocument())
    XCTAssertEqual(factoryCalls, 0)
    XCTAssertEqual(appState.documentSession.identity, originalIdentity)
    XCTAssertEqual(appState.activeDocumentText, "original buffer")
  }

  @MainActor
  func testConsecutiveNewCommandsNeverReuseAFreshUntitledTabInPlace() {
    let sourceWindow = Self.makeWindow(title: "Source")
    let firstUntitledWindow = Self.makeWindow()
    let secondUntitledWindow = Self.makeWindow()
    let factoryWindows = [firstUntitledWindow, secondUntitledWindow]
    defer {
      for window in factoryWindows.reversed() + [sourceWindow] {
        window.close()
      }
    }
    XCTAssertTrue(DocumentWindowOwnership.claimDocumentHost(sourceWindow))

    var factoryCalls = 0
    var merges: [(NSWindow, NSWindow)] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in XCTFail("New must not defer here") },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { merges.append(($0, $1)) },
      orderAndActivateWindow: { _ in },
      applicationWindows: { [sourceWindow] + factoryWindows },
      makeDocumentWindow: { ref, intent in
        XCTAssertNil(ref)
        XCTAssertEqual(intent, .newUntitledTab)
        defer { factoryCalls += 1 }
        return factoryCalls < factoryWindows.count ? factoryWindows[factoryCalls] : nil
      })

    let sourceState = AppState()
    sourceState.documentSession = .untitled(title: "Original.md")
    sourceState.activeDocumentText = "original buffer"
    let sourceController = AppController(
      appState: sourceState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(),
      documentWindowRegistry: registry)
    registry.registerController(sourceController, for: sourceWindow)

    XCTAssertTrue(sourceController.createUntitledDocument())

    // This is the runtime race the regression pins: the new native tab exists
    // and owns the command, but its editable buffer has not arrived yet.
    let firstUntitledState = AppState()
    let firstUntitledController = AppController(
      appState: firstUntitledState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(),
      documentWindowRegistry: registry)
    registry.registerController(firstUntitledController, for: firstUntitledWindow)
    XCTAssertFalse(firstUntitledState.documentSession.hasEditableBuffer)

    XCTAssertTrue(firstUntitledController.createUntitledDocument())
    XCTAssertEqual(factoryCalls, 2)
    XCTAssertEqual(merges.count, 2)
    XCTAssertTrue(merges[0].0 === sourceWindow)
    XCTAssertTrue(merges[0].1 === firstUntitledWindow)
    XCTAssertTrue(merges[1].0 === firstUntitledWindow)
    XCTAssertTrue(merges[1].1 === secondUntitledWindow)
    XCTAssertFalse(
      firstUntitledState.documentSession.hasEditableBuffer,
      "the second New must not mutate the first tab in place")
  }

  @MainActor
  func testNewStillReusesTheTrackedIdleLauncherInPlace() {
    let launcher = Self.makeWindow(title: "Pensieve")
    defer { launcher.close() }
    let factoryWindow = Self.makeWindow()
    defer { factoryWindow.close() }
    var factoryCalls = 0
    let registry = DocumentWindowRegistry(
      scheduleLauncherWindowSweep: { _ in },
      applicationWindows: { [launcher, factoryWindow] },
      makeDocumentWindow: { _, _ in
        factoryCalls += 1
        return factoryWindow
      })
    XCTAssertTrue(
      registry.attach(
        launcher,
        identity: nil,
        documentID: nil,
        hasEditableBuffer: false))

    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
      documentStore: makeTestDocumentStore(),
      documentWindowRegistry: registry)
    registry.registerController(controller, for: launcher)
    controller.start(intent: .dockReopen)

    XCTAssertTrue(registry.isReusableLauncherWindow(launcher))
    XCTAssertTrue(controller.createUntitledDocument())
    XCTAssertEqual(factoryCalls, 0)
    XCTAssertTrue(appState.documentSession.hasEditableBuffer)
  }

  @MainActor
  func testNewOverADirtyRecoveredDraftNeverPromptsOrClonesIt() throws {
    for mode in Self.matrix {
      let rig = Rig(mode: mode)
      defer { rig.tearDown() }

      let recoveryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PensieveNewTabContract-\(UUID().uuidString)", isDirectory: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: recoveryRoot) }
      let recoveryStore = RecoveryStore(directoryURL: recoveryRoot)
      let draft = try recoveryStore.saveDraft(
        id: nil, title: "umowa.md", text: "contract text that must survive")
      XCTAssertEqual(recoveryStore.loadDrafts().count, 1, mode.name)

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
        confirmSaveChanges: { _, _, _, _ in saveSheets += 1 })
      rig.registry.registerController(controller, for: rig.sourceWindow)

      XCTAssertTrue(controller.createUntitledDocument(), mode.name)
      rig.assertTabPlacement(mode.name)
      XCTAssertEqual(savePrompts, 0, mode.name)
      XCTAssertEqual(saveSheets, 0, mode.name)
      XCTAssertEqual(appState.documentSession.identity, originalIdentity, mode.name)
      XCTAssertEqual(appState.activeDocumentText, "contract text that must survive", mode.name)
      XCTAssertTrue(appState.activeDocumentDirty, mode.name)
      XCTAssertEqual(recoveryStore.loadDrafts().count, 1, mode.name)
      XCTAssertEqual(recoveryStore.loadDrafts().first?.id, draft.id, mode.name)
    }
  }

  @MainActor
  fileprivate final class Rig {
    let sourceWindow: NSWindow
    let untitledWindow: NSWindow
    let registry: DocumentWindowRegistry

    private let counters = Counters()

    init(mode: Mode) {
      let sourceWindow =
        mode.sourceIsFullScreen
        ? FullScreenLikeWindow.make()
        : NewDocumentTabIntegrationTests.makeWindow(title: "Source")
      let untitledWindow = NewDocumentTabIntegrationTests.makeWindow()
      self.sourceWindow = sourceWindow
      self.untitledWindow = untitledWindow
      XCTAssertTrue(DocumentWindowOwnership.claimDocumentHost(sourceWindow), mode.name)

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
        makeDocumentWindow: { ref, intent in
          XCTAssertNil(ref, mode.name)
          XCTAssertEqual(intent, .newUntitledTab, mode.name)
          counters.factoryCalls += 1
          return untitledWindow
        })
    }

    func assertTabPlacement(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
      XCTAssertEqual(counters.factoryCalls, 1, label, file: file, line: line)
      XCTAssertEqual(counters.merges, 1, label, file: file, line: line)
      XCTAssertEqual(counters.activations, 1, label, file: file, line: line)
      XCTAssertEqual(
        untitledWindow.tabbingIdentifier, WindowChromeRecipe.documentTabbingIdentifier,
        label, file: file, line: line)
    }

    func tearDown() {
      untitledWindow.close()
      if !(sourceWindow is FullScreenLikeWindow) { sourceWindow.close() }
    }
  }

  @MainActor
  fileprivate final class Counters {
    var factoryCalls = 0
    var merges = 0
    var activations = 0
  }

  @MainActor
  fileprivate static func makeWindow(title: String = "") -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -9000, y: -9000, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = NSView(frame: .zero)
    window.title = title
    return window
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveNewTabContract-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }
}

private final class FullScreenLikeWindow: NSWindow {
  override var styleMask: NSWindow.StyleMask {
    get { super.styleMask.union(.fullScreen) }
    set { super.styleMask = newValue }
  }

  @MainActor
  static func make() -> FullScreenLikeWindow {
    let window = FullScreenLikeWindow(
      contentRect: NSRect(x: -9000, y: -9000, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = NSView(frame: .zero)
    window.title = "Source (full screen)"
    return window
  }
}
