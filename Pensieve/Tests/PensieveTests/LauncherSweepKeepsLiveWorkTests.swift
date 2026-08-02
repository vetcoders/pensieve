import AppKit
import XCTest

@testable import Pensieve

/// The launcher sweep exists to reap empty "Pensieve" windows left behind by
/// tab churn and Dock reopens. It ran 0.2s after a launcher registered and
/// decided what was empty from registry bookkeeping ALONE — which cannot see a
/// window's actual session. Two windows are invisible to that bookkeeping:
///
///   * the window holding a recovered crash draft (no URL ⇒ the accessor never
///     publishes a document identity ⇒ it stays filed as a launcher), and
///   * the window still waiting for its launch restore (the document is
///     coming, it just has not reached the accessor yet).
///
/// Both were reaped. Whichever one lost the 0.2s race disappeared, and a window
/// closed before its document loaded has an empty session — so the "reopen this
/// on launch" record was never retired and the next launch resurrected the same
/// document. These pins fire the sweep DIRECTLY through the injected scheduler,
/// so the race is decided by the test, not by timing.
final class LauncherSweepKeepsLiveWorkTests: XCTestCase {

  // ── (a) the window holding the crash draft survives the sweep ────────────
  @MainActor
  func testSweepKeepsTheWindowHoldingTheRecoveredDraft() throws {
    let harness = try Harness(self)
    let documentWindow = harness.openDocumentWindow(at: harness.documentURL)
    let draftWindow = harness.openLauncherWindow()

    // The draft lands in the launcher window through the real adoption path:
    // real work, no URL behind it, so only the explicit promotion can reclassify
    // the window out of "launcher".
    harness.stashRecoveryDraft(text: "unsaved crash draft")
    let draft = harness.attachController(to: draftWindow)
    let registry = harness.registry
    draft.controller.requestPromoteWindowToContent = {
      registry.markWindowAsContent(draftWindow)
    }
    draft.controller.start(restoringWorkspace: true)
    XCTAssertEqual(
      draft.appState.documentSession.text, "unsaved crash draft",
      "the window under test never adopted the draft, so the pin proves nothing")

    harness.fireSweep()

    XCTAssertFalse(
      harness.wasClosed(draftWindow),
      "the sweep reaped the window holding the recovered crash draft — the user's unsaved "
        + "work vanished 0.2s after the window appeared")
    XCTAssertFalse(harness.wasClosed(documentWindow))
  }

  // ── (b) the window still resolving its launch survives the sweep ────────
  @MainActor
  func testSweepKeepsAWindowWhoseLaunchHasNotResolvedYet() throws {
    let harness = try Harness(self)

    // The starting window is a launcher until it knows what it will show. A
    // second window already counts as content, so the sweep's "close all
    // launchers" arm is armed — this is the mirror of the draft-window race.
    let restoringWindow = harness.openLauncherWindow()
    let restoring = harness.attachController(to: restoringWindow)
    let otherWindow = harness.openDocumentWindow(at: harness.otherURL)

    harness.fireSweep()

    XCTAssertFalse(
      harness.wasClosed(restoringWindow),
      "the sweep reaped the window before its launch resolved — anything it was about to "
        + "show was lost with it")
    XCTAssertFalse(harness.wasClosed(otherWindow))
    XCTAssertTrue(restoring.controller.isAwaitingLaunchRestore)
  }

  // ── (c) control: a genuinely empty launcher is still reaped ──────────────
  @MainActor
  func testSweepStillReapsAnEmptyLauncherOnceItsLaunchDecisionSettles() throws {
    let harness = try Harness(self)
    _ = harness.openDocumentWindow(at: harness.documentURL)

    // A Dock-reopen / "+" launcher: its launch decision is settled and it holds
    // nothing at all.
    let emptyLauncher = harness.openLauncherWindow()
    let launcher = harness.attachController(to: emptyLauncher)
    launcher.controller.start(restoringWorkspace: true)
    XCTAssertFalse(
      launcher.appState.documentSession.hasEditableBuffer,
      "this launcher picked something up, so it is not the empty-launcher control leg")

    harness.fireSweep()

    XCTAssertTrue(
      harness.wasClosed(emptyLauncher),
      "protecting live work also spared a launcher with nothing in it — the sweep no longer "
        + "does the job it exists for")
  }

  // ── (d) control: the settle pass reaps what the protection deferred ──────
  @MainActor
  func testAProtectedLauncherIsReapedOnTheSweepThatFollowsItsRestore() throws {
    let harness = try Harness(self)
    _ = harness.openDocumentWindow(at: harness.documentURL)

    let launcherWindow = harness.openLauncherWindow()
    let launcher = harness.attachController(to: launcherWindow)
    let registry = harness.registry
    launcher.controller.requestLauncherSweepReconcile = {
      registry.reconcileLaunchersAfterRestoreSettled()
    }

    // Sweep #1 lands while the launch decision is still open: protected.
    harness.fireSweep()
    XCTAssertFalse(harness.wasClosed(launcherWindow))

    // The restore settles with nothing to show and asks for another sweep.
    launcher.controller.start(restoringWorkspace: true)
    harness.fireSweep()

    XCTAssertTrue(
      harness.wasClosed(launcherWindow),
      "the deferred reap never happened — protecting an in-flight restore leaked an empty "
        + "launcher instead of just delaying its cleanup")
  }

