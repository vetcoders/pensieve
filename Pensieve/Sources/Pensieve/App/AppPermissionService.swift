import AVFoundation
import AppKit
import Foundation

enum AppPermissionSettingsPane: String {
  case accessibility = "Privacy_Accessibility"
  case microphone = "Privacy_Microphone"

  var url: URL {
    URL(
      string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"
    )!
  }
}

enum AppPermissionService {
  enum PermissionError: LocalizedError {
    case microphoneDenied
    case microphoneRestricted

    var errorDescription: String? {
      switch self {
      case .microphoneDenied:
        return
          "Microphone permission is required for transcription. Enable it in System Settings > Privacy & Security > Microphone."
      case .microphoneRestricted:
        return "Microphone access is restricted on this system."
      }
    }
  }

  static func ensureMicrophonePermission(openSettingsOnFailure: Bool) async throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return
    case .notDetermined:
      let granted = await withCheckedContinuation {
        (continuation: CheckedContinuation<Bool, Never>) in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          continuation.resume(returning: granted)
        }
      }
      if shouldOpenMicrophoneSettings(status: .notDetermined, grantedAfterPrompt: granted) {
        await openSettingsIfNeeded(.microphone, enabled: openSettingsOnFailure)
        throw PermissionError.microphoneDenied
      }
    case .denied:
      if shouldOpenMicrophoneSettings(status: .denied, grantedAfterPrompt: nil) {
        await openSettingsIfNeeded(.microphone, enabled: openSettingsOnFailure)
      }
      throw PermissionError.microphoneDenied
    case .restricted:
      if shouldOpenMicrophoneSettings(status: .restricted, grantedAfterPrompt: nil) {
        await openSettingsIfNeeded(.microphone, enabled: openSettingsOnFailure)
      }
      throw PermissionError.microphoneRestricted
    @unknown default:
      await openSettingsIfNeeded(.microphone, enabled: openSettingsOnFailure)
      throw PermissionError.microphoneDenied
    }
  }

  static func shouldOpenMicrophoneSettings(
    status: AVAuthorizationStatus,
    grantedAfterPrompt: Bool?
  ) -> Bool {
    switch status {
    case .authorized:
      return false
    case .notDetermined:
      return grantedAfterPrompt == false
    case .denied, .restricted:
      return true
    @unknown default:
      return true
    }
  }

  @MainActor
  private static func openSettings(_ pane: AppPermissionSettingsPane) {
    NSWorkspace.shared.open(pane.url)
  }

  private static func openSettingsIfNeeded(
    _ pane: AppPermissionSettingsPane,
    enabled: Bool
  ) async {
    guard enabled else { return }
    await MainActor.run {
      openSettings(pane)
    }
  }
}
