import Foundation
import XCTest

@testable import Pensieve

/// `BookmarkStore.identityPath` folds the `/private` prefix so that a live
/// working-set row and the bookmark blob of its trashed self still correlate.
///
/// The fold is only sound for the directories macOS publishes under two
/// spellings: `/var`, `/tmp` and `/etc` are symlinks into `/private`, so both
/// spellings name one file. Everything else under `/private` is an independent
/// location — folding it would hand two unrelated documents the same identity
/// key, and with it the same security-scoped grant and the same Trash
/// correlation.
///
/// Paths here are deliberately chosen NOT to exist: `standardizedFileURL`
/// rewrites `/private` on its own while the target still exists, and this is
/// exactly the missing-file case the key was built for.
@MainActor
final class BookmarkIdentityPathTests: XCTestCase {
  private func identity(_ path: String) -> String {
    BookmarkStore.identityPath(URL(fileURLWithPath: path))
  }

  func testTheThreeMacOSAliasesFoldOntoTheirShortSpelling() {
    let stamp = UUID().uuidString

    XCTAssertEqual(
      identity("/private/var/folders/\(stamp)/note.md"),
      identity("/var/folders/\(stamp)/note.md"),
      "/var is a symlink into /private, so both spellings are one document")
    XCTAssertEqual(
      identity("/private/tmp/\(stamp)/note.md"),
      identity("/tmp/\(stamp)/note.md"),
      "/tmp is a symlink into /private, so both spellings are one document")
    XCTAssertEqual(
      identity("/private/etc/\(stamp)/note.md"),
      identity("/etc/\(stamp)/note.md"),
      "/etc is a symlink into /private, so both spellings are one document")

    XCTAssertEqual(
      identity("/private/var/folders/\(stamp)/note.md"),
      "/var/folders/\(stamp)/note.md",
      "the folded key must be the short spelling, the one a live row carries")
  }

  /// THE PIN this narrowing exists for. `/private/<anything else>` is a real
  /// directory of its own — nothing on macOS publishes it a second time at the
  /// root. Dropping the prefix there fuses it with an unrelated top-level path.
  func testANonAliasPrivatePathKeepsItsOwnIdentity() {
    let stamp = UUID().uuidString

    XCTAssertNotEqual(
      identity("/private/\(stamp)/note.md"),
      identity("/\(stamp)/note.md"),
      "an arbitrary /private/… path is not an alias; folding it collides two documents")
    XCTAssertEqual(
      identity("/private/\(stamp)/note.md"),
      "/private/\(stamp)/note.md",
      "a non-alias /private path must be returned untouched")
  }

  /// A directory whose name merely STARTS with an alias name is not that alias.
  /// The trailing slash in the prefix list is what keeps them apart.
  func testAPathThatOnlyLooksLikeAnAliasIsNotFolded() {
    let stamp = UUID().uuidString

    XCTAssertEqual(
      identity("/private/variants/\(stamp)/note.md"),
      "/private/variants/\(stamp)/note.md",
      "/private/variants is not /private/var")
    XCTAssertEqual(
      identity("/private/tmpfiles/\(stamp)/note.md"),
      "/private/tmpfiles/\(stamp)/note.md",
      "/private/tmpfiles is not /private/tmp")
  }

  /// Paths outside `/private` are never rewritten, and no symlink resolution of
  /// this function's own is implied — it is an identity key, not a canonicalizer.
  func testPathsOutsidePrivateAreReturnedUnchanged() {
    let stamp = UUID().uuidString

    XCTAssertEqual(identity("/Users/\(stamp)/note.md"), "/Users/\(stamp)/note.md")
    XCTAssertEqual(identity("/var/folders/\(stamp)/note.md"), "/var/folders/\(stamp)/note.md")
  }
}
