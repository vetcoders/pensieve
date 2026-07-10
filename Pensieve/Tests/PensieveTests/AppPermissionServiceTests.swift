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
}
