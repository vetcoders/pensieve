import Foundation

/// The ONE size gate the open path is built around: above it a document is
/// carried to the screen in stages, at or below it nothing about opening
/// changes.
///
/// It lives in one place on purpose. Three separate costs are gated on it —
/// the file read (`DocumentStore`), the first syntax-highlight pass
/// (`MarkdownTextStorage`) and the first preview render (`PreviewRepresentable`)
/// — and they only add up to a coherent experience while they agree about which
/// documents are big. Three constants would have been three chances to drift,
/// and the failure mode of a drift is invisible: a file that stages its read but
/// then freezes on the highlight anyway.
enum LargeDocument {
  /// 1 MiB.
  ///
  /// Sized from what the main thread actually owes a document of this length in
  /// ONE run-loop turn. The repo's own measurement for a full reset + both
  /// highlighters is ~0.7 µs per character in a debug build
  /// (`MarkdownTextStorage.seedSecondsPerCharacter`), so 1 MiB of
  /// ASCII-dominated markdown is ~0.7 s of highlighting alone — before the
  /// wholesale `replaceCharacters` and the full cmark parse the same turn also
  /// carries. That is well past the ~100 ms at which a click stops feeling like
  /// it landed, and it lands with no signal at all: the window simply stops
  /// responding.
  ///
  /// Below the gate the same three costs fit inside a couple of frames, and
  /// staging them would buy nothing while adding a hop and a placeholder flash
  /// to every ordinary note. A markdown file over a megabyte is not an ordinary
  /// note.
  ///
  /// Applied in TWO units, deliberately with ONE number: bytes on disk before
  /// the file is read (the only measure available at that point) and UTF-16
  /// length afterwards. For ASCII-dominated markdown the two agree closely. Where
  /// they disagree the byte count is the larger one, so the disagreement can only
  /// stage the READ of a document whose highlight then still runs in a single
  /// pass — the harmless direction. It can never let a document past the gate
  /// that should have been staged.
  static let sizeBudget = 1_048_576

  /// Whether `size` — bytes on disk, or UTF-16 length in memory — puts a
  /// document past the gate.
  static func isLarge(_ size: Int) -> Bool {
    size > sizeBudget
  }

  /// Bytes `url` occupies on disk, or `nil` when the file system will not say.
  ///
  /// A `nil` answer deliberately reads as "not large" at every call site: an
  /// unmeasurable file takes the plain synchronous path it took before this gate
  /// existed, which is the behaviour-preserving choice.
  static func fileSize(of url: URL) -> Int? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
  }

  /// Whether the file at `url` is past the gate, judged from its size on disk.
  static func isLargeFile(at url: URL) -> Bool {
    guard let size = fileSize(of: url) else { return false }
    return isLarge(size)
  }
}
