import CodescribeBridge
import Foundation

/// Selection is sampled only when a conversation is created, never on submit.
@MainActor
enum AskContextSelection {
  static func current(in appState: AppState) -> AskContext {
    if appState.documentHasEditableBuffer { return document(in: appState) }
    return AskContext(roots: Set(appState.workspaceRoots.map(\.url)))
  }

  static func document(in appState: AppState) -> AskContext {
    guard appState.documentHasEditableBuffer else { return .empty }
    if let ref = appState.documentSession.document { return AskContext(files: [ref]) }
    return AskContext(draftID: appState.documentSession.askThreadID)
  }

  /// Use the original mounted roots, even when another tab owns the surface.
  /// A closed workspace has no live bookmark authority and is reported explicitly.
  static func documents(
    for context: AskContext, controller: AppController,
    registry: DocumentWindowRegistry = .shared
  ) -> [DocumentRef]? {
    var mountedRoots: Set<URL> = []
    var documents: [DocumentRef] = []
    var seen: Set<URL> = []
    for owner in [controller] + registry.liveDocumentControllers() {
      let snapshot = owner.askWorkspaceSnapshot
      mountedRoots.formUnion(snapshot.roots)
      for document in snapshot.documents where seen.insert(document.url).inserted {
        documents.append(document)
      }
    }
    return Set(context.roots.map(\.path)).isSubset(of: Set(mountedRoots.map(\.path)))
      ? documents : nil
  }

  /// The original mounted workspace supplies root-context opens after the
  /// shared Ask surface moves to a controller with a different workspace.
  static func openDocument(
    _ ref: DocumentRef, context: AskContext, controller: AppController,
    registry: DocumentWindowRegistry = .shared, isActive: @escaping @Sendable () -> Bool
  ) async throws -> DocumentToolHost {
    guard isActive() else { throw CsError.Agent(msg: "The Ask request was stopped.") }
    let path = ref.url.standardizedFileURL.resolvingSymlinksInPath().path
    if context.files.contains(where: { $0.url.path == path }) {
      return try await controller.openAgentDocument(ref, context: context, isActive: isActive)
    }
    let roots = context.roots.filter { root in
      root.resolvingSymlinksInPath().path == root.path
        && WorkspaceScanner.contains(URL(fileURLWithPath: path), in: root)
    }
    guard !roots.isEmpty else {
      throw CsError.Agent(msg: "The file is outside this thread's context.")
    }
    let selectedRoots = Set(roots.map(\.path))
    for owner in [controller] + registry.liveDocumentControllers() {
      let snapshot = owner.askWorkspaceSnapshot
      guard !selectedRoots.isDisjoint(with: Set(snapshot.roots.map(\.path))),
        let mounted = snapshot.documents.first(where: {
          !$0.isAdHoc && $0.url.standardizedFileURL.resolvingSymlinksInPath().path == path
        })
      else { continue }
      return try await owner.openAgentDocument(mounted, context: context, isActive: isActive)
    }
    throw CsError.Agent(
      msg: "The workspace for this thread is closed. Open it again or start a new thread.")
  }

  /// Resolve the owner of the original live buffer across native tab changes.
  /// DocumentToolHost's generation checks still fence edits after that buffer closes.
  static func initialDocument(
    for context: AskContext, controller: AppController,
    registry: DocumentWindowRegistry = .shared
  ) -> (path: String, host: DocumentToolHost)? {
    for owner in [controller] + registry.liveDocumentControllers() {
      if let seed = owner.makeInitialAskDocumentHost(for: context) { return seed }
    }
    return nil
  }
}
