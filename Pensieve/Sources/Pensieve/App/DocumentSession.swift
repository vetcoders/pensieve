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
      guard case .fileBacked(let document) = kind else { return nil }
      return document
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
    case .fileBacked(let document):
      return .file(document.url.standardizedFileURL)
    }
  }

  var isUntitled: Bool {
    guard case .untitled = kind else { return false }
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
    case .empty:
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
    case .fileBacked(let document):
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