  // ── harness ──────────────────────────────────────────────────────────────

  /// Mutable state the registry's injected closures write into. It has to be a
  /// reference the closures can capture before `Harness` finishes initializing.
  private final class SweepJournal {
    var pendingSweeps: [() -> Void] = []
    var closedWindows: [NSWindow] = []
    var liveWindows: [NSWindow] = []
    var firedCount = 0
  }

  private struct Session {
    let controller: AppController
    let appState: AppState
  }

  @MainActor
  private final class Harness {
    let folder: URL
    let documentURL: URL
    let otherURL: URL
    let registry: DocumentWindowRegistry

    private let journal = SweepJournal()
    private let bookmarkStore: BookmarkStore
    private let recoveryStore: RecoveryStore
    private var sessions: [Session] = []

    init(_ testCase: XCTestCase) throws {
      folder = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "PensieveLauncherSweepTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      documentURL = folder.appendingPathComponent("DPA_Zalacznik.md")
      try "the document the user was reading".write(
        to: documentURL, atomically: true, encoding: .utf8)
      otherURL = folder.appendingPathComponent("other.md")
      try "another document".write(to: otherURL, atomically: true, encoding: .utf8)

      bookmarkStore = BookmarkStore(
        defaults: testCase.makeEphemeralDefaults(prefix: "PensieveLauncherSweepTests"))
      recoveryStore = RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))

      let journal = self.journal
      registry = DocumentWindowRegistry(
        canMutateWindowTabs: { false },
        scheduleDeferredMainWork: { _ in },
        scheduleLauncherWindowSweep: { journal.pendingSweeps.append($0) },
        mergeWindowIntoTabs: { _, _ in },
        orderAndActivateWindow: { _ in },
        currentMergeTarget: { nil },
        applicationWindows: { journal.liveWindows },
        closeWindow: { window in
          journal.closedWindows.append(window)
          journal.liveWindows.removeAll { $0 === window }
          window.close()
        }
      )

      let folderRef = folder
      testCase.addTeardownBlock {
        await MainActor.run {
          for window in journal.liveWindows { window.close() }
        }
        try? FileManager.default.removeItem(at: folderRef)
      }
    }

    /// Runs every sweep scheduled since the last call — the injected scheduler
    /// makes the 0.2s race a decision the test makes explicitly.
    func fireSweep() {
      let sweeps = journal.pendingSweeps
      for sweep in sweeps.dropFirst(journal.firedCount) { sweep() }
      journal.firedCount = sweeps.count
    }

    func wasClosed(_ window: NSWindow) -> Bool {
      journal.closedWindows.contains { $0 === window }
    }

    func openLauncherWindow() -> NSWindow {
      let window = Self.makeWindow()
      journal.liveWindows.append(window)
      registry.makeDocumentWindow = { _ in window }
      registry.openLauncherWindow()
      registry.makeDocumentWindow = nil
      return window
    }

    func openDocumentWindow(at url: URL) -> NSWindow {
      let window = Self.makeWindow(title: url.lastPathComponent)
      journal.liveWindows.append(window)
      registry.attach(window, documentID: url.standardizedFileURL)
      return window
    }

    @discardableResult
    func attachController(to window: NSWindow) -> Session {
      let appState = AppState()
      let controller = AppController(
        appState: appState,
        folderManager: FolderManager(
          metadataStore: WorkspaceMetadataStore(
            metadataURL: folder.appendingPathComponent("workspace-\(UUID().uuidString).json")),
          indexDatabase: IndexDatabase(
            databaseURL: folder.appendingPathComponent("index-\(UUID().uuidString).db")),
          bookmarkStore: bookmarkStore),
        documentStore: DocumentStore(
          indexDatabase: IndexDatabase(
            databaseURL: folder.appendingPathComponent("index-\(UUID().uuidString).db")),
          bookmarkStore: bookmarkStore,
          recoveryStore: recoveryStore),
        indexDatabase: IndexDatabase(
          databaseURL: folder.appendingPathComponent("index-\(UUID().uuidString).db")),
        documentWindowRegistry: registry
      )
      let session = Session(controller: controller, appState: appState)
      sessions.append(session)
      registry.registerController(controller, for: window)
      return session
    }

    /// Leaves an unsaved untitled buffer behind the way a crash/quit does, so a
    /// later `start` finds a pending recovery draft to adopt.
    func stashRecoveryDraft(text: String) {
      let appState = AppState()
      let store = DocumentStore(
        indexDatabase: IndexDatabase(
          databaseURL: folder.appendingPathComponent("index-\(UUID().uuidString).db")),
        bookmarkStore: bookmarkStore,
        recoveryStore: recoveryStore)
      appState.documentSession.createUntitled(title: "Untitled.md")
      appState.activeDocumentText = text
      store.documentDidChange(appState: appState)
      _ = store.savePendingChangesOnClose(appState: appState)
    }

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
}
