import Foundation

enum DocumentIdentity: Hashable {
  case file(URL)
  case untitled(UUID)
  case recovered(UUID)

  var standardized: DocumentIdentity {
    guard case .file(let url) = self else { return self }
    return .file(url.standardizedFileURL)
  }

  var fileURL: URL? {
    guard case .file(let url) = standardized else { return nil }
    return url
  }

  var persistentID: String {
    switch standardized {
    case .file(let url):
      return "file:\(url.absoluteString)"
    case .untitled(let id):
      return "untitled:\(id.uuidString.lowercased())"
    case .recovered(let id):
      return "recovery:\(id.uuidString.lowercased())"
    }
  }
}

struct DocumentSession: Equatable {
  enum Kind: Equatable {
    case empty
    /// A file this window has CLAIMED but whose bytes are still being read off
    /// the main actor — the staged half of a large-document open.
    ///
    /// It carries the document, so the window, the tab, the title bar and the
    /// registry all name the right file from the moment the user clicked, and
    /// every post-condition the synchronous open path publishes in its own turn
    /// (`selectedDocumentID`, `documentSession.url`) still holds in that turn.
    ///
    /// It does NOT carry an editable buffer. The text is empty until the read
    /// lands, and `hasEditableBuffer` is what the whole document command surface
    /// gates on — Save, Save As, Export, Share, Dispatch, the editor and the
    /// preview all go quiet — so no surface can act on, or worse WRITE, the
    /// empty placeholder buffer standing in for a file that is still loading.
    case loading(DocumentRef)
    case untitled(title: String, identity: DocumentIdentity, recoveryID: UUID?)
    case fileBacked(DocumentRef)
  }

  private var kind: Kind
  var text: String
  var isDirty: Bool

  static let empty = DocumentSession(kind: .empty, text: "", isDirty: false)

  static func untitled(
    title: String = "Untitled.md",
    identityID: UUID = UUID()
  ) -> DocumentSession {
    DocumentSession(
      kind: .untitled(title: title, identity: .untitled(identityID), recoveryID: nil),
      text: "",
      isDirty: false)
  }

  var document: DocumentRef? {
    get {
      switch kind {
      // A staged open answers with its document too: the file is the one this
      // window is on, and everything keyed on document IDENTITY — the tab, the
      // registry mapping, Open Recent's "did this window actually land on the
      // file" post-condition — has to agree with the user's click immediately,
      // not one background read later.
      case .fileBacked(let document), .loading(let document):
        return document
      case .empty, .untitled:
        return nil
      }
    }
    set {
      kind = newValue.map(Kind.fileBacked) ?? .empty
    }
  }

  var url: URL? {
    document?.url
  }

  var id: DocumentRef.ID? {
    document?.id
  }

  var identity: DocumentIdentity? {
    switch kind {
    case .empty:
      return nil
    case .untitled(_, let identity, _):
      return identity.standardized
    case .fileBacked(let document), .loading(let document):
      return .file(document.url.standardizedFileURL)
    }
  }

  var isUntitled: Bool {
    guard case .untitled = kind else { return false }
    return true
  }

  /// This window has claimed a file and is still reading it off the main actor.
  ///
  /// Distinct from "has no buffer": an EMPTY window is idle and reapable, a
  /// LOADING one is spoken for. Everything that asks "is this window free?" —
  /// the registry's launcher sweep, the open router deciding between this window
  /// and a new tab, the crash-draft restore — has to tell those two apart, the
  /// same way `AppController.hasPendingImportWork` already makes them tell an
  /// in-flight Word/PDF conversion apart from an idle window.
  var isLoading: Bool {
    guard case .loading = kind else { return false }
    return true
  }

  var recoveryID: UUID? {
    get {
      guard case .untitled(_, _, let recoveryID) = kind else { return nil }
      return recoveryID
    }
    set {
      guard case .untitled(let title, let identity, _) = kind else { return }
      // Once a draft is backed by a recovery record its persistent identity must
      // become `.recovered(recoveryID)` — the SAME key a post-relaunch restore
      // rebuilds via `restoreUntitled`. Keeping the ephemeral `.untitled(uuid)`
      // key here would derive the AI session store key `untitled:<uuid>` before
      // close but `recovery:<recoveryID>` after restore, silently dropping the
      // AI continuation saved for this draft. Nil clears (discard) keep identity.
      let resolvedIdentity = newValue.map(DocumentIdentity.recovered) ?? identity
      kind = .untitled(title: title, identity: resolvedIdentity, recoveryID: newValue)
    }
  }

  var hasEditableBuffer: Bool {
    switch kind {
    // `.loading` is false BY DESIGN, not by omission. Its buffer is an empty
    // placeholder standing in for bytes that have not arrived; every write path
    // in the app gates on this predicate, so answering true here would let a ⌘S
    // during a large open truncate the file being opened.
    case .empty, .loading:
      return false
    case .untitled, .fileBacked:
      return true
    }
  }

  var displayTitle: String {
    switch kind {
    case .empty:
      return ""
    case .untitled(let title, _, _):
      return title
    case .fileBacked(let document), .loading(let document):
      return document.title
    }
  }

  init(document: DocumentRef?, text: String = "", isDirty: Bool = false) {
    self.kind = document.map(Kind.fileBacked) ?? .empty
    self.text = text
    self.isDirty = isDirty
  }

  private init(kind: Kind, text: String, isDirty: Bool) {
    self.kind = kind
    self.text = text
    self.isDirty = isDirty
  }

  mutating func load(document: DocumentRef, text: String) {
    self.kind = .fileBacked(document)
    self.text = text
    self.isDirty = false
  }

  /// Claims `document` for this window while its bytes are read off the main
  /// actor. The buffer is empty and NOT editable until `load(document:text:)`
  /// lands the real text — see `Kind.loading`.
  mutating func beginLoading(document: DocumentRef) {
    self.kind = .loading(document)
    self.text = ""
    self.isDirty = false
  }

  mutating func createUntitled(title: String = "Untitled.md") {
    self.kind = .untitled(title: title, identity: .untitled(UUID()), recoveryID: nil)
    self.text = ""
    self.isDirty = false
  }

  mutating func restoreUntitled(title: String, text: String, recoveryID: UUID) {
    self.kind = .untitled(
      title: title,
      identity: .recovered(recoveryID),
      recoveryID: recoveryID)
    self.text = text
    self.isDirty = true
  }

  mutating func clear() {
    self = .empty
  }
}
