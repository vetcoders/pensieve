import Foundation

struct ScrollSyncPosition: Equatable, Sendable {
  let progress: Double

  init(progress: Double) {
    if progress.isFinite {
      self.progress = min(max(progress, 0), 1)
    } else {
      self.progress = 0
    }
  }
}

protocol ScrollSyncPreviewTarget: AnyObject {
  func applyScrollSyncPosition(_ position: ScrollSyncPosition)
}

final class ScrollSyncCoordinator {
  enum Side: Equatable {
    case editor
    case preview
  }

  var isEnabled = false {
    didSet {
      if !isEnabled {
        lockedProgrammaticSide = nil
      }
    }
  }

  private weak var previewTarget: ScrollSyncPreviewTarget?
  private var lockedProgrammaticSide: Side?
  private var lockGeneration: UInt64 = 0
  private let unlockScheduler: (@escaping () -> Void) -> Void

  init(unlockScheduler: @escaping (@escaping () -> Void) -> Void = { action in
    RunLoop.main.perform(action)
  }) {
    self.unlockScheduler = unlockScheduler
  }

  func attachPreviewTarget(_ target: ScrollSyncPreviewTarget) {
    previewTarget = target
  }

  func detachPreviewTarget(_ target: ScrollSyncPreviewTarget) {
    if previewTarget === target {
      previewTarget = nil
    }
  }

  func acceptsObservedScroll(from side: Side) -> Bool {
    isEnabled && lockedProgrammaticSide != side
  }

  func editorDidScroll(to position: ScrollSyncPosition) {
    guard acceptsObservedScroll(from: .editor), let previewTarget else { return }
    performProgrammaticScroll(target: .preview) {
      previewTarget.applyScrollSyncPosition(position)
    }
  }

  private func performProgrammaticScroll(target: Side, _ action: () -> Void) {
    lockGeneration &+= 1
    let generation = lockGeneration
    lockedProgrammaticSide = target

    action()

    unlockScheduler { [weak self] in
      guard let self else { return }
      guard self.lockGeneration == generation, self.lockedProgrammaticSide == target else {
        return
      }
      self.lockedProgrammaticSide = nil
    }
  }
}
