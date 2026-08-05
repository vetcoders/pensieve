import Foundation

/// Whether a URL currently lives inside a Trash directory.
///
/// A security-scoped bookmark tracks the FILE, not the path it was made from:
/// moving a document to the Trash leaves the bookmark perfectly resolvable, and
/// it resolves to the item's new home under a Trash folder. Everything that
/// decided "this is still an open document" by resolving a bookmark and checking
/// existence therefore said YES about files the user had thrown away. Trash
/// membership is the missing question.
///
/// It is asked of the FILESYSTEM rather than matched against a hardcoded
/// `~/.Trash`, and rather than against the shape of a path: every volume keeps
/// its own Trash (`/Volumes/<name>/.Trashes/<uid>`), an item trashed on an
/// external disk never leaves it, and a sandboxed build sees a container-relative
/// one. Path-component matching also answers YES about any directory a user
/// happened to name `.Trash`, which is not a Trash the system knows about.
///
/// The single exception is `contains`'s last resort for an item that is already
/// GONE, where there is nothing left to ask the filesystem about: see the
/// per-volume `.Trashes/<uid>` note there.
enum TrashLocation {

  /// True when `url` is a Trash directory or lives anywhere inside one.
  ///
  /// `getRelationship` is the authoritative check: it resolves the Trash
  /// APPROPRIATE FOR the item's own volume and answers about that one. It needs
  /// an item it can look at, so a path fallback covers the two cases it cannot
  /// serve — a URL whose target is already gone (a working-set entry outliving
  /// its file) and any error the relationship query reports.
  ///
  /// What the fallback can promise about a GONE item is narrower than what the
  /// relationship query promises about a live one, and the difference is worth
  /// stating: both `getRelationship` and `url(for:.trashDirectory,
  /// appropriateFor:)` need an existing item, so for a path whose target is
  /// gone only the HOME Trash can be named by the system. Every other volume is
  /// covered by recognizing the layout the system itself uses there —
  /// `<volume>/.Trashes/<uid>` — which is the one shape a `.Trash` component
  /// match gets wrong often enough to be worth refusing (any directory can be
  /// named `.Trash`; `.Trashes/501` is a system-made pair). A gone item under
  /// ANOTHER user's `.Trashes/<other uid>` is deliberately not claimed: this app
  /// only ever holds bookmarks to its own user's files.
  nonisolated static func contains(_ url: URL) -> Bool {
    let standardized = url.standardizedFileURL
    var relationship: FileManager.URLRelationship = .other
    let relationshipIsKnown =
      (try? FileManager.default.getRelationship(
        &relationship,
        of: .trashDirectory,
        in: .userDomainMask,
        toItemAt: standardized
      )) != nil
    if relationshipIsKnown, relationship == .contains || relationship == .same {
      return true
    }

    if trashDirectories(appropriateFor: standardized).contains(where: { trash in
      isSameOrDescendant(standardized.path, of: trash.standardizedFileURL.path)
    }) {
      return true
    }

    return isInsideAVolumeTrash(standardized)
  }

  /// Whether the path runs through this user's per-volume Trash,
  /// `<volume>/.Trashes/<uid>`.
  ///
  /// Deliberately a path shape, and deliberately only THIS shape: it is the
  /// layout macOS creates on a non-home volume, and it is the only answer left
  /// once the item is gone — the system cannot name a volume's Trash for a path
  /// it can no longer look at.
  private nonisolated static func isInsideAVolumeTrash(_ url: URL) -> Bool {
    let components = url.pathComponents
    let ownTrashDirectory = String(getuid())
    for (index, component) in components.enumerated() where component == ".Trashes" {
      let uidIndex = index + 1
      guard uidIndex < components.count, components[uidIndex] == ownTrashDirectory else {
        continue
      }
      return true
    }
    return false
  }

  /// Trash directories worth comparing a path against: the home Trash plus, when
  /// the system can name it, the Trash belonging to the item's own volume.
  /// `create: false` means an external disk that has never had anything trashed
  /// on it simply contributes nothing instead of being given a Trash folder by
  /// this query.
  private nonisolated static func trashDirectories(appropriateFor url: URL) -> [URL] {
    var directories = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)
    if let volumeTrash = try? FileManager.default.url(
      for: .trashDirectory,
      in: .userDomainMask,
      appropriateFor: url,
      create: false
    ) {
      directories.append(volumeTrash)
    }
    return directories
  }

  private nonisolated static func isSameOrDescendant(
    _ path: String,
    of ancestorPath: String
  ) -> Bool {
    path == ancestorPath || path.hasPrefix(ancestorPath + "/")
  }
}
