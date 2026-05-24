import Foundation

struct DocumentSession: Equatable {
    var document: DocumentRef?
    var text: String
    var isDirty: Bool

    static let empty = DocumentSession(document: nil, text: "", isDirty: false)

    var url: URL? {
        document?.url
    }

    var id: DocumentRef.ID? {
        document?.id
    }

    init(document: DocumentRef?, text: String = "", isDirty: Bool = false) {
        self.document = document
        self.text = text
        self.isDirty = isDirty
    }

    mutating func load(document: DocumentRef, text: String) {
        self.document = document
        self.text = text
        self.isDirty = false
    }

    mutating func clear() {
        self = .empty
    }
}
