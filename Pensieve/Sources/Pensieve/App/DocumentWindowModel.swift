import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class DocumentWindowModel {
  private static let previewAutoReloadKey = "Pensieve.previewAutoReload"
  private static let tableTidyOnPasteKey = "Pensieve.tableTidyOnPaste"
  private static let asciiSafeTablesKey = "Pensieve.asciiSafeTables"
  private static let aiAutocompleteEnabledKey = "Pensieve.aiAutocompleteEnabled"
  private static let scrollSyncEnabledKey = "Pensieve.scrollSyncEnabled"
  private static let showAllFilesInSidebarKey = "Pensieve.showAllFilesInSidebar"
  private let defaults: UserDefaults

  var selectedDocumentID: DocumentRef.ID?

  /// The single source of truth for the open document (kind + text + dirty).
  /// Typing reassigns this struct on every keystroke, so any view that reads
  /// `documentSession` directly re-renders per keystroke. The editor and the
  /// preview WANT that (they read `.text`). The window chrome (title bar, split
  /// gating, sidebar) must NOT — it reads the discrete mirrors below instead,
  /// which only change when the metadata actually changes (guarded didSet).
  var documentSession: DocumentSession = .empty {
    didSet {
      let identity = documentSession.identity
      if documentIdentity != identity { documentIdentity = identity }
      let title = documentSession.displayTitle
      if documentTitle != title { documentTitle = title }
      let editable = documentSession.hasEditableBuffer
      if documentHasEditableBuffer != editable { documentHasEditableBuffer = editable }
      let url = documentSession.url
      if documentURL != url { documentURL = url }
      if documentIsDirty != documentSession.isDirty { documentIsDirty = documentSession.isDirty }
      let loading = documentSession.isLoading
      if documentIsLoading != loading { documentIsLoading = loading }
    }
  }

  /// Stable per-window identity used only as the AI-session fallback while the
  /// window has no document. `DocumentAISessionStore` keys sessions by this
  /// string; a shared constant ("window:empty") would collapse every empty
  /// window onto ONE session, so multiple empty windows would share — and
  /// overwrite — each other's continuation. A per-instance UUID keeps them
  /// isolated. It is never persisted across launches: an empty window has no
  /// document, so autocomplete produces no continuation to store under this key
  /// (the moment a document loads, `documentIdentity` is non-nil and the real
  /// `persistentID` takes over), so no unbounded empty-window records accrue.
  private let windowInstanceID = UUID()

  /// Counts the conscious closes this window has performed (File > Close, the
  /// sidebar's close, the tab "×" answering the save question). Restoration
  /// flows capture it when they start and refuse to select a document if it
  /// moved while they were walking the workspace — no restoration may reverse a
  /// close the user asked for. A counter rather than a flag: a flag would also
  /// block the NEXT open the user performs, a generation only blocks the flow
  /// that was already in flight.
  private(set) var documentCloseGeneration: Int = 0

  /// Records that this window's document was closed on purpose.
  func noteConsciousDocumentClose() {
    documentCloseGeneration &+= 1
  }

  var aiDocumentID: String {
    documentIdentity?.persistentID ?? "window:\(windowInstanceID.uuidString.lowercased())"
  }

  /// Discrete, low-frequency mirrors of `documentSession` metadata. Chrome views
  /// read THESE (not `documentSession`) so a text-only edit never invalidates
  /// them — that is what stops the whole window re-rendering on every keystroke.
  private(set) var documentTitle: String = ""
  private(set) var documentIdentity: DocumentIdentity?
  private(set) var documentHasEditableBuffer: Bool = false
  private(set) var documentURL: URL?
  private(set) var documentIsDirty: Bool = false
  private(set) var documentIsLoading: Bool = false

  // MARK: - Staged open claim

  /// Which staged open this window is currently answering to.
  ///
  /// A background read has to be able to ask "am I still the load this window
  /// wants?" before it applies anything, and a URL cannot answer that — the user
  /// can close a file and reopen the SAME one while the first read is in flight,
  /// and the stale result would then match by URL and clobber the newer session.
  /// A strictly increasing per-window counter answers it exactly: every claim is
  /// unique for the life of the window, so an apply either holds the current
  /// number or is provably obsolete.
  ///
  /// Observation-ignored: it changes once per open and is read only by the store,
  /// never by a view.
  @ObservationIgnored private(set) var documentLoadClaim: UInt64 = 0

  /// The in-flight background read, held only so it can be cancelled. Its result
  /// is dropped by the claim check regardless — this is about not leaving work
  /// running for a window nobody is looking at any more.
  @ObservationIgnored private var pendingDocumentLoad: Task<Void, Never>?

  /// Claims this window for a NEW document load and invalidates every earlier
  /// one. Called by both open paths — the synchronous one too, which is what
  /// makes "a small file opened over a large one in flight wins" true without a
  /// special case.
  @discardableResult
  func beginDocumentLoad() -> UInt64 {
    pendingDocumentLoad?.cancel()
    pendingDocumentLoad = nil
    documentLoadClaim &+= 1
    return documentLoadClaim
  }

  func trackPendingDocumentLoad(_ task: Task<Void, Never>) {
    pendingDocumentLoad = task
  }

  func isCurrentDocumentLoad(_ claim: UInt64) -> Bool {
    claim == documentLoadClaim
  }

  /// The claimed load has landed. Drops the task handle without bumping the
  /// claim: the session that just arrived IS the current one.
  func finishDocumentLoad(_ claim: UInt64) {
    guard isCurrentDocumentLoad(claim) else { return }
    pendingDocumentLoad = nil
  }

  /// Window teardown, or any other abandonment of the in-flight open. Bumps the
  /// claim so a read already past cancellation cannot apply into a window that is
  /// on its way out.
  func cancelPendingDocumentLoad() {
    pendingDocumentLoad?.cancel()
    pendingDocumentLoad = nil
    documentLoadClaim &+= 1
  }

  deinit {
    pendingDocumentLoad?.cancel()
  }

  var mode: EditorMode = .split
  var fontSize: CGFloat = 14
  var richMarkdownEnabled: Bool = true
  var pendingMarkdownFormatCommand: MarkdownFormatCommand?
  var pendingAIRewriteCommand: AIRewriteCommand?
  var aiRewritePreview: AIRewritePreview?
  var findBarVisible: Bool = false
  var findReplaceMode: Bool = false
  var findQuery: String = ""
  var findReplaceQuery: String = ""
  var findFocusToken: Int = 0
  var pendingFindCommand: FindBarCommand?
  var findMatchCount: Int = 0
  var findActiveMatchIndex: Int?
  /// Caret/selection state surfaced by the editor for the status bar. UTF-16
  /// units, as AppKit reports them; the status bar resolves line/column lazily.
  var caretUTF16Offset: Int = 0
  var selectionUTF16Length: Int = 0
  var tableTidyOnPaste: Bool {
    didSet {
      defaults.set(tableTidyOnPaste, forKey: Self.tableTidyOnPasteKey)
    }
  }
  var asciiSafeTables: Bool {
    didSet {
      defaults.set(asciiSafeTables, forKey: Self.asciiSafeTablesKey)
    }
  }
  var aiAutocompleteEnabled: Bool {
    didSet {
      defaults.set(aiAutocompleteEnabled, forKey: Self.aiAutocompleteEnabledKey)
    }
  }
  var scrollSyncEnabled: Bool {
    didSet {
      defaults.set(scrollSyncEnabled, forKey: Self.scrollSyncEnabledKey)
    }
  }
  var previewAutoReload: Bool {
    didSet {
      defaults.set(previewAutoReload, forKey: Self.previewAutoReloadKey)
    }
  }
  var previewRefreshToken: Int = 0
  var sidebarVisible: Bool = true
  /// Whether non-markdown ("foreign") files show up greyed-out in the sidebar.
  /// Off by default: on a real vault the scanner-emitted `.foreignFile` nodes
  /// are visual noise at scale, so they stay hidden until explicitly requested.
  var showAllFilesInSidebar: Bool {
    didSet {
      defaults.set(showAllFilesInSidebar, forKey: Self.showAllFilesInSidebarKey)
    }
  }
  /// This window's most recent error, or `nil` when it has nothing to report.
  ///
  /// Was a bare `String?` that nothing rendered: it was written from ~35 sites
  /// across the app and read by no view at all, so every failure the app knew
  /// about — including a crash-recovery draft that could not be written — was
  /// recorded and never shown. It now backs `WindowErrorBanner`, and carries the
  /// severity that decides whether a passive line is enough.
  var currentError: WindowError?

  /// A data-loss error this window has not yet ALERTED about. Set only on the
  /// transition into a new data-loss condition, so a failing autosave repeating
  /// the same error every 1.5 s asks once instead of once per tick. Presented
  /// and cleared by `ContentView`, exactly like `pendingDispatchIntent`.
  var pendingDataLossAlert: WindowError?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if defaults.object(forKey: Self.previewAutoReloadKey) == nil {
      self.previewAutoReload = false
    } else {
      self.previewAutoReload = defaults.bool(forKey: Self.previewAutoReloadKey)
    }
    if defaults.object(forKey: Self.tableTidyOnPasteKey) == nil {
      self.tableTidyOnPaste = true
    } else {
      self.tableTidyOnPaste = defaults.bool(forKey: Self.tableTidyOnPasteKey)
    }
    if defaults.object(forKey: Self.asciiSafeTablesKey) == nil {
      self.asciiSafeTables = false
    } else {
      self.asciiSafeTables = defaults.bool(forKey: Self.asciiSafeTablesKey)
    }
    if defaults.object(forKey: Self.aiAutocompleteEnabledKey) == nil {
      self.aiAutocompleteEnabled = false
    } else {
      self.aiAutocompleteEnabled = defaults.bool(forKey: Self.aiAutocompleteEnabledKey)
    }
    if defaults.object(forKey: Self.scrollSyncEnabledKey) == nil {
      self.scrollSyncEnabled = false
    } else {
      self.scrollSyncEnabled = defaults.bool(forKey: Self.scrollSyncEnabledKey)
    }
    if defaults.object(forKey: Self.showAllFilesInSidebarKey) == nil {
      self.showAllFilesInSidebar = false
    } else {
      self.showAllFilesInSidebar = defaults.bool(forKey: Self.showAllFilesInSidebarKey)
    }
    // Seed the metadata mirrors from the initial (empty) session. didSet does
    // not fire during init, so prime them explicitly to stay consistent.
    self.documentIdentity = documentSession.identity
    self.documentTitle = documentSession.displayTitle
    self.documentHasEditableBuffer = documentSession.hasEditableBuffer
    self.documentIsLoading = documentSession.isLoading
    self.documentURL = documentSession.url
    self.documentIsDirty = documentSession.isDirty
  }

  func bumpFontSize(by delta: CGFloat) {
    fontSize = max(8, min(48, fontSize + delta))
  }

  func resetFontSize() {
    fontSize = 14
  }

  func requestPreviewRefresh() {
    previewRefreshToken &+= 1
  }
}
