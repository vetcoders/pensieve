import Foundation

/// Pure formatter for search results formatted as agent-ready XML blocks.
enum SearchResultAgentCopyFormatter {
  static func format(_ results: [WorkspaceSearchResult]) -> String {
    results.map { formatSingle($0) }.joined(separator: "\n\n")
  }

  static func formatSingle(_ result: WorkspaceSearchResult) -> String {
    let matchStr: String
    switch result.matchKind {
    case .title:
      matchStr = "title"
    case .path:
      matchStr = "path"
    case .body:
      matchStr = "body"
    }

    let escapedPath = escapeXMLAttribute(result.displayPath)
    let header =
      "<search_result path=\"\(escapedPath)\" match=\"\(matchStr)\" score=\"\(result.score)\">"

    if let snippet = result.snippet, !snippet.isEmpty {
      return "\(header)\n\(snippet)\n</search_result>"
    } else {
      return "\(header)\n</search_result>"
    }
  }

  private static func escapeXMLAttribute(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

/// Pure reducer and filter utilities for search result multi-selection state.
struct SearchResultSelectionState {
  static func toggleSelection(id: URL, in current: Set<URL>) -> Set<URL> {
    var updated = current
    if updated.contains(id) {
      updated.remove(id)
    } else {
      updated.insert(id)
    }
    return updated
  }

  static func selectSingle(id: URL) -> Set<URL> {
    [id]
  }

  static func filterSelected(
    from allResults: [WorkspaceSearchResult],
    selectedIDs: Set<URL>
  ) -> [WorkspaceSearchResult] {
    allResults.filter { selectedIDs.contains($0.id) }
  }
}
