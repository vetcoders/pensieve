import Foundation
import Observation

/// The app-wide auto-save preference (Settings ▸ General).
///
/// Auto-save governs exactly ONE thing: whether an edit to a document that
/// already has a location is written to that file on its own. Everything else
/// about saving is deliberately outside its reach:
///
/// * An untitled draft has no location to be saved INTO, so it keeps asking
///   `Save As… / Don't Save / Cancel` in both states. Auto-saving it would mean
///   inventing a file the user never chose.
/// * Crash-recovery drafts are written either way. Turning auto-save off is a
///   statement about the file on disk ("don't touch it until I say so"), not a
///   decision to risk the work if the app dies.
///
/// Consumers read the value at the moment of each decision and never cache it,
/// so flipping the toggle takes effect on the next keystroke and the next close
/// — no restart, and no already-scheduled write escaping under the old value.
@Observable
@MainActor
final class DocumentSavingSettings {
  static let shared = DocumentSavingSettings()

  /// The default the app registers for a first launch: auto-save ON. Exposed so
  /// the contract lives in one place — the UI only binds to the stored value,
  /// it never spells the default out itself.
  static let autoSavesPathedDocumentsDefault = true

  private static let autoSavesPathedDocumentsKey = "Pensieve.autoSavePathedDocuments"

  private let defaults: UserDefaults

  var autoSavesPathedDocuments: Bool {
    didSet {
      defaults.set(autoSavesPathedDocuments, forKey: Self.autoSavesPathedDocumentsKey)
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // An absent key is a first launch, not "off": `bool(forKey:)` would read a
    // missing value as false and silently ship the opposite default.
    if defaults.object(forKey: Self.autoSavesPathedDocumentsKey) == nil {
      self.autoSavesPathedDocuments = Self.autoSavesPathedDocumentsDefault
    } else {
      self.autoSavesPathedDocuments = defaults.bool(forKey: Self.autoSavesPathedDocumentsKey)
    }
  }
}
