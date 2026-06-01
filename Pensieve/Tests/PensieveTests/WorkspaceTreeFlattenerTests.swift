import Foundation
import XCTest

@testable import Pensieve

final class WorkspaceTreeFlattenerTests: XCTestCase {
  // MARK: - Fixtures

  private func document(_ id: String, _ name: String) -> WorkspaceNode {
    WorkspaceNode(
      id: id,
      name: name,
      kind: .document,
      url: URL(fileURLWithPath: "/\(id)"),
      children: nil
    )
  }

  private func folder(_ id: String, _ name: String, children: [WorkspaceNode]) -> WorkspaceNode {
    WorkspaceNode(
      id: id,
      name: name,
      kind: .folder,
      url: URL(fileURLWithPath: "/\(id)"),
      children: children
    )
  }

  /// Tree:
  /// root (folder)
  ///   childDoc (doc)
  ///   subFolder (folder)
  ///     deepDoc (doc)
  ///   tailDoc (doc)
  /// sibling (doc)
  private func sampleForest() -> [WorkspaceNode] {
    let root = folder(
      "root", "Root",
      children: [
        document("childDoc", "Child.md"),
        folder("subFolder", "Sub", children: [document("deepDoc", "Deep.md")]),
        document("tailDoc", "Tail.md"),
      ]
    )
    return [root, document("sibling", "Sibling.md")]
  }

  // MARK: - Tests

  func testCollapsedRootShowsOnlyTopLevelNodes() {
    let rows = flattenWorkspaceTree(sampleForest(), expandedNodeIDs: [])

    XCTAssertEqual(rows.map(\.id), ["root", "sibling"])
    XCTAssertEqual(rows.map(\.depth), [0, 0])
    // Collapsed folder reports isExpanded == false; document is always false.
    XCTAssertEqual(rows.map(\.isExpanded), [false, false])
  }

  func testExpandedRootRevealsDirectChildrenInOrder() {
    let rows = flattenWorkspaceTree(sampleForest(), expandedNodeIDs: ["root"])

    // subFolder is visible but collapsed, so deepDoc stays hidden.
    XCTAssertEqual(rows.map(\.id), ["root", "childDoc", "subFolder", "tailDoc", "sibling"])
    XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 1, 0])
    // root expanded -> true; subFolder collapsed -> false; docs -> false.
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.isExpanded) }),
      ["root": true, "childDoc": false, "subFolder": false, "tailDoc": false, "sibling": false]
    )
  }

  func testFullyExpandedRevealsDeepDescendantsWithCorrectDepth() {
    let rows = flattenWorkspaceTree(sampleForest(), expandedNodeIDs: ["root", "subFolder"])

    XCTAssertEqual(
      rows.map(\.id),
      ["root", "childDoc", "subFolder", "deepDoc", "tailDoc", "sibling"]
    )
    XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 2, 1, 0])
    XCTAssertTrue(rows.first(where: { $0.id == "subFolder" })?.isExpanded == true)
  }

  func testDeepNodeHiddenWhenAncestorCollapsedEvenIfDeepNodeIsExpanded() {
    // subFolder is in the expanded set but its parent `root` is collapsed:
    // walk only visits expanded branches, so neither subFolder nor deepDoc appear.
    let rows = flattenWorkspaceTree(sampleForest(), expandedNodeIDs: ["subFolder"])

    XCTAssertEqual(rows.map(\.id), ["root", "sibling"])
    XCTAssertFalse(rows.contains { $0.id == "deepDoc" })
    XCTAssertFalse(rows.contains { $0.id == "subFolder" })
  }

  func testFlatteningIsPureWithRespectToSelectionAndHover() {
    // No selection/hover input exists in the signature: identical inputs must
    // yield identical output regardless of any UI state elsewhere.
    let forest = sampleForest()
    let first = flattenWorkspaceTree(forest, expandedNodeIDs: ["root", "subFolder"])
    let second = flattenWorkspaceTree(forest, expandedNodeIDs: ["root", "subFolder"])

    XCTAssertEqual(first, second)
  }

  func testEmptyExpandedFolderProducesNoChildRows() {
    let forest = [folder("empty", "Empty", children: [])]
    let rows = flattenWorkspaceTree(forest, expandedNodeIDs: ["empty"])

    XCTAssertEqual(rows.map(\.id), ["empty"])
    XCTAssertEqual(rows.first?.isExpanded, true)
  }
}
