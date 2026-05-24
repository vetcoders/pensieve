import Foundation

struct WorkspaceSearchResult: Identifiable, Hashable {
    enum MatchKind: Int, Hashable {
        case title
        case path
        case body
    }

    var document: DocumentRef
    var displayPath: String
    var snippet: String?
    var matchKind: MatchKind
    var score: Int
    var updatedAt: Date

    var id: URL { document.id }
    var title: String { document.title }
    var isAdHoc: Bool { document.isAdHoc }
}
