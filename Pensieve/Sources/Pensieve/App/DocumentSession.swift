import Foundation

struct DocumentSession: Equatable {
  enum Kind: Equatable {
    case empty
    case untitled(title: String, recoveryID: UUID?)
    case fileBacked(DocumentRef)
  }

  private var kind: Kind
  var text: String
  var isDirty: Bool

  static let empty = DocumentSession(kind: .empty, text: "", isDirty: false)

  static func untitled(title: String = "Untitled.md") -> DocumentSession {
    DocumentSession(kind: .untitled(title: title, recoveryID: nil), text: "", isDirty: false)
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

  var persistentAIDocumentID: String? {
    if let url {
      return "file:\(url.standardizedFileURL.absoluteString)"
    }
    if let recoveryID {
      return "recovery:\(recoveryID.uuidString.lowercased())"
    }
    return nil
  }

  var isUntitled: Bool {
    guard case .untitled = kind else { return false }
    return true
  }

  var recoveryID: UUID? {
    get {
      guard case .untitled(_, let recoveryID) = kind else { return nil }
      return recoveryID
    }
    set {
      guard case .untitled(let title, _) = kind else { return }
      kind = .untitled(title: title, recoveryID: newValue)
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
    case .untitled(let title, _):
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
    self.kind = .untitled(title: title, recoveryID: nil)
    self.text = ""
    self.isDirty = false
  }

  mutating func restoreUntitled(title: String, text: String, recoveryID: UUID) {
    self.kind = .untitled(title: title, recoveryID: recoveryID)
    self.text = text
    self.isDirty = true
  }

  mutating func clear() {
    self = .empty
  }
}
