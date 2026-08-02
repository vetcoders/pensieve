import Foundation
import XCTest

@testable import Pensieve

/// Recent documents are listed by basename, so two `README.md` from different
/// folders were two identical `README` buttons. The full path lived only in a
/// hover tooltip — nothing a keyboard or VoiceOver user ever reaches — so the
/// name itself has to carry the difference.
final class EmptyStateRecentLabelsTests: XCTestCase {
  private func labels(_ paths: [String]) -> [String] {
    EmptyStateRecentLabels.labels(for: paths.map { URL(fileURLWithPath: $0) })
  }

  /// The reported case: only the colliding rows take a folder, and the row that
  /// was already unambiguous is left exactly as it was.
  func testCollidingNamesTakeTheirFolderAndUniqueOnesDoNot() {
    XCTAssertEqual(
      labels(["/a/README.md", "/b/README.md", "/c/NOTES.md"]),
      ["README — a", "README — b", "NOTES"])
  }

  /// CONTROL: a slice with no collision at all is untouched. Without this leg the
  /// fix could suffix every row and make the ordinary case noisier for nothing.
  func testAllDistinctNamesAreLeftBare() {
    XCTAssertEqual(
      labels(["/a/README.md", "/b/CHANGELOG.md", "/c/NOTES.md"]),
      ["README", "CHANGELOG", "NOTES"])
  }

  /// Uniqueness is judged over the whole visible slice, not pairwise: three of a
  /// name all take a folder, and a fourth distinct name still does not.
  func testEveryMemberOfACollisionIsDisambiguated() {
    XCTAssertEqual(
      labels(["/one/index.md", "/two/index.md", "/three/index.md", "/four/other.md"]),
      ["index — one", "index — two", "index — three", "other"])
  }

  /// A file at a volume root has no folder name to add; it keeps the bare name
  /// rather than growing a trailing "/".
  func testRootLevelFileKeepsItsBareName() {
    XCTAssertEqual(
      labels(["/README.md", "/docs/README.md"]),
      ["README", "README — docs"])
  }

  /// The extension is not part of the name, and it is not what disambiguates
  /// either: the collision is between BASENAMES, exactly as the list draws them.
  func testCollisionIsMeasuredOnTheNameTheListActuallyShows() {
    XCTAssertEqual(
      labels(["/a/notes.md", "/b/notes.markdown"]),
      ["notes — a", "notes — b"])
  }

  func testEmptySliceProducesNoLabels() {
    XCTAssertEqual(labels([]), [])
  }
}
