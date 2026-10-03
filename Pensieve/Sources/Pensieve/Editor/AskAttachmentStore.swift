import CodescribeBridge
import Combine
import Foundation

/// One pending Ask attachment. Path-based on purpose: the embedded engine
/// reads and validates the file on the Rust side (core's single vision-loading
/// path), so Swift never marshals raw image bytes across the FFI.
struct AskAttachment: Equatable, Identifiable, Sendable {
  enum Origin: Equatable, Sendable {
    /// A user-owned file (picker, drop). Ask never copies nor deletes it.
    case external
    /// A Pensieve-owned staging copy (clipboard image). Ask deletes it when
    /// the attachment is removed or its send completes.
    case staged
  }

  let id: UUID
  let url: URL
  let origin: Origin
  let byteCount: Int64
}

/// A rejected attachment is a readable, explicit error — never a silent skip
/// of a file the user chose, and never a chip for data that cannot be sent.
enum AskAttachmentError: Error, Equatable {
  case unsupportedFormat(name: String)
  case missing(name: String)
  case empty(name: String)
  case tooLarge(name: String, limitBytes: Int64)
  case tooMany(count: Int, limit: Int)
}

extension AskAttachmentError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .unsupportedFormat(let name):
      return
        "Can't attach \(name): this Ask wave sends images only (PNG, JPEG, GIF, WebP, BMP or TIFF)."
    case .missing(let name):
      return "Can't attach \(name): the file no longer exists."
    case .empty(let name):
      return "Can't attach \(name): the file is empty."
    case .tooLarge(let name, let limitBytes):
      return "Can't attach \(name): images must be \(limitBytes / 1_024 / 1_024) MB or smaller."
    case .tooMany(let count, let limit):
      return "Too many images (\(count)). Attach at most \(limit) per message."
    }
  }
}

/// Attachment-capable Ask stream seam over the scoped FFI entrypoints. The
/// plain `CodescribeAgentStreaming` protocol stays untouched so existing
/// engines and test doubles keep compiling; a thread sending attachments
/// requires this seam and fails explicitly when the engine lacks it.
protocol CodescribeAgentAttachmentStreaming: CodescribeAgentStreaming {
  func streamDocumentWithAttachments(
    text: String, threadId: String, attachments: [CsAttachment], document: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String
}

/// Workspace twin of `CodescribeAgentAttachmentStreaming`.
protocol WorkspaceAgentAttachmentStreaming: WorkspaceAgentStreaming {
  func streamWorkspaceWithAttachments(
    text: String, threadId: String, attachments: [CsAttachment], workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String
}

extension CodescribeAgent: CodescribeAgentAttachmentStreaming, WorkspaceAgentAttachmentStreaming {}

/// The pending attachment set of one Ask thread, plus the Pensieve-owned
/// staging area for clipboard images. Staged copies live under the app's own
/// support directory and are deleted when removed or sent; external files are
/// referenced, never copied, and never deleted.
@MainActor
final class AskAttachmentStore: ObservableObject {
  /// Matches core's `MAX_VISION_IMAGE_BYTES` — both sides reject beyond it.
  nonisolated static let maximumImageBytes: Int64 = 8 * 1024 * 1024
  /// Matches the bridge's `MAX_COMPOSER_VISION_IMAGES` send cap.
  nonisolated static let maximumAttachments = 16
  /// Core's `image_media_type` extension set: the only formats the vision lane
  /// accepts. Anything else (PDF, HEIC, SVG, …) is rejected explicitly.
  nonisolated static let supportedExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff",
  ]

  @Published private(set) var attachments: [AskAttachment] = []

  let stagingDirectory: URL
  private let fileManager: FileManager

  init(stagingDirectory: URL? = nil, fileManager: FileManager = .default) {
    self.stagingDirectory =
      stagingDirectory ?? Self.defaultStagingDirectory(fileManager: fileManager)
    self.fileManager = fileManager
  }

  /// Pensieve-owned staging root: the isolated support root when one is armed,
  /// else `Application Support/Pensieve/AskStaging`. Created on first stage.
  static func defaultStagingDirectory(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let root = AppSupportLocation.isolationRoot(
      environment: environment, fileManager: fileManager)
    {
      return root.appendingPathComponent("AskStaging", isDirectory: true)
    }
    let appSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support", isDirectory: true)
    return appSupport.appendingPathComponent("Pensieve", isDirectory: true)
      .appendingPathComponent("AskStaging", isDirectory: true)
  }

