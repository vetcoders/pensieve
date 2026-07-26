import Foundation

/// Whether a URL currently lives inside a Trash directory.
///
/// A security-scoped bookmark tracks the FILE, not the path it was made from:
/// moving a document to the Trash leaves the bookmark perfectly resolvable, and
/// it resolves to the item's new home under a Trash folder. Restoring the
/// working set from bookmarks therefore resurrected documents the user had
/// thrown away — they existed, they were readable, and nothing told them apart
/// from a live file. Trash membership is the missing question.
///
/// It is asked of the filesystem rather than matched against a hardcoded
/// `~/.Trash`: every volume keeps its own Trash (`/Volumes/<name>/.Trashes/<uid>`)
/// and an item trashed on an external disk never leaves it, while a sandboxed
/// build sees a container-relative one.
enum TrashLocation {

  /// True when `url` is a Trash directory or lives anywhere inside one.
  ///
  /// `getRelationship` is the authoritative check: it resolves the Trash
  /// APPROPRIATE FOR the item's own volume and answers about that one. It needs
  /// an item it can look at, so a path-ancestry fallback covers the two cases it
  /// cannot serve — a URL whose target is already gone (a working-set entry
  /// outliving its file) and any error the relationship query reports.
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

    return trashDirectories(appropriateFor: standardized).contains { trash in
      isSameOrDescendant(standardized.path, of: trash.standardizedFileURL.path)
    }
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
