import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Paste/drop classification ahead of the attachment store. An image or file
/// paste becomes an attachment route; ordinary text paste is left for the
/// native editor path so it keeps working byte-for-byte.
enum AskAttachmentInput {
  enum Route: Equatable {
    /// User-owned files (copied in Finder, dropped). Referenced, never copied.
    case files([URL])
    /// Raw image payload (a screenshot on the clipboard). Staged by the store.
    case imageData(Data, fileExtension: String)
    case notAnAttachment
  }

  /// Files win over raw image data: a copied image FILE arrives as a URL and
  /// must keep its on-disk identity, not a staged re-encode.
  static func route(pasteboard: NSPasteboard) -> Route {
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
    {
      return .files(urls)
    }
    if let png = pasteboard.data(forType: .png), !png.isEmpty {
      return .imageData(png, fileExtension: "png")
    }
    if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty {
      return .imageData(tiff, fileExtension: "tiff")
    }
    return .notAnAttachment
  }

  /// Claims the paste only when it really is an attachment. Returning false
  /// lets the text view insert the clipboard text unchanged, so no marker or
  /// path string ever spills into the draft or the document.
  @MainActor
  static func handlePaste(
    _ pasteboard: NSPasteboard, store: AskAttachmentStore,
    onError: @escaping @MainActor (String) -> Void
  ) -> Bool {
    switch route(pasteboard: pasteboard) {
    case .notAnAttachment:
      return false
    case .files(let urls):
      attach(urls: urls, store: store, onError: onError)
      return true
    case .imageData(let data, let fileExtension):
      Task { @MainActor in
        do {
          _ = try await store.stageImage(data: data, fileExtension: fileExtension)
        } catch {
          onError(error.localizedDescription)
        }
      }
      return true
    }
  }

  /// Every dropped/copied file goes through store validation; unsupported
  /// formats surface the store's explicit error instead of becoming a chip.
  @MainActor
  static func attach(
    urls: [URL], store: AskAttachmentStore,
    onError: @escaping @MainActor (String) -> Void
  ) {
    for url in urls {
      Task { @MainActor in
        do {
          _ = try await store.addExternal(url: url)
        } catch {
          onError(error.localizedDescription)
        }
      }
    }
  }
}

/// One chip's thumbnail. Decode runs off the UI actor through ImageIO's
/// bounded thumbnail path — never in a SwiftUI body, never the full image.
@MainActor
final class AskAttachmentThumbnail: ObservableObject {
  @Published private(set) var image: NSImage?
  private var started = false

  nonisolated static let maxThumbnailPixel: Int = 96

  func load(url: URL) {
    guard !started else { return }
    started = true
    let maxPixel = Self.maxThumbnailPixel
    Task.detached(priority: .userInitiated) { [weak self] in
      let options: CFDictionary =
        [
          kCGImageSourceThumbnailMaxPixelSize: maxPixel,
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
      else { return }
      let decoded = NSImage(
        cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
      await MainActor.run { self?.image = decoded }
    }
  }
}

/// The pending-attachment chips: preview, name, and a remove control. Sent
/// chips are released by the thread on completion, so a chip always names
/// input that will actually reach the provider.
struct AskAttachmentChipsView: View {
  @ObservedObject var store: AskAttachmentStore
  var tokens: ThemeTokens
  var identifierPrefix: String

  var body: some View {
    if !store.attachments.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(store.attachments) { attachment in
            AskAttachmentChip(attachment: attachment, store: store, tokens: tokens)
              .accessibilityIdentifier("\(identifierPrefix).attachment.\(attachment.id.uuidString)")
          }
        }
        .padding(.vertical, 2)
      }
      .frame(maxHeight: 44)
      .accessibilityIdentifier("\(identifierPrefix).attachments")
    }
  }
}

private struct AskAttachmentChip: View {
  let attachment: AskAttachment
  let store: AskAttachmentStore
  let tokens: ThemeTokens
  @StateObject private var thumbnail = AskAttachmentThumbnail()

  var body: some View {
    HStack(spacing: 6) {
      if let image = thumbnail.image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 28, height: 28)
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      } else {
        Image(systemName: "photo")
          .font(.system(size: 12))
          .frame(width: 28, height: 28)
      }
      Text(attachment.url.lastPathComponent)
        .font(.system(size: 11))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 140)
      Button {
        store.remove(id: attachment.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 16, height: 16)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove attachment \(attachment.url.lastPathComponent)")
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color(nsColor: tokens.codeBackground.nsColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(Color(nsColor: tokens.border.nsColor).opacity(0.6), lineWidth: 1)
    )
    .onAppear { thumbnail.load(url: attachment.url) }
  }
}

/// The "+" attach control. The panel is a deliberate user gesture on the UI
/// actor; the files it returns still pass through store validation off-main.
struct AskAttachmentMenu: View {
  let store: AskAttachmentStore
  var tokens: ThemeTokens
  var identifierPrefix: String
  var onError: @MainActor (String) -> Void

  var body: some View {
    Button {
      pickImages()
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color(nsColor: tokens.muted.nsColor))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Attach images — or paste / drop them into the message")
    .accessibilityLabel("Attach images")
    .accessibilityIdentifier("\(identifierPrefix).attach")
  }

  private func pickImages() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .bmp, .tiff]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Attach images to this Ask message"
    guard panel.runModal() == .OK else { return }
    AskAttachmentInput.attach(urls: panel.urls, store: store, onError: onError)
  }
}
