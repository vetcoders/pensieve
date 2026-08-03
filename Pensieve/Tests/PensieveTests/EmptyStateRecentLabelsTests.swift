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

  /// ONE parent is not always enough. Two projects each holding a `README.md`
  /// under a folder of the same name — `/a/project/README.md` and
  /// `/b/project/README.md` — both rendered "README — project", so the rows were
  /// as indistinguishable as the bare basenames they replaced. The suffix grows
  /// until the rows actually differ.
  func testIdenticalParentsGrowTheSuffixUntilTheRowsDiffer() {
    XCTAssertEqual(
      labels(["/a/project/README.md", "/b/project/README.md"]),
      ["README — a/project", "README — b/project"])
  }

  /// CONTROL: the suffix is SHORTEST, and it is chosen per colliding name. A
  /// group that separates on one component keeps one component even while
  /// another group in the same slice needs two — growing everything to the
  /// longest would make the whole list pay for one ambiguity.
  func testSuffixLengthIsChosenPerNameNotForTheWholeSlice() {
    XCTAssertEqual(
      labels([
        "/a/project/README.md", "/b/project/README.md",
        "/one/NOTES.md", "/two/NOTES.md",
      ]),
      ["README — a/project", "README — b/project", "NOTES — one", "NOTES — two"])
  }

  /// CONTROL: paths that agree ALL THE WAY UP have no suffix that separates
  /// them, so the search stops as soon as growing stops helping and keeps the
  /// SHORT label. Terminating, and no long path grown for a difference that does
  /// not exist.
  func testPathsIdenticalToTheRootDegradeInsteadOfLooping() {
    XCTAssertEqual(
      labels(["/a/project/README.md", "/a/project/README.md"]),
      ["README — project", "README — project"])
  }

  /// CONTROL: "stop when growing stops helping" is not "stop at the first
  /// twins". Two of these three are the same path and can never separate, but the
  /// third can — so the suffix still grows to the length that separates what is
  /// separable.
  func testGrowthContinuesWhileItSeparatesAnyoneAtAll() {
    XCTAssertEqual(
      labels(["/a/project/README.md", "/a/project/README.md", "/b/project/README.md"]),
      ["README — a/project", "README — a/project", "README — b/project"])
  }

  /// A PLATEAU IS NOT THE END. `/a/shared/project/README.md` and
  /// `/b/shared/project/README.md` stay identical at one component AND at two —
  /// the difference is at three. The first growth loop read the flat step as
  /// proof that no ancestor could ever separate them and stopped there, so both
  /// rows rendered "README — project" again. Distinctness can arrive later, so
  /// the search runs to the deepest parent and keeps the shortest depth that
  /// separated the most rows.
  func testSuffixGrowsPastAPlateauOfSharedParents() {
    XCTAssertEqual(
      labels(["/a/shared/project/README.md", "/b/shared/project/README.md"]),
      ["README — a/shared/project", "README — b/shared/project"])
  }

  /// CONTROL for the same scan: running to the deepest parent must not make the
  /// suffix longer than it needs to be. These separate at ONE component, and the
  /// deeper levels — which are also distinct — must not win over it.
  func testScanningDeeperStillReturnsTheShortestSeparatingSuffix() {
    XCTAssertEqual(
      labels(["/one/x/a/README.md", "/two/y/b/README.md"]),
      ["README — a", "README — b"])
  }

  /// CONTROL: a row whose path runs out before its rival's still separates on
  /// what it has — the shorter path IS the difference.
  func testAShorterPathSeparatesOnWhatItHas() {
    XCTAssertEqual(
      labels(["/project/README.md", "/deep/project/README.md"]),
      ["README — project", "README — deep/project"])
  }

  func testEmptySliceProducesNoLabels() {
    XCTAssertEqual(labels([]), [])
  }
}
