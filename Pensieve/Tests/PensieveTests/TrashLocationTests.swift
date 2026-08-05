import Foundation
import XCTest

@testable import Pensieve

/// The real `TrashLocation` predicate, against the real filesystem.
///
/// Every other Trash test injects a simulated Trash so the suite stays out of
/// `~/.Trash`. That leaves exactly one thing unproven — whether the predicate
/// recognizes an ACTUAL trashed file — so this suite does one genuine round trip
/// with a uniquely named scratch file and puts the Trash back the way it found
/// it.
final class TrashLocationTests: XCTestCase {
  private var scratch: URL!

  override func setUp() async throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("TrashLocationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  /// The load-bearing case: `FileManager.trashItem` puts a file where the system
  /// puts trashed files, and the predicate must say so about the resulting URL.
  func testAGenuinelyTrashedFileIsRecognized() throws {
    let name = "pensieve-trashlocation-\(UUID().uuidString).md"
    let fileURL = scratch.appendingPathComponent(name)
    try "scratch".write(to: fileURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(
      TrashLocation.contains(fileURL),
      "a live scratch file must not read as trashed")

    var resultingURL: NSURL?
    try FileManager.default.trashItem(at: fileURL, resultingItemURL: &resultingURL)
    let trashedURL = try XCTUnwrap(resultingURL as URL?).standardizedFileURL
    // Leave the operator's Trash exactly as we found it. Guarded on our own
    // unique prefix so a wrong `resultingItemURL` could never widen this.
    addTeardownBlock {
      if trashedURL.lastPathComponent.hasPrefix("pensieve-trashlocation-") {
        try? FileManager.default.removeItem(at: trashedURL)
      }
    }

    XCTAssertTrue(
      TrashLocation.contains(trashedURL),
      "the predicate must recognize the location the system actually trashes into")
  }

  /// The predicate has to answer for a working-set entry whose file is already
  /// gone, which is past the point where the relationship query can look at an
  /// item — that is what the path-ancestry fallback is for.
  func testAPathInsideTheTrashIsRecognizedWithoutAnItemToInspect() throws {
    let trashDirectory = try XCTUnwrap(
      FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first)

    XCTAssertTrue(TrashLocation.contains(trashDirectory))
    XCTAssertTrue(
      TrashLocation.contains(
        trashDirectory.appendingPathComponent("never-existed-\(UUID().uuidString).md")),
      "a nonexistent path inside the Trash still describes a thrown-away document")
  }

  /// The same question one volume over. An item trashed on an external disk never
  /// leaves it — it lands in `<volume>/.Trashes/<uid>` — and once that item is
  /// gone the system can no longer name that Trash for us: both the relationship
  /// query and `url(for:.trashDirectory, appropriateFor:)` need something to look
  /// at. So a working-set entry that outlived a file on an external volume used to
  /// answer NO, and the home Trash was the only Trash a gone item could be in.
  func testAGonePathInsideAVolumeTrashIsRecognized() throws {
    let volume = URL(fileURLWithPath: "/Volumes/PensieveNoSuchVolume-\(UUID().uuidString)")
    let trashed = volume
      .appendingPathComponent(".Trashes", isDirectory: true)
      .appendingPathComponent(String(getuid()), isDirectory: true)
      .appendingPathComponent("gone.md")

    XCTAssertTrue(
      TrashLocation.contains(trashed),
      "a bookmark that followed its file into another volume's Trash still describes a "
        + "thrown-away document, even after the item itself is gone")

    XCTAssertFalse(
      TrashLocation.contains(volume.appendingPathComponent("Notes/gone.md")),
      "control: an ordinary path on the same absent volume is not trashed")
    XCTAssertFalse(
      TrashLocation.contains(
        volume.appendingPathComponent("Trashes/\(getuid())/gone.md")),
      "control: the match is the system's own layout, not any directory called Trashes")
  }

  /// End to end against the REAL Trash, closing the gap between the simulated
  /// Trash the rest of the suite injects and what actually happens on this
  /// machine: a genuinely trashed file, a genuine security-scoped bookmark, and
  /// the shipped predicate deciding.
  ///
  /// The middle assertion is the reason the defect existed at all — the bookmark
  /// does not break when the file is thrown away, it follows it into the Trash and
  /// keeps resolving.
  @MainActor
  func testTheShippedRestoreGuardDropsAGenuinelyTrashedFile() throws {
    let name = "pensieve-trashlocation-\(UUID().uuidString).md"
    let fileURL = scratch.appendingPathComponent(name).standardizedFileURL
    try "restore me".write(to: fileURL, atomically: true, encoding: .utf8)

    let defaults = makeEphemeralDefaults(prefix: "PensieveRealTrashRestoreTests")
    // No injected predicate: this store uses the shipped `TrashLocation`.
    try BookmarkStore(defaults: defaults).persistFile(url: fileURL, into: AppState())
    XCTAssertEqual(
      BookmarkStore(defaults: defaults).restoreWorkspace(into: AppState()).fileURLs
        .map(\.standardizedFileURL),
      [fileURL],
      "precondition: the working set restores this file while it is live")

    var resultingURL: NSURL?
    try FileManager.default.trashItem(at: fileURL, resultingItemURL: &resultingURL)
    let trashedURL = try XCTUnwrap(resultingURL as URL?).standardizedFileURL
    addTeardownBlock {
      if trashedURL.lastPathComponent.hasPrefix("pensieve-trashlocation-") {
        try? FileManager.default.removeItem(at: trashedURL)
      }
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: trashedURL.path),
      "the file is not gone — it is in the Trash, still readable, which is the whole problem")

    XCTAssertTrue(
      BookmarkStore(defaults: defaults).restoreWorkspace(into: AppState()).fileURLs.isEmpty,
      "restore must drop a file the user threw away, not resurrect it as an open document")
  }

  /// Negative controls: ordinary places must not read as Trash, including a
  /// directory that merely LOOKS like one — the case a path-component match
  /// (`.Trash` anywhere in the path) gets wrong, and the reason this predicate
  /// asks the filesystem instead.
  func testOrdinaryLocationsAreNotTrash() throws {
    XCTAssertFalse(TrashLocation.contains(scratch))
    XCTAssertFalse(TrashLocation.contains(FileManager.default.temporaryDirectory))
    XCTAssertFalse(
      TrashLocation.contains(FileManager.default.homeDirectoryForCurrentUser))

    let lookalike = scratch.appendingPathComponent(".Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
    XCTAssertFalse(
      TrashLocation.contains(lookalike.appendingPathComponent("note.md")),
      "a directory named .Trash somewhere else is not a Trash the system knows about")
  }
}