  /// Stage in-memory image data (a clipboard image) into Pensieve-owned
  /// support staging. The write runs off the caller's actor; a cancellation
  /// racing the write removes the partial copy rather than leaking it.
  @discardableResult
  func stageImage(data: Data, fileExtension: String, suggestedName: String? = nil) async throws
    -> AskAttachment
  {
    guard attachments.count < Self.maximumAttachments else {
      throw AskAttachmentError.tooMany(
        count: attachments.count + 1, limit: Self.maximumAttachments)
    }
    let directory = stagingDirectory
    let staged = try await Task.detached(priority: .userInitiated) {
      try Self.stageImageData(
        data, fileExtension: fileExtension, suggestedName: suggestedName,
        into: directory, fileManager: .default)
    }.value
    do {
      try Task.checkCancellation()
      guard attachments.count < Self.maximumAttachments else {
        throw AskAttachmentError.tooMany(
          count: attachments.count + 1, limit: Self.maximumAttachments)
      }
    } catch {
      // A stale or over-limit staging task must not attach: its copy is
      // Pensieve-owned, so it is deleted rather than leaked.
      try? fileManager.removeItem(at: staged.url)
      throw error
    }
    attachments.append(staged)
    return staged
  }

  /// Reference a user-owned file (picker, drop). The file is never copied and
  /// never deleted by Ask. Format, existence and size are validated off the
  /// caller's actor, before the chip exists.
  @discardableResult
  func addExternal(url: URL) async throws -> AskAttachment {
    guard attachments.count < Self.maximumAttachments else {
      throw AskAttachmentError.tooMany(
        count: attachments.count + 1, limit: Self.maximumAttachments)
    }
    let attachment = try await Task.detached(priority: .userInitiated) {
      try Self.validateOne(url: url, origin: .external, fileManager: .default)
    }.value
    try Task.checkCancellation()
    guard attachments.count < Self.maximumAttachments else {
      throw AskAttachmentError.tooMany(
        count: attachments.count + 1, limit: Self.maximumAttachments)
    }
    attachments.append(attachment)
    return attachment
  }

  /// Remove one pending attachment. Staged copies are deleted; external files
  /// are only unreferenced.
  func remove(id: UUID) {
    guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
    let attachment = attachments.remove(at: index)
    deleteIfStaged(attachment)
  }

  /// Re-validate the pending set immediately before a send, on the caller's
  /// (background) executor. All-or-nothing: the first failure aborts the send
  /// with a readable error instead of sending a quietly degraded message.
  nonisolated static func validateForSend(
    _ attachments: [AskAttachment], fileManager: FileManager = .default
  ) throws {
    guard attachments.count <= maximumAttachments else {
      throw AskAttachmentError.tooMany(
        count: attachments.count, limit: maximumAttachments)
    }
    for attachment in attachments {
      _ = try validateOne(
        url: attachment.url, origin: attachment.origin, id: attachment.id,
        fileManager: fileManager)
    }
  }

  /// A completed send consumes its attachments: staged copies are deleted and
  /// the IDs leave the pending set, so a second send cannot resubmit them.
  /// External files are unreferenced, never deleted. IDs that are not pending
  /// (a stale completion racing a newer set) are ignored.
  func releaseSent(ids: [UUID]) {
    let sent = Set(ids)
    let released = attachments.filter { sent.contains($0.id) }
    attachments.removeAll { sent.contains($0.id) }
    for attachment in released { deleteIfStaged(attachment) }
  }

  private func deleteIfStaged(_ attachment: AskAttachment) {
    guard attachment.origin == .staged else { return }
    guard
      attachment.url.deletingLastPathComponent().standardizedFileURL
        == stagingDirectory.standardizedFileURL
    else { return }
    try? fileManager.removeItem(at: attachment.url)
  }

  /// Write clipboard image data under the staging root. Off-main callers only:
  /// this performs file I/O.
  nonisolated private static func stageImageData(
    _ data: Data, fileExtension: String, suggestedName: String?, into directory: URL,
    fileManager: FileManager
  ) throws -> AskAttachment {
    let name = suggestedName ?? "clipboard"
    let ext = fileExtension.lowercased()
    guard supportedExtensions.contains(ext) else {
      throw AskAttachmentError.unsupportedFormat(name: name)
    }
    guard !data.isEmpty else { throw AskAttachmentError.empty(name: name) }
    guard data.count <= maximumImageBytes else {
      throw AskAttachmentError.tooLarge(name: name, limitBytes: maximumImageBytes)
    }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID()
    let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
    try data.write(to: url, options: .atomic)
    return AskAttachment(id: id, url: url, origin: .staged, byteCount: Int64(data.count))
  }

  /// Existence, format, emptiness and size for one attachment. Returns the
  /// validated record. Off-main callers only: this stats the file.
  @discardableResult
  nonisolated private static func validateOne(
    url: URL, origin: AskAttachment.Origin, id: UUID = UUID(), fileManager: FileManager
  ) throws -> AskAttachment {
    let name = url.lastPathComponent
    guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
      throw AskAttachmentError.unsupportedFormat(name: name)
    }
    guard fileManager.fileExists(atPath: url.path) else {
      throw AskAttachmentError.missing(name: name)
    }
    let size =
      (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    guard let size else { throw AskAttachmentError.missing(name: name) }
    guard size > 0 else { throw AskAttachmentError.empty(name: name) }
    guard size <= maximumImageBytes else {
      throw AskAttachmentError.tooLarge(name: name, limitBytes: maximumImageBytes)
    }
    return AskAttachment(id: id, url: url, origin: origin, byteCount: size)
  }
}
