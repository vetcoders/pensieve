import AppKit
import XCTest

@testable import Pensieve

/// W2-01: one wrap-lines preference, default ON, drives editor container and
/// preview `pre`/`code` without reading production `UserDefaults`.
final class WrapPreferenceTests: XCTestCase {

  @MainActor
  func testWrapLinesDefaultsOnWithoutReadingProductionDefaults() {
    let settings = WrapPreference(
      defaults: makeEphemeralDefaults(prefix: "PensieveWrapPreferenceDefaultTests"))

    XCTAssertTrue(settings.wrapLines)
    XCTAssertTrue(WrapPreference.wrapLinesDefault)
    XCTAssertEqual(WrapPreference.commandTitle, "Wrap lines")
  }

  @MainActor
  func testChosenStateSurvivesRelaunchOnTheSameSuite() {
    let defaults = makeEphemeralDefaults(prefix: "PensieveWrapPreferencePersistenceTests")

    WrapPreference(defaults: defaults).wrapLines = false
    XCTAssertFalse(WrapPreference(defaults: defaults).wrapLines)

    WrapPreference(defaults: defaults).wrapLines = true
    XCTAssertTrue(WrapPreference(defaults: defaults).wrapLines)
  }

  func testTextContainerWrapsWhenOnAndGrowsHorizontallyWhenOff() {
    let wrapped = WrapPreference.textContainerConfiguration(wrapLines: true)
    XCTAssertTrue(wrapped.widthTracksTextView)
    XCTAssertFalse(wrapped.isHorizontallyResizable)
    XCTAssertTrue(wrapped.autoresizesWidth)
    XCTAssertFalse(wrapped.hasHorizontalScroller)

    let unwrapped = WrapPreference.textContainerConfiguration(wrapLines: false)
    XCTAssertFalse(unwrapped.widthTracksTextView)
    XCTAssertTrue(unwrapped.isHorizontallyResizable)
    XCTAssertFalse(unwrapped.autoresizesWidth)
    XCTAssertTrue(unwrapped.hasHorizontalScroller)
  }

  @MainActor
  func testEditorSurfaceAppliesInjectedWrapConfigurationWithoutAWindow() {
    let surface = MarkdownEditorSurface(text: "a long line that would wrap", fontSize: 14)

    surface.applyWrapPreference(true)
    XCTAssertTrue(surface.textContainer.widthTracksTextView)
    XCTAssertFalse(surface.textView.isHorizontallyResizable)
    XCTAssertTrue(surface.textView.autoresizingMask.contains(.width))
    XCTAssertFalse(surface.scrollView.hasHorizontalScroller)

    surface.applyWrapPreference(false)
    XCTAssertFalse(surface.textContainer.widthTracksTextView)
    XCTAssertTrue(surface.textView.isHorizontallyResizable)
    XCTAssertFalse(surface.textView.autoresizingMask.contains(.width))
    XCTAssertTrue(surface.scrollView.hasHorizontalScroller)
    XCTAssertEqual(surface.textContainer.size.width, CGFloat.greatestFiniteMagnitude)
  }

  @MainActor
  func testLongLineActuallyUnwrapsAndWrapsAgain() {
    let text = String(repeating: "abcdefghij ", count: 100)
    let surface = MarkdownEditorSurface(
      text: text, fontSize: 14, syntaxHighlightingEnabled: false)
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
    surface.scrollView.layoutSubtreeIfNeeded()
    surface.textView.setFrameSize(NSSize(width: surface.scrollView.contentSize.width, height: 240))
    let selection = NSRange(location: 10, length: 7)
    surface.textView.setSelectedRange(selection)

    func visualRows() -> Int {
      surface.scrollView.layoutSubtreeIfNeeded()
      surface.textLayoutManager.ensureLayout(for: surface.textLayoutManager.documentRange)
      var count = 0
      surface.textLayoutManager.enumerateTextLayoutFragments(
        from: surface.textLayoutManager.documentRange.location, options: [.ensuresLayout]
      ) { fragment in
        count += fragment.textLineFragments.count
        return true
      }
      return count
    }

    XCTAssertGreaterThan(visualRows(), 1, "ON must wrap a long logical line")
    surface.applyWrapPreference(false)
    surface.textView.sizeToFit()
    XCTAssertEqual(visualRows(), 1, "OFF must render one visual row")
    XCTAssertGreaterThan(surface.textView.frame.width, surface.scrollView.contentSize.width)
    XCTAssertTrue(surface.scrollView.hasHorizontalScroller)

    surface.applyWrapPreference(true)
    XCTAssertGreaterThan(visualRows(), 1, "Returning to ON must restore viewport-width wrapping")
    XCTAssertLessThanOrEqual(surface.textView.frame.width, surface.scrollView.contentSize.width + 1)
    XCTAssertEqual(surface.textView.selectedRange(), selection)
    XCTAssertEqual(surface.textStorage.string, text)
  }

  @MainActor
  func testPreviewStylesheetHonorsWrapOnAndDoesNotLetNowrapWin() {
    let on = PreviewWebView.appearanceCSS(fontSize: 14, wrapLines: true)
    XCTAssertTrue(on.contains(WrapPreference.previewStylesheetMarker))
    XCTAssertTrue(on.contains("white-space: pre-wrap !important"))
    XCTAssertTrue(
      wrapSection(in: on).contains("pre-wrap"),
      "the W2 wrap section must emit wrap, not a flavor nowrap")
    XCTAssertFalse(
      wrapSection(in: on).contains("nowrap"),
      "an unconditional nowrap must not win inside the W2 wrap section")

    let off = PreviewWebView.appearanceCSS(fontSize: 14, wrapLines: false)
    XCTAssertTrue(off.contains(WrapPreference.previewStylesheetMarker))
    XCTAssertTrue(wrapSection(in: off).contains("white-space: pre !important"))
    XCTAssertTrue(wrapSection(in: off).contains("overflow-x: auto"))
    XCTAssertFalse(wrapSection(in: off).contains("pre-wrap"))
  }

  @MainActor
  func testPreviewStylesheetSeamMatchesAppearanceCSS() {
    let wrapOn = WrapPreference.previewStylesheet(wrapLines: true)
    XCTAssertTrue(wrapOn.contains(WrapPreference.previewStylesheetMarker))
    XCTAssertTrue(wrapOn.contains("white-space: pre-wrap !important"))
    XCTAssertFalse(wrapOn.contains("nowrap"))

    let wrapOff = WrapPreference.previewStylesheet(wrapLines: false)
    XCTAssertTrue(wrapOff.contains("white-space: pre !important"))
    XCTAssertTrue(wrapOff.contains("overflow-x: auto"))
  }

  private func wrapSection(in css: String) -> String {
    guard let range = css.range(of: WrapPreference.previewStylesheetMarker) else {
      XCTFail("appearance CSS must emit the W2-01 wrap section")
      return ""
    }
    return String(css[range.lowerBound...])
  }
}
