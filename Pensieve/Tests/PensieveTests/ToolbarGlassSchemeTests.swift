import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

/// A window that states its own appearance and says NOTHING about its toolbar is
/// not a window with a neutral toolbar — it is a window that handed the decision
/// to AppKit's glass, which resolves each pill against the content composited
/// beneath it.
///
/// Measured on an isolated probe (typewriter, system dark, one document open in
/// split mode): the window resolved `darkAqua`, `NSTitlebarView` and
/// `NSToolbarView` resolved `VibrantDark`, and every `NSToolbarPlatterView`
/// sitting over the PREVIEW column — the sheet a paired skin pins white in both
/// halves — carried an explicitly set `VibrantLight`. Dark titlebar, dark leading
/// families, white trailing pills. Declaring the toolbar scheme put all of them
/// back on `DarkAqua`.
///
/// That composition cannot be reproduced below the window server: the same rig
/// built offscreen, and built on screen over a white `ScrollView`, never grows
/// the scroll pocket the luminance adjustment lives in, so the platters stay dark
/// with and without the fix. What IS pinnable — and what was missing when the
/// symptom shipped — is the DECLARATION: the toolbar scheme must exist, and it
/// must be the window's own answer rather than a second, independently derived
/// one. These pins hold that contract for every skin, and for both halves of the
/// pair that made the gap visible.
final class ToolbarGlassSchemeTests: XCTestCase {
  /// THE REGRESSION PIN. Under the shipped defect the toolbar had no declared
  /// scheme at all, so there was no second answer to compare — which is exactly
  /// the state this forbids.
  @MainActor
  func testEverySkinDeclaresItsToolbarSchemeAndItMatchesTheWindow() throws {
    for skin in PensieveTheme.allCases {
      let chrome = WindowChromeRecipe.skinChrome(for: skin)
      XCTAssertEqual(
        chrome.toolbar, chrome.window,
        "\(skin.rawValue): the toolbar and the window must state ONE scheme — a toolbar left to "
          + "disagree with its window is a toolbar AppKit resolves against the content under it")
      XCTAssertEqual(
        chrome.window, WindowChromeRecipe.preferredColorScheme(for: skin),
        "\(skin.rawValue): the window scheme must stay the recipe's single answer")
    }
  }

  /// The pair is the case that produced the symptom: one enum case, two halves,
  /// and a reading surface deliberately pinned white on BOTH of them. Whichever
  /// half is live, the toolbar has to be told which one — under dark it is the
  /// white sheet under the trailing pills that would otherwise decide.
  @MainActor
  func testAPairedSkinStatesAToolbarSchemeOnBothHalves() throws {
    let paired = PensieveTheme.allCases.filter(\.isPaired)
    XCTAssertFalse(paired.isEmpty, "the pair this suite exists for has disappeared")

    for skin in paired {
      for dark in [true, false] {
        try withSystemAppearance(dark: dark) {
          let chrome = WindowChromeRecipe.skinChrome(for: skin)
          XCTAssertEqual(
            chrome.toolbar, dark ? .dark : .light,
            "\(skin.rawValue) on the \(dark ? "dark" : "light") half: the toolbar must follow the "
              + "half that is live, not the sheet that is white on both")
          XCTAssertEqual(
            chrome.toolbar, chrome.window,
            "\(skin.rawValue) on the \(dark ? "dark" : "light") half: window and toolbar disagree")
        }
      }
    }
  }

  /// An adaptive skin declares nothing on purpose — it follows the system, and
  /// its reading surface follows the system with it, so there is no white sheet
  /// under a dark toolbar for the glass to react to. Pinned so the fix above is
  /// not "state something everywhere", which would freeze the adaptive skins to
  /// whatever the setting was when the window opened.
  @MainActor
  func testAdaptiveSkinsStillDeclineToStateAScheme() throws {
    for skin in PensieveTheme.allCases where WindowChromeRecipe.windowAppearance(for: skin) == nil {
      let chrome = WindowChromeRecipe.skinChrome(for: skin)
      XCTAssertNil(chrome.window, "\(skin.rawValue): an adaptive skin must not pin its window")
      XCTAssertNil(chrome.toolbar, "\(skin.rawValue): an adaptive skin must not pin its toolbar")
    }
  }

  /// The AppKit half of the recipe and the SwiftUI half have to keep agreeing:
  /// the toolbar scheme is derived from `appearanceName`, the same source
  /// `assertWindowChrome` writes to the window, so a skin cannot end up with a
  /// dark window and a light toolbar through the back door.
  @MainActor
  func testToolbarSchemeAgreesWithTheAppKitWindowAppearance() throws {
    for skin in PensieveTheme.allCases {
      let appearance = WindowChromeRecipe.windowAppearance(for: skin)
      let expected: ColorScheme? =
        switch appearance?.name {
        case .some(.darkAqua): .dark
        case .some: .light
        case .none: nil
        }
      XCTAssertEqual(
        WindowChromeRecipe.skinChrome(for: skin).toolbar, expected,
        "\(skin.rawValue): the toolbar scheme drifted from the window appearance AppKit is given")
    }
  }
}
