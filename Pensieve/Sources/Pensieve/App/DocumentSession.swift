import Foundation

struct DocumentSession: Equatable {
  enum Kind: Equatable {
    case empty
    case untitled(title: String)
    case fileBacked(DocumentRef)
  }

  private var kind: Kind
  var text: String
  var isDirty: Bool

  static let empty = DocumentSession(kind: .empty, text: "", isDirty: false)

  static func untitled(title: String = "Untitled.md") -> DocumentSession {
    DocumentSession(kind: .untitled(title: title), text: "", isDirty: false)
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

  var isUntitled: Bool {
    guard case .untitled = kind else { return false }
    return true
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
    case .untitled(let title):
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
    self.kind = .untitled(title: title)
    self.text = ""
    self.isDirty = false
  }

  mutating func clear() {
    self = .empty
  }
}
