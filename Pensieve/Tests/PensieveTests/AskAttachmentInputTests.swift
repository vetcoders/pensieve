import AppKit
import XCTest

@testable import Pensieve

/// Attachment input routing: paste and drop classification happens before the
/// store, an attachable payload is claimed (so no image bytes, file paths or
/// marker text ever reach the draft or the document), plain text paste falls
/// through untouched, and unsupported files fail with an explicit error.
@MainActor
final class AskAttachmentInputTests: XCTestCase {
  private var scratch: URL!

  override func setUp() {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ask-attachment-input-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: scratch)
    scratch = nil
  }

  private func makeStore() -> AskAttachmentStore {
    AskAttachmentStore(
      stagingDirectory: scratch.appendingPathComponent("staging", isDirectory: true))
  }

  /// A private pasteboard: the general one is never touched by these tests.
  private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ask-input-test-\(UUID().uuidString)"))
  }

  private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

  private func writeFile(_ name: String, bytes: Int) throws -> URL {
    let url = scratch.appendingPathComponent(name)
    try Data(repeating: 0x89, count: bytes).write(to: url)
    return url
  }

  private func waitUntil(
    timeout: TimeInterval = 2.0, predicate: @escaping () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
  }

  func testPasteboardClassification() throws {
    let files = makePasteboard()
    let image = try writeFile("figure.png", bytes: 32)
    files.writeObjects([image as NSURL])
    guard case .files(let urls) = AskAttachmentInput.route(pasteboard: files) else {
      return XCTFail("a copied file must classify as files")
    }
    XCTAssertEqual(urls, [image])

    let data = makePasteboard()
    data.setData(pngBytes, forType: .png)
    guard case .imageData(let payload, let ext) = AskAttachmentInput.route(pasteboard: data)
    else {
      return XCTFail("raw image data must classify as imageData")
    }
    XCTAssertEqual(payload, pngBytes)
    XCTAssertEqual(ext, "png")

    let text = makePasteboard()
    text.setString("plain question", forType: .string)
    XCTAssertEqual(
      AskAttachmentInput.route(pasteboard: text), .notAnAttachment,
      "plain text stays on the native paste path")

    // A copied image FILE arrives with both a URL and image data; the URL
    // wins so the file keeps its identity instead of a staged re-encode.
    let both = makePasteboard()
    both.writeObjects([image as NSURL])
    both.setData(pngBytes, forType: .png)
    guard case .files = AskAttachmentInput.route(pasteboard: both) else {
      return XCTFail("file identity wins over raw image data")
    }
  }

  /// An image paste is claimed by the attachment lane: a Pensieve-owned
  /// staged chip appears and the handler reports the paste consumed, which is
  /// what keeps binary or marker text out of the draft editor.
  func testImagePasteStagesChipAndClaimsPaste() async throws {
    let store = makeStore()
    let pasteboard = makePasteboard()
    pasteboard.setData(pngBytes, forType: .png)
    var errors: [String] = []

    let claimed = AskAttachmentInput.handlePaste(pasteboard, store: store) { message in
      errors.append(message)
    }
    XCTAssertTrue(claimed, "an image paste is claimed, never inserted as text")

    let staged = await waitUntil { store.attachments.count == 1 }
    XCTAssertTrue(staged, "the staged chip appears")
    XCTAssertTrue(errors.isEmpty)
    let attachment = try XCTUnwrap(store.attachments.first)
    XCTAssertEqual(attachment.origin, .staged)
    XCTAssertEqual(
      attachment.url.deletingLastPathComponent().standardizedFileURL,
      store.stagingDirectory.standardizedFileURL,
      "clipboard images live in Pensieve-owned staging")
  }

  /// Plain text is not an attachment: the handler declines, so the native
  /// text view inserts the clipboard string unchanged.
  func testTextPasteIsNotClaimed() {
    let store = makeStore()
    let pasteboard = makePasteboard()
    pasteboard.setString("just words", forType: .string)

    let claimed = AskAttachmentInput.handlePaste(pasteboard, store: store) { _ in
      XCTFail("plain text must not produce an attachment error")
    }
    XCTAssertFalse(claimed, "text paste falls through to the editor")
    XCTAssertTrue(store.attachments.isEmpty)
  }

  /// A file this wave cannot send produces the store's explicit error and
  /// never becomes a chip.
  func testUnsupportedFilePasteFailsHonestly() async throws {
    let store = makeStore()
    let document = try writeFile("notes.txt", bytes: 16)
    let pasteboard = makePasteboard()
    pasteboard.writeObjects([document as NSURL])
    var errors: [String] = []

    let claimed = AskAttachmentInput.handlePaste(pasteboard, store: store) { message in
      errors.append(message)
    }
    XCTAssertTrue(claimed, "the paste is claimed so the path never enters the draft")

    let failed = await waitUntil { !errors.isEmpty }
    XCTAssertTrue(failed, "the unsupported file reports an error")
    XCTAssertTrue(errors.first?.contains("notes.txt") == true, errors.first ?? "")
    XCTAssertTrue(errors.first?.contains("images only") == true, errors.first ?? "")
    XCTAssertTrue(store.attachments.isEmpty, "a rejected file never shows a sent chip")
  }

  /// The drop/picker path takes several files at once: supported images
  /// become external (never copied, never deleted) chips, unsupported files
  /// error out individually.
  func testAttachUrlsMixesValidImagesAndHonestRejections() async throws {
    let store = makeStore()
    let figure = try writeFile("figure.png", bytes: 32)
    let paper = try writeFile("paper.pdf", bytes: 32)
    var errors: [String] = []

    AskAttachmentInput.attach(urls: [figure, paper], store: store) { message in
      errors.append(message)
    }

    let settled = await waitUntil { store.attachments.count == 1 && errors.count == 1 }
    XCTAssertTrue(settled, "one chip, one error; got \(store.attachments.count) chips")
    XCTAssertEqual(store.attachments.first?.url.standardizedFileURL, figure.standardizedFileURL)
    XCTAssertEqual(store.attachments.first?.origin, .external)
    XCTAssertTrue(errors.first?.contains("paper.pdf") == true, errors.first ?? "")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: figure.path),
      "external files are referenced, never moved")
  }
}
