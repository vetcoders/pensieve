import Foundation

/// A Trash the test OWNS.
///
/// `BookmarkStore` asks `TrashLocation` — that is, the filesystem — whether a
/// URL lives in a Trash, and the filesystem is right to say no about a fixture
/// directory that is merely NAMED `.Trash` under `/tmp`: it is not a Trash the
/// system would ever put anything in. Suites that need a thrown-away file
/// therefore inject their own membership predicate instead of relying on the
/// shape of a path — which is also what keeps every one of them out of the
/// operator's real `~/.Trash`.
///
/// The real predicate is covered by `TrashLocationTests`, which does one genuine
/// round trip through `FileManager.trashItem` and puts the Trash back.
enum SimulatedTrash {

  /// A `BookmarkStore` trash-membership predicate that answers YES for
  /// `directory` and everything inside it, and NO for everywhere else.
  static func membership(at directory: URL) -> (URL) -> Bool {
    let trashPath = directory.standardizedFileURL.path
    return { url in
      let path = url.standardizedFileURL.path
      return path == trashPath || path.hasPrefix(trashPath + "/")
    }
  }
}
