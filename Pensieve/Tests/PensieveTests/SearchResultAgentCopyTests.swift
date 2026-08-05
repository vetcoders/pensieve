import XCTest

@testable import Pensieve

final class SearchResultAgentCopyTests: XCTestCase {
  func testFormatSingleResultWithSnippet() {
    let doc = DocumentRef(
      id: URL(fileURLWithPath: "/tmp/test.md"),
      isAdHoc: false
    )
    let result = WorkspaceSearchResult(
      document: doc,
      displayPath: "Docs/test.md",
      snippet: "This is a match snippet",
      matchKind: .body,
      score: 42,
      updatedAt: Date()
    )

    let formatted = SearchResultAgentCopyFormatter.formatSingle(result)
    let expected = """
      <search_result path="Docs/test.md" match="body" score="42">
      This is a match snippet
      </search_result>
      """
    XCTAssertEqual(formatted, expected)
  }

  func testFormatSingleResultWithoutSnippet() {
    let doc = DocumentRef(
      id: URL(fileURLWithPath: "/tmp/title.md"),
      isAdHoc: false
    )
    let result = WorkspaceSearchResult(
      document: doc,
      displayPath: "Docs/title.md",
      snippet: nil,
      matchKind: .title,
      score: 100,
      updatedAt: Date()
    )

    let formatted = SearchResultAgentCopyFormatter.formatSingle(result)
    let expected = """
      <search_result path="Docs/title.md" match="title" score="100">
      </search_result>
      """
    XCTAssertEqual(formatted, expected)
  }

  func testFormatMultipleResultsEscapesXMLAndPreservesOrder() {
    let url1 = URL(fileURLWithPath: "/tmp/a.md")
    let url2 = URL(fileURLWithPath: "/tmp/b.md")

    let res1 = WorkspaceSearchResult(
      document: DocumentRef(id: url1, isAdHoc: false),
      displayPath: "Docs/A & B \"quoted\".md",
      snippet: "Snippet 1",
      matchKind: .path,
      score: 10,
      updatedAt: Date()
    )
    let res2 = WorkspaceSearchResult(
      document: DocumentRef(id: url2, isAdHoc: false),
      displayPath: "Docs/B.md",
      snippet: "Snippet 2",
      matchKind: .body,
      score: 20,
      updatedAt: Date()
    )

    let formatted = SearchResultAgentCopyFormatter.format([res1, res2])
    let expected = """
      <search_result path="Docs/A &amp; B &quot;quoted&quot;.md" match="path" score="10">
      Snippet 1
      </search_result>

      <search_result path="Docs/B.md" match="body" score="20">
      Snippet 2
      </search_result>
      """
    XCTAssertEqual(formatted, expected)
  }

  func testSelectionStateToggleAndSingle() {
    let url1 = URL(fileURLWithPath: "/tmp/1.md")
    let url2 = URL(fileURLWithPath: "/tmp/2.md")

    var selection: Set<URL> = []
    selection = SearchResultSelectionState.toggleSelection(id: url1, in: selection)
    XCTAssertEqual(selection, [url1])

    selection = SearchResultSelectionState.toggleSelection(id: url2, in: selection)
    XCTAssertEqual(selection, [url1, url2])

    selection = SearchResultSelectionState.toggleSelection(id: url1, in: selection)
    XCTAssertEqual(selection, [url2])

    selection = SearchResultSelectionState.selectSingle(id: url1)
    XCTAssertEqual(selection, [url1])
  }

  func testFilterSelectedPreservesListOrder() {
    let url1 = URL(fileURLWithPath: "/tmp/1.md")
    let url2 = URL(fileURLWithPath: "/tmp/2.md")
    let url3 = URL(fileURLWithPath: "/tmp/3.md")

    let r1 = WorkspaceSearchResult(
      document: DocumentRef(id: url1, isAdHoc: false),
      displayPath: "1.md", snippet: nil, matchKind: .title, score: 30, updatedAt: Date()
    )
    let r2 = WorkspaceSearchResult(
      document: DocumentRef(id: url2, isAdHoc: false),
      displayPath: "2.md", snippet: nil, matchKind: .title, score: 20, updatedAt: Date()
    )
    let r3 = WorkspaceSearchResult(
      document: DocumentRef(id: url3, isAdHoc: false),
      displayPath: "3.md", snippet: nil, matchKind: .title, score: 10, updatedAt: Date()
    )

    let allResults = [r1, r2, r3]
    let selectedSet: Set<URL> = [url3, url1]

    let filtered = SearchResultSelectionState.filterSelected(
      from: allResults, selectedIDs: selectedSet)
    let filteredIDs = filtered.map { $0.id }
    XCTAssertEqual(filteredIDs, [url1, url3])
  }
}
