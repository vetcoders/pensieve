import AVFoundation
import XCTest

@testable import Pensieve

final class AppPermissionServiceTests: XCTestCase {
  func testMicrophoneSettingsFallbackOnlyForMissingPermission() {
    XCTAssertFalse(
      AppPermissionService.shouldOpenMicrophoneSettings(
        status: .authorized,
        grantedAfterPrompt: nil
      )
    )
    XCTAssertFalse(
      AppPermissionService.shouldOpenMicrophoneSettings(
        status: .notDetermined,
        grantedAfterPrompt: true
      )
    )
    XCTAssertTrue(
      AppPermissionService.shouldOpenMicrophoneSettings(
        status: .notDetermined,
        grantedAfterPrompt: false
      )
    )
    XCTAssertTrue(
      AppPermissionService.shouldOpenMicrophoneSettings(
        status: .denied,
        grantedAfterPrompt: nil
      )
    )
    XCTAssertTrue(
      AppPermissionService.shouldOpenMicrophoneSettings(
        status: .restricted,
        grantedAfterPrompt: nil
      )
    )
  }

  func testSystemSettingsPaneURLsUsePrivacyDeeplinks() {
    XCTAssertEqual(
      AppPermissionSettingsPane.accessibility.url.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    XCTAssertEqual(
      AppPermissionSettingsPane.microphone.url.absoluteString,
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )
  }

  func testDeveloperIDEntitlementsAllowMicrophoneCapture() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot =
      testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let entitlementsURL = packageRoot.appendingPathComponent("Resources/Pensieve.entitlements")
    let data = try Data(contentsOf: entitlementsURL)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )

    XCTAssertEqual(
      plist["com.apple.security.device.audio-input"] as? Bool,
      true,
      "The signed Developer ID app must carry the audio-input entitlement used by Dictation."
    )
  }
}
