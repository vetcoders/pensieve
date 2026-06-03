import Foundation

/// A single materialized row in the flattened, lazily-rendered workspace tree.
///
/// The sidebar renders a `List` over an array of these rows instead of an eagerly
/// built recursive `VStack` of nested `AnyView`s. Only nodes that are visible
/// (i.e. every ancestor folder is expanded) appear in the array, so `List` —
/// which lazily materializes only its on-screen direct rows — never has to build
/// the entire expanded subtree at once.
struct FlattenedWorkspaceRow: Identifiable, Hashable {
  /// Stable identity for `List`/`ForEach`. Equal to the underlying node id, which
  /// is unique within the tree.
  var id: WorkspaceNode.ID { node.id }

  let node: WorkspaceNode
  let depth: Int
  /// `true` only for folders that are currently expanded. Documents are always
  /// `false`. Used purely for chevron direction; selection/hover are computed
  /// separately at render time and are intentionally NOT part of this value type.
  let isExpanded: Bool
}

/// Pure, deterministic depth-first flattening of a workspace forest into the
/// list of currently-visible rows.
///
/// Walks only expanded branches: a folder's children are appended only when the
/// folder's id is present in `expandedNodeIDs`. This makes the walk O(visible)
/// rather than O(total) — the cost scales with what is on screen, not with the
/// full (possibly enormous) tree. The output order matches the original
/// recursive render: each node immediately precedes its visible descendants
/// (pre-order), preserving the on-screen ordering exactly.
///
/// The function is intentionally free of any selection/hover state so it can be
/// unit-tested deterministically and so that selection/hover changes do not
/// require re-flattening.
func flattenWorkspaceTree(
  _ roots: [WorkspaceNode],
  expandedNodeIDs: Set<WorkspaceNode.ID>
) -> [FlattenedWorkspaceRow] {
  var rows: [FlattenedWorkspaceRow] = []
  appendFlattenedWorkspaceRows(
    roots,
    depth: 0,
    expandedNodeIDs: expandedNodeIDs,
    into: &rows
  )
  return rows
}

private func appendFlattenedWorkspaceRows(
  _ nodes: [WorkspaceNode],
  depth: Int,
  expandedNodeIDs: Set<WorkspaceNode.ID>,
  into rows: inout [FlattenedWorkspaceRow]
) {
  for node in nodes {
    if node.kind == .document {
      rows.append(FlattenedWorkspaceRow(node: node, depth: depth, isExpanded: false))
      continue
    }

    let isExpanded = expandedNodeIDs.contains(node.id)
    rows.append(FlattenedWorkspaceRow(node: node, depth: depth, isExpanded: isExpanded))

    guard isExpanded, let children = node.children else { continue }
    appendFlattenedWorkspaceRows(
      children,
      depth: depth + 1,
      expandedNodeIDs: expandedNodeIDs,
      into: &rows
    )
  }
}
