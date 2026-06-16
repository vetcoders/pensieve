import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class EditorViewportSyncTests: XCTestCase {
  func testEditorViewportPostIsDeferredAndDeduped() async {
    let surface = makeSurface(text: "alpha\n\nbeta")
    let blocks = LockedIntLog()
    let observer = NotificationCenter.default.addObserver(
      forName: .vcEditorViewportChanged,
      object: nil,
      queue: .main
    ) { note in
      if let block = note.userInfo?["block"] as? Int {
        blocks.append(block)
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    surface.postEditorViewportIfNeeded()

    XCTAssertEqual(blocks.values, [], "viewport publishing must not query layout synchronously")

    await waitUntil { blocks.values.count == 1 }

    XCTAssertEqual(blocks.values, [0])

    surface.postEditorViewportIfNeeded()
    try? await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(blocks.values, [0], "unchanged editor viewport blocks must not repost")
  }

  func testPreviewViewportScrollIsDeferredAndSuppressesEcho() async {
    let surface = makeSurface(text: "alpha\n\nbeta\n\ngamma")

    NotificationCenter.default.post(
      name: .vcPreviewViewportChanged,
      object: nil,
      userInfo: ["block": 1]
    )

    XCTAssertNil(
      surface.lastPreviewAppliedBlock,
      "preview-driven editor scrolling must not run inside the notification handler")

    await waitUntil { surface.lastPreviewAppliedBlock == 1 }

    XCTAssertEqual(surface.lastPreviewAppliedBlock, 1)
    XCTAssertEqual(surface.lastPostedEditorBlock, 1, "preview-driven scroll must not echo back")
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 500_000_000,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
    while Date() < deadline {
      if condition() { return }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Timed out waiting for viewport sync condition")
  }
}

@MainActor
private func makeSurface(text: String) -> MarkdownEditorSurface {
  MarkdownEditorSurface(
    text: text,
    fontSize: 14,
    syntaxHighlightingEnabled: true,
    tableTidyOnPaste: true,
    asciiSafeTables: false,
    aiAutocompleteEnabled: false
  )
}

private final class LockedIntLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Int] = []

  func append(_ value: Int) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
