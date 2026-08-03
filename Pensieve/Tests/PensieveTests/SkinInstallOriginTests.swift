import Foundation
import XCTest

@testable import Pensieve

/// A missing `pensieve.preview.skin` key does not mean one thing.
///
/// The shipped builds resolved it to `.default`; this build's fresh-install
/// default is `.graphite`. `skin`'s `didSet` does not fire during `init`, so an
/// operator who has been reading on Default since before this build and never
/// opened the picker has NO key — indistinguishable, from the key alone, from a
/// machine that has never run Pensieve. Reading both as "fresh install" would
/// silently re-theme every existing user on first launch.
final class SkinInstallOriginTests: XCTestCase {
  /// A container with nothing of Pensieve's in it is a new install, and takes
  /// this build's default.
  func testEmptyContainerIsAFreshInstallAndTakesGraphite() {
    let defaults = makeEphemeralDefaults(prefix: "pensieve.install.fresh")

    XCTAssertEqual(ThemeManager.installOrigin(defaults: defaults), .fresh)
    XCTAssertEqual(ThemeManager(defaults: defaults).skin, .graphite)
  }

  /// A container a previous build already wrote to, with no skin key: that
  /// operator was on Default and never chose otherwise. She keeps Default.
  ///
  /// Red before the fix — `resolve` answered `.graphite` for a missing key
  /// whatever else was in the container.
  func testPreexistingContainerWithoutASkinKeyKeepsDefault() {
    for evidenceKey in ThemeManager.priorContainerKeys {
      let defaults = makeEphemeralDefaults(prefix: "pensieve.install.upgrade")
      defaults.set("x", forKey: evidenceKey)

      XCTAssertEqual(
        ThemeManager.installOrigin(defaults: defaults), .upgrade,
        "\(evidenceKey): a container this key is in has been used before")
      XCTAssertEqual(
        ThemeManager(defaults: defaults).skin, .default,
        "\(evidenceKey): an upgrader who never picked a skin must not be re-themed")
    }
  }

  /// CONTROL: a stored skin is a CHOICE and outranks the whole question, on a
  /// fresh container and on a used one alike. Without this leg the fix could
  /// override the picker.
  func testAStoredSkinAlwaysWins() {
    for theme in PensieveTheme.allCases {
      let fresh = makeEphemeralDefaults(prefix: "pensieve.install.chosen.fresh")
      fresh.set(theme.rawValue, forKey: ThemeManager.skinKey)
      XCTAssertEqual(ThemeManager(defaults: fresh).skin, theme)

      let used = makeEphemeralDefaults(prefix: "pensieve.install.chosen.used")
      used.set(theme.rawValue, forKey: ThemeManager.skinKey)
      used.set("gfm", forKey: ThemeManager.flavorKey)
      XCTAssertEqual(ThemeManager(defaults: used).skin, theme)
    }
  }

  /// The marker is what makes the answer stable. Without it the classification
  /// would be re-derived every launch — and by the second launch this build has
  /// written keys of its own, so a fresh install would start reading as an
  /// upgrade and flip to Default.
  func testTheClassificationIsMadeOnceAndDoesNotDriftOnLaterLaunches() {
    let defaults = makeEphemeralDefaults(prefix: "pensieve.install.stable")

    let first = ThemeManager(defaults: defaults)
    XCTAssertEqual(first.skin, .graphite)
    XCTAssertEqual(
      defaults.string(forKey: ThemeManager.installOriginKey),
      ThemeManager.InstallOrigin.fresh.rawValue,
      "the first launch must write down what it decided")

    // The container is no longer empty — the operator changed the flavour.
    first.current = .gfm

    XCTAssertEqual(ThemeManager.installOrigin(defaults: defaults), .fresh)
    XCTAssertEqual(
      ThemeManager(defaults: defaults).skin, .graphite,
      "a fresh install must not turn into an upgrader once it has been used")
  }

  /// …and the same, the other way round: an upgrader stays an upgrader.
  func testAnUpgraderStaysAnUpgraderAcrossLaunches() {
    let defaults = makeEphemeralDefaults(prefix: "pensieve.install.stableUpgrade")
    defaults.set("gfm", forKey: ThemeManager.flavorKey)

    XCTAssertEqual(ThemeManager(defaults: defaults).skin, .default)
    XCTAssertEqual(
      defaults.string(forKey: ThemeManager.installOriginKey),
      ThemeManager.InstallOrigin.upgrade.rawValue)
    XCTAssertEqual(ThemeManager(defaults: defaults).skin, .default)
  }

  /// CONTROL: resolving a skin is not the operator picking one, so an install
  /// with no stored skin still gets none written — on either classification.
  func testResolvingASkinNeverWritesAChoice() {
    let fresh = makeEphemeralDefaults(prefix: "pensieve.install.nochoice.fresh")
    _ = ThemeManager(defaults: fresh)
    XCTAssertNil(fresh.string(forKey: ThemeManager.skinKey))

    let upgrade = makeEphemeralDefaults(prefix: "pensieve.install.nochoice.upgrade")
    upgrade.set("gfm", forKey: ThemeManager.flavorKey)
    _ = ThemeManager(defaults: upgrade)
    XCTAssertNil(upgrade.string(forKey: ThemeManager.skinKey))
  }
}
