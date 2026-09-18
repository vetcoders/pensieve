import Foundation
import Observation

/// A single materialized row in the flattened, lazily-rendered workspace tree.
///
/// The sidebar renders a `List` over an array of these rows instead of an eagerly
/// built recursive `VStack` of nested `AnyView`s. Only nodes that are visible
/// (i.e. every ancestor folder is expanded) appear in the array, so `List` —
/// which lazily materializes only its on-screen direct rows — never has to build
/// the entire expanded subtree at once.
struct FlattenedWorkspaceRow: Identifiable, Hashable, Sendable {
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

/// Publishes a flattened snapshot of the visible workspace rows, computed OFF
/// the main actor.
///
/// `SidebarView` feeds every tree / expansion / visibility change into
/// `publish` and renders `rows`. The flatten itself runs on a detached task:
/// when a large workspace republish lands thousands of nodes on
/// `workspaceTree`, the main actor only records the latest request — the
/// O(visible) walk happens off main, and intermediate republishes coalesce
/// (latest wins) instead of each paying a full flatten. A momentarily stale
/// tree is the accepted trade for never blocking click-file.
@Observable
@MainActor
final class WorkspaceTreeSnapshotStore {
  /// Test seam: the flatten implementation. Defaults to the real
  /// `flattenWorkspaceTree`; tests inject a probe to assert the closure is
  /// never invoked on the main thread during a republish.
  typealias Flatten =
    @Sendable (
      _ roots: [WorkspaceNode],
      _ expandedNodeIDs: Set<WorkspaceNode.ID>,
      _ includeForeignFiles: Bool
    ) -> [FlattenedWorkspaceRow]

  /// The latest published snapshot. Starts empty; the first `publish` fills it
  /// asynchronously.
  private(set) var rows: [FlattenedWorkspaceRow] = []

  private let flatten: Flatten
  private var pendingRequest: Request?
  private var isPumping = false

  init(
    flatten: @escaping Flatten = { roots, expandedNodeIDs, includeForeignFiles in
      flattenWorkspaceTree(
        roots,
        expandedNodeIDs: expandedNodeIDs,
        includeForeignFiles: includeForeignFiles
      )
    }
  ) {
    self.flatten = flatten
  }

  /// Records the latest inputs and schedules an off-main flatten. Cheap by
  /// contract — a store-and-trigger, never a walk — so it is safe to call from
  /// every view-invalidation hook.
  func publish(
    tree: [WorkspaceNode],
    expandedNodeIDs: Set<WorkspaceNode.ID>,
    includeForeignFiles: Bool
  ) {
    pendingRequest = Request(
      tree: tree,
      expandedNodeIDs: expandedNodeIDs,
      includeForeignFiles: includeForeignFiles
    )
    guard !isPumping else { return }
    isPumping = true
    let flatten = self.flatten
    Task.detached(priority: .userInitiated) { [weak self] in
      while let self, let request = await self.takePendingRequest() {
        let flattened = flatten(
          request.tree,
          request.expandedNodeIDs,
          request.includeForeignFiles
        )
        await self.apply(flattened)
      }
    }
  }

  /// Latest-wins coalescing and pump shutdown are one atomic main-actor step:
  /// either a newer request is taken, or the pump is marked stopped and the
  /// next `publish` starts a fresh pump. No request can be lost in between.
  private func takePendingRequest() -> Request? {
    if let request = pendingRequest {
      pendingRequest = nil
      return request
    }
    isPumping = false
    return nil
  }

  private func apply(_ flattened: [FlattenedWorkspaceRow]) {
    rows = flattened
  }

  private struct Request: Sendable {
    let tree: [WorkspaceNode]
    let expandedNodeIDs: Set<WorkspaceNode.ID>
    let includeForeignFiles: Bool
  }
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
  expandedNodeIDs: Set<WorkspaceNode.ID>,
  includeForeignFiles: Bool = false
) -> [FlattenedWorkspaceRow] {
  var rows: [FlattenedWorkspaceRow] = []
  appendFlattenedWorkspaceRows(
    roots,
    depth: 0,
    expandedNodeIDs: expandedNodeIDs,
    includeForeignFiles: includeForeignFiles,
    into: &rows
  )
  return rows
}

private func appendFlattenedWorkspaceRows(
  _ nodes: [WorkspaceNode],
  depth: Int,
  expandedNodeIDs: Set<WorkspaceNode.ID>,
  includeForeignFiles: Bool,
  into rows: inout [FlattenedWorkspaceRow]
) {
  for node in nodes {
    // Foreign (non-markdown) nodes are always emitted by the scanner so scan
    // results stay cache-coherent regardless of the toggle; visibility is
    // filtered here instead, which is what makes the toggle instant (no rescan).
    if node.kind == .foreignFile, !includeForeignFiles {
      continue
    }

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
      includeForeignFiles: includeForeignFiles,
      into: &rows
    )
  }
}
