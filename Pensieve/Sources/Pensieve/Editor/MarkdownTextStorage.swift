import AppKit

class MarkdownTextStorage: NSTextContentStorage {
  let highlighter = SyntaxHighlighter()
  let codeBlockHighlighter = CodeBlockHighlighter()
  private var highlightWorkItem: DispatchWorkItem?
  private var pendingHighlightRange: NSRange?
  private var pendingRequiresFullRefresh = false
  private var lastProcessedString = ""

  /// Delay before a scheduled highlight pass runs. Shared by the typing debounce
  /// and the deferred retheme pass so the two can never drift apart. It must be a
  /// TIMER, not a bare `main.async`: a block enqueued on the main queue is drained
  /// in the same run-loop iteration that queued it, i.e. before Core Animation
  /// commits the frame — which would put the full pass back in front of the
  /// repaint it is supposed to follow.
  private static let highlightRefreshDelay: DispatchTimeInterval = .milliseconds(70)

  /// Character range the operator is actually looking at, supplied by the host
  /// surface. Injected rather than read out of layout in here so the storage
  /// keeps no view dependency and the viewport-first retheme is provable
  /// headless. `nil` means "layout has not established a viewport yet" (the
  /// launch ordering, where the surface is themed before it has a window), and
  /// then a retheme falls back to the plain synchronous full pass.
  var visibleRangeProvider: (() -> NSRange?)?

  /// Fired once a DEFERRED retheme's full-document pass has run. A full refresh
  /// strips `.backgroundColor` document-wide, which is where the find-match
  /// washes live; with the pass deferred it lands AFTER `applyTheme` already
  /// repainted them, so the surface needs a second chance to put them back.
  var onRethemeCompleted: (() -> Void)?

  /// Fired after a SCOPED pass repaints `range`, with the range it painted.
  ///
  /// A scoped pass runs `resetBaseAttributes` over its range, which strips
  /// `.backgroundColor` — the attribute the find-match washes live in. The
  /// deferred sweep starts at offset 0 and walks the document one chunk per
  /// frame, so a find session with matches near the TOP lost its washes on the
  /// first chunk and, with `onRethemeCompleted` as the only signal, got them
  /// back only after the LAST one. On a large document that is the whole length
  /// of the sweep with the matches invisible.
  ///
  /// Scoped, so the surface repaints only the matches the pass actually touched
  /// rather than the whole cached set on every chunk.
  var onHighlightingRepainted: ((NSRange) -> Void)?

  /// Full-document refresh passes performed so far. Exposed so the perf pins can
  /// prove what the timings say: a skin switch on a large document must not run
  /// one synchronously, and a burst of switches must collapse into ONE.
  private(set) var fullRefreshCount = 0

  // MARK: - Deferred retheme sweep

  /// Next character offset the deferred sweep still has to paint, or `nil` when
  /// no sweep is in flight.
  private var rethemeSweepCursor: Int?
  private var rethemeWorkItem: DispatchWorkItem?

  /// Rolling estimate of what a reset + both highlighters cost per character,
  /// used to size the next chunk from a TIME budget rather than a fixed
  /// character count. Seeded from the measured debug figure and then replaced by
  /// real measurements, because a release build is several times faster and a
  /// chunk frozen at the debug size would make the sweep needlessly long there.
  private var rethemeSecondsPerCharacter = MarkdownTextStorage.seedSecondsPerCharacter

  /// Chunks completed in the current (or most recent) sweep, and the longest any
  /// single chunk held the main thread. Both exist for the perf pins: the whole
  /// point of chunking is that no single chunk blocks longer than a frame.
  private(set) var rethemeChunkCount = 0
  private(set) var longestRethemeChunkDuration: TimeInterval = 0

  /// Longest RANGE any single chunk painted. The duration above is the property
  /// that matters but it is a wall-clock measurement on a shared machine; this
  /// is the same contract stated deterministically, and it is what a fenced
  /// block used to blow open — the expansion could hand one chunk the entire
  /// block however big it was.
  private(set) var longestRethemeChunkLength = 0

  /// Whether a sweep still has ranges to paint. Exposed so a pin can land an
  /// edit at a moment that is provably MID-sweep instead of guessing a delay.
  var isRethemeSweepInFlight: Bool { rethemeSweepCursor != nil }

  /// Wall time one chunk of the deferred sweep may spend on the main thread.
  ///
  /// Settable so the pins can force a many-chunk sweep without a megabyte
  /// fixture; production always uses the default. One 60 Hz frame is the budget
  /// because the chunk rides a frame: anything longer and the sweep is back to
  /// being a visible stall, just a smaller one.
  var rethemeChunkTimeBudget: TimeInterval = MarkdownTextStorage.defaultRethemeChunkTimeBudget

  static let defaultRethemeChunkTimeBudget: TimeInterval = 1.0 / 60.0

  /// Measured on the running app: ~0.7 µs per character for a full reset + both
  /// highlighters in a debug build (860 ms for a 1.27 MB draft).
  static let seedSecondsPerCharacter: TimeInterval = 0.7e-6

  /// Chunk-length guard rails. The floor stops a pathological measurement from
  /// degenerating into a per-character crawl that would never finish; the
  /// ceiling stops one from swallowing the whole document and re-creating the
  /// single blocking pass this replaced.
  static let minimumRethemeChunkLength = 2_048
  static let maximumRethemeChunkLength = 262_144

  /// Cached, document-order list of every ``` fence line's `NSRange`.
  ///
  /// Whether a line sits inside a fenced code block depends on the PARITY of
  /// fences counted from the start of the document, so `codeBlockAwareRange`
  /// needs the full fence set — but recomputing it on every keystroke is the
  /// O(document-length) scan that caused per-keystroke typing lag. The set only
  /// changes when an edit touches a fence line, which the `requiresFullRefresh`
  /// path already detects, so we rebuild the cache there and reuse it for plain
  /// keystrokes. `nil` means "stale / not yet built" — rebuild on next use.
  private var fenceLineRangesCache: [NSRange]?

  var syntaxHighlightingEnabled: Bool = true {
    didSet {
      refreshHighlighting()
    }
  }

  var fontSize: CGFloat = 14 {
    didSet {
      highlighter.baseFontSize = fontSize
      codeBlockHighlighter.baseFontSize = fontSize
      refreshHighlighting()
    }
  }

  /// Active theme tokens for the source panel. Forwarded to BOTH highlighters —
  /// the markdown one and the fenced-code one — before the full refresh, so
  /// every already-typed range (prose and code alike) picks up the new colours
  /// in the same pass. Pushing tokens after the refresh would leave fenced code
  /// on the previous skin until the next edit.
  var tokens: ThemeTokens = PensieveTheme.default.tokens {
    didSet {
      highlighter.tokens = tokens
      codeBlockHighlighter.tokens = tokens
      rethemeHighlighting()
    }
  }

  /// Documents at or below this length re-colour in ONE synchronous pass. A full
  /// reset + both highlighters measured ~0.7 µs per character in a debug build
  /// (860 ms for a 1.27 MB draft), so 20 000 characters is roughly a single
  /// 60 Hz frame: below it deferring buys no repaint and only adds a hop.
  static let synchronousRethemeCharacterBudget = 20_000

  /// Re-colours the document for a newly applied palette.
  ///
  /// A live skin switch used to call `refreshHighlighting()` — reset the base
  /// attributes and re-run BOTH highlighters over the WHOLE document,
  /// synchronously on the main thread. Measured on the running app that is
  /// 860 ms for a 1.27 MB draft, so the source pane's pixels trailed the click by
  /// seconds while the preview, a `WKWebView` rendered out of process, repainted
  /// at once. That asymmetry is the whole "preview switches, source stays on the
  /// old skin" report; clicking through skins queued one such pass per click and
  /// stacked them into 3.5–4.5 s.
  ///
  /// So: repaint what is on screen now, defer the rest. The viewport is widened
  /// to whole paragraphs and to any code block it touches — the same context the
  /// full pass would give it, so the visible text is not coloured as prose for
  /// the duration of the deferral — and re-highlighted inline. The rest of the
  /// document is then swept in frame-sized chunks.
  private func rethemeHighlighting() {
    guard let textStorage = textStorage else { return }
    let string = textStorage.string as NSString
    guard string.length > Self.synchronousRethemeCharacterBudget,
      let visibleRange = visibleRangeProvider?(),
      clampedRange(visibleRange, textLength: string.length).length > 0
    else {
      refreshHighlighting()
      return
    }

    let viewportRange = clampedRange(visibleRange, textLength: string.length)
    let scope = codeBlockAwareScope(
      for: scopedHighlightRange(for: viewportRange, in: string))
    refreshHighlighting(in: scope)
    startRethemeSweep()
  }

  /// Starts (or restarts) the deferred sweep that carries the new palette across
  /// the rest of the document.
  ///
  /// The first cut of this fix queued ONE full-document pass behind the viewport
  /// repaint. That removed the stall from in front of the repaint but not from
  /// the main thread: measured on the running app, `applyTheme` fell from 860 ms
  /// to 150 ms, yet the remaining ~700 ms still landed as a single block one
  /// timer tick later, and click→pixels only came down from 3.5–4.5 s to 2.2 s.
  ///
  /// So the pass is cut into chunks sized from a TIME budget — one frame — and
  /// each chunk rides its own timer, yielding the main thread in between. The
  /// document is swept front to back; the viewport region is re-covered on the
  /// way past, which is wasted work but never a wrong colour, and it keeps the
  /// cursor arithmetic to a single monotonic offset.
  ///
  /// Restarting cancels whatever is in flight, so a burst of skin switches
  /// leaves exactly one sweep — the coalescing the previous cut got from
  /// cancelling its single work item.
  private func startRethemeSweep() {
    rethemeWorkItem?.cancel()
    rethemeSweepCursor = 0
    rethemeChunkCount = 0
    longestRethemeChunkDuration = 0
    longestRethemeChunkLength = 0
    scheduleNextRethemeChunk()
  }

  private func cancelRethemeSweep() {
    rethemeWorkItem?.cancel()
    rethemeWorkItem = nil
    rethemeSweepCursor = nil
  }

  /// A chunk is scheduled on a TIMER, never `main.async`. Blocks enqueued on the
  /// main queue drain within the run-loop iteration that queued them, so a chain
  /// of `async` chunks would run back-to-back inside one iteration and add up to
  /// exactly the single blocking pass this replaced. The delay is the chunk
  /// budget itself: long enough to let the frame the previous chunk dirtied
  /// actually composite, short enough that the sweep is not idling.
  ///
  /// The FIRST chunk uses the same delay rather than the 70 ms typing debounce.
  /// It costs nothing perceptually — the viewport was already repainted
  /// synchronously — and it shortens the tail, which is what the operator hits
  /// when scrolling right after a switch.
  private func scheduleNextRethemeChunk() {
    let workItem = DispatchWorkItem { [weak self] in
      self?.applyNextRethemeChunk()
    }
    rethemeWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + rethemeChunkTimeBudget, execute: workItem)
  }

  private func applyNextRethemeChunk() {
    rethemeWorkItem = nil
    guard let cursor = rethemeSweepCursor, let textStorage = textStorage else {
      rethemeSweepCursor = nil
      return
    }

    let string = textStorage.string as NSString
    guard cursor < string.length else {
      finishRethemeSweep()
      return
    }

    // Clamped against the CURRENT length on every turn: the document can shrink
    // between chunks (an undo, a delete, an external reload), and a cursor
    // captured before that must not index past the end.
    let planned = clampedRange(
      NSRange(location: cursor, length: plannedRethemeChunkLength()),
      textLength: string.length)
    let scope = codeBlockAwareScope(for: scopedHighlightRange(for: planned, in: string))
    let chunk = scope.range

    let started = Date()
    refreshHighlighting(in: scope)
    let elapsed = Date().timeIntervalSince(started)

    rethemeChunkCount += 1
    longestRethemeChunkDuration = max(longestRethemeChunkDuration, elapsed)
    longestRethemeChunkLength = max(longestRethemeChunkLength, chunk.length)
    if chunk.length > 0 {
      // Smoothed, so one noisy sample (a chunk that happened to straddle a big
      // fenced block) cannot halve or double every chunk that follows.
      rethemeSecondsPerCharacter =
        (rethemeSecondsPerCharacter + elapsed / Double(chunk.length)) / 2
    }

    // `codeBlockAwareRange` can widen BACKWARDS to swallow a block that opened
    // before the cursor, so the end of the painted chunk is the only honest next
    // cursor — and it must still advance, or a degenerate range would spin.
    let next = max(NSMaxRange(chunk), cursor + 1)
    if next >= string.length {
      finishRethemeSweep()
    } else {
      rethemeSweepCursor = next
      scheduleNextRethemeChunk()
    }
  }

  /// Chunk length that should fit the budget at the currently measured cost.
  private func plannedRethemeChunkLength() -> Int {
    let perCharacter = max(rethemeSecondsPerCharacter, 1e-9)
    let estimate = Int(rethemeChunkTimeBudget / perCharacter)
    return min(max(estimate, Self.minimumRethemeChunkLength), Self.maximumRethemeChunkLength)
  }

  /// Completion fires ONCE, after the last chunk — the find washes are repainted
  /// from here, and repainting them while the sweep still had ranges to strip
  /// would just erase them again.
  private func finishRethemeSweep() {
    cancelRethemeSweep()
    onRethemeCompleted?()
  }

  /// The source panel's base face for the active tokens and font size. Every
  /// surface that paints its own text (the text view, its typing attributes, the
  /// autocomplete ghost) reads it from here, so nothing can end up in a
  /// different family than the highlighter's own base attributes.
  var baseFont: NSFont {
    highlighter.baseFont
  }

  override func processEditing(
    for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
    range newCharRange: NSRange, changeInLength delta: Int,
    invalidatedRange invalidatedCharRange: NSRange
  ) {

    super.processEditing(
      for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta,
      invalidatedRange: invalidatedCharRange)

    if editMask.contains(.editedCharacters) {
      let oldString = lastProcessedString as NSString
      let newString = textStorage.string as NSString
      let editedRange = postEditRange(
        newCharRange: newCharRange,
        invalidatedCharRange: invalidatedCharRange,
        delta: delta,
        textLength: newString.length
      )
      let scopedRange = scopedHighlightRange(for: editedRange, in: newString)
      let requiresFullRefresh = editTouchesFence(
        oldString: oldString,
        newString: newString,
        newCharRange: newCharRange,
        invalidatedCharRange: invalidatedCharRange,
        delta: delta
      )

      scheduleHighlightingRefresh(
        for: scopedRange,
        editedRange: editedRange,
        delta: delta,
        requiresFullRefresh: requiresFullRefresh
      )
      lastProcessedString = textStorage.string
    }
  }

  private func scheduleHighlightingRefresh(
    for scopedRange: NSRange,
    editedRange: NSRange,
    delta: Int,
    requiresFullRefresh: Bool
  ) {
    highlightWorkItem?.cancel()
    // The document moved under an in-flight retheme sweep. Everything BEFORE the
    // cursor already carries the new palette, so the sweep is rebased rather
    // than restarted: an edit ahead of the cursor shifts every remaining offset
    // by `delta`, and restarting from zero on each keystroke would let continuous
    // typing starve the sweep and leave the tail of a big document on the old
    // skin indefinitely. The edited range itself is repainted by this very pass,
    // so no range is left behind either way.
    if let cursor = rethemeSweepCursor {
      let rebased = editedRange.location <= cursor ? max(0, cursor + delta) : cursor
      rethemeSweepCursor = min(rebased, textStorage?.length ?? rebased)
    }
    if requiresFullRefresh {
      pendingRequiresFullRefresh = true
      pendingHighlightRange = nil
      // A fence line was touched/created/deleted, so the cached fence set is
      // stale. Drop it; it rebuilds lazily on the next `codeBlockAwareRange`.
      fenceLineRangesCache = nil
    } else if !pendingRequiresFullRefresh {
      adjustPendingHighlightRange(
        for: editedRange,
        delta: delta,
        textLength: textStorage?.length ?? 0
      )
      // The fenced-block expansion is deferred to the apply, not folded in
      // here: it is bounded by the chunk ceiling, and a ceiling applied to each
      // of a burst of keystrokes and then unioned would not be a ceiling.
      pendingHighlightRange =
        pendingHighlightRange.map { NSUnionRange($0, scopedRange) } ?? scopedRange
    }

    let workItem = DispatchWorkItem { [weak self] in
      self?.applyScheduledHighlightingRefresh()
    }
    highlightWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.highlightRefreshDelay, execute: workItem)
  }

  private func applyScheduledHighlightingRefresh() {
    guard !pendingRequiresFullRefresh else {
      refreshHighlighting()
      return
    }

    guard let scopedRange = pendingHighlightRange else {
      highlightWorkItem = nil
      return
    }

    pendingHighlightRange = nil
    highlightWorkItem = nil
    refreshHighlighting(in: codeBlockAwareScope(for: scopedRange))
  }

  func refreshHighlighting() {
    highlightWorkItem?.cancel()
    highlightWorkItem = nil
    pendingHighlightRange = nil
    pendingRequiresFullRefresh = false
    // A full pass paints every range the sweep still had queued, so the sweep is
    // absorbed rather than left running behind it. It still owes its completion
    // callback: this pass strips `.backgroundColor` document-wide exactly like
    // the last chunk would have, and the find washes have to come back.
    let absorbedSweep = rethemeSweepCursor != nil
    cancelRethemeSweep()
    // Full refresh can follow a wholesale text replacement (document load,
    // font/syntax toggle), so invalidate the fence cache here too.
    fenceLineRangesCache = nil
    guard let textStorage = textStorage else { return }
    fullRefreshCount += 1
    let fullRange = NSRange(location: 0, length: textStorage.length)

    // Prevent recursive processEditing calls for attribute changes
    textStorage.beginEditing()
    highlighter.resetBaseAttributes(textStorage, range: fullRange)
    if syntaxHighlightingEnabled {
      highlighter.highlight(textStorage, range: fullRange)
      codeBlockHighlighter.highlight(textStorage, range: fullRange)
    }
    textStorage.endEditing()
    lastProcessedString = textStorage.string
    if absorbedSweep {
      onRethemeCompleted?()
    }
  }

  private func refreshHighlighting(in scope: HighlightScope) {
    guard let textStorage = textStorage else { return }
    let string = textStorage.string as NSString
    let scopedRange = clampedRange(scope.range, textLength: string.length)

    textStorage.beginEditing()
    highlighter.resetBaseAttributes(textStorage, range: scopedRange)
    if syntaxHighlightingEnabled {
      highlighter.highlight(textStorage, range: scopedRange)
      // Only where a COMPLETE fence can exist — see `rangesOutsidePartialBlocks`.
      for piece in scope.rangesOutsidePartialBlocks(in: scopedRange) {
        codeBlockHighlighter.highlight(textStorage, range: piece)
      }
      // Blocks the range only slices. The fence regex above cannot see them, so
      // without this pass the code inside a big fence would keep the prose
      // reset the chunk had just applied.
      for block in scope.partialBlocks {
        codeBlockHighlighter.highlight(textStorage, range: scopedRange, in: block)
      }
    }
    textStorage.endEditing()
    lastProcessedString = textStorage.string
    onHighlightingRepainted?(scopedRange)
  }

  private func postEditRange(
    newCharRange: NSRange,
    invalidatedCharRange: NSRange,
    delta: Int,
    textLength: Int
  ) -> NSRange {
    let newRange = clampedRange(newCharRange, textLength: textLength)
    let invalidatedLocation = min(max(0, invalidatedCharRange.location), textLength)
    let adjustedInvalidatedLength = max(0, invalidatedCharRange.length + delta)
    let invalidatedRange = clampedRange(
      NSRange(location: invalidatedLocation, length: adjustedInvalidatedLength),
      textLength: textLength
    )
    return NSUnionRange(newRange, invalidatedRange)
  }

  private func scopedHighlightRange(for range: NSRange, in string: NSString) -> NSRange {
    guard string.length > 0 else {
      return NSRange(location: 0, length: 0)
    }

    let contextRange = contextRangeAround(range, textLength: string.length)
    return string.paragraphRange(for: contextRange)
  }

  /// A range to repaint, plus any fenced block it lies inside that is too big to
  /// repaint whole.
  struct HighlightScope {
    let range: NSRange
    /// Blocks the range only partly covers, so `CodeBlockHighlighter` can still
    /// colour the slice as code without its fence regex finding the block.
    let partialBlocks: [CodeBlockHighlighter.BlockSlice]

    init(range: NSRange, partialBlocks: [CodeBlockHighlighter.BlockSlice] = []) {
      self.range = range
      self.partialBlocks = partialBlocks
    }

    /// `range` minus every partial block, in document order.
    ///
    /// The fence regex must NOT be run over a slice of a block it cannot
    /// complete. `(?s)```(.*?)\n(.*?)``` ` is lazy on both groups, so with no
    /// closing fence inside the slice it retries the tail scan from every line
    /// start in it — measured on the fenced fixture, that alone cost ~288 ms per
    /// chunk, WORSE than the unbounded expansion the clamp replaced. The blocks
    /// are disjoint and appended in document order, so the complement is one
    /// walk.
    func rangesOutsidePartialBlocks(in range: NSRange) -> [NSRange] {
      guard !partialBlocks.isEmpty else { return [range] }
      var pieces: [NSRange] = []
      var cursor = range.location
      let end = NSMaxRange(range)
      for block in partialBlocks {
        let blocked = NSIntersectionRange(block.blockRange, range)
        guard blocked.length > 0 else { continue }
        if blocked.location > cursor {
          pieces.append(NSRange(location: cursor, length: blocked.location - cursor))
        }
        cursor = max(cursor, NSMaxRange(blocked))
      }
      if cursor < end {
        pieces.append(NSRange(location: cursor, length: end - cursor))
      }
      return pieces
    }
  }

  /// Widens `range` to cover any fenced block it touches — but never past the
  /// chunk ceiling.
  ///
  /// The union used to be unbounded, on a range that had ALREADY been sized to
  /// `maximumRethemeChunkLength`, and then ran through `refreshHighlighting`
  /// synchronously. One ```swift fence bigger than a chunk therefore put the
  /// whole fence on the main thread in a single go — a reset, twelve markdown
  /// regexes, the fence regex, the per-language rules and a substring copy of
  /// the entire block. That is the blocking pass the chunked sweep was written
  /// to remove, reintroduced by the very expansion meant to keep the colours
  /// right.
  ///
  /// So: a block that fits is still swallowed whole (it is cheap, and the fence
  /// regex needs the complete block); a block that does not is left OUT of the
  /// repaint range and reported as a partial instead, which colours the slice
  /// from its known extent and language.
  private func codeBlockAwareScope(for range: NSRange) -> HighlightScope {
    guard let textStorage = textStorage else { return HighlightScope(range: range) }
    let string = textStorage.string as NSString
    var result = clampedRange(range, textLength: string.length)

    let fences = fenceLineRanges(in: string)
    guard fences.count >= 2 else { return HighlightScope(range: result) }

    // The ceiling never shrinks a range the caller already asked for; it only
    // stops the EXPANSION from growing one.
    let ceiling = max(result.length, plannedRethemeChunkLength())
    var partialBlocks: [CodeBlockHighlighter.BlockSlice] = []

    // Fences pair in document order: index 0 opens, 1 closes, 2 opens, ... .
    // A complete code block spans [open.location, NSMaxRange(close)). Blocks
    // are disjoint and sorted, so binary-search the first fence at/after
    // `result.location` and inspect only the few blocks bracketing `result`
    // instead of walking the whole document.
    let pivot = lowerBound(of: result.location, in: fences)

    // Candidate block-opener indices (even) near the pivot. Looking a couple of
    // pairs to each side covers a block that starts before `result` and the one
    // that starts after it.
    let firstOpener = max(0, ((pivot - 2) / 2) * 2)
    var openerIndex = firstOpener
    while openerIndex + 1 < fences.count {
      let open = fences[openerIndex]
      let close = fences[openerIndex + 1]
      let blockRange = NSRange(
        location: open.location,
        length: NSMaxRange(close) - open.location
      )

      // Sorted blocks: once a block starts past the end of `result`, no later
      // block can touch it either.
      if blockRange.location > NSMaxRange(result) {
        break
      }

      if rangesTouchOrIntersect(blockRange, result) {
        let union = NSUnionRange(result, blockRange)
        if union.length <= ceiling {
          result = union
        } else if let slice = blockSlice(open: open, close: close, in: string) {
          partialBlocks.append(slice)
        }
      }

      openerIndex += 2
    }

    return HighlightScope(range: result, partialBlocks: partialBlocks)
  }

  /// The (block, code, language) triple for a fenced block, read straight off
  /// its fence lines — the same information `CodeBlockHighlighter`'s regex would
  /// extract if the repaint range were wide enough to contain the whole block.
  private func blockSlice(open: NSRange, close: NSRange, in string: NSString)
    -> CodeBlockHighlighter.BlockSlice?
  {
    let codeStart = NSMaxRange(open)
    let codeEnd = close.location
    guard codeEnd > codeStart else { return nil }

    let infoRange = lineContentRange(from: open, in: string)
    // Drop the indent and the run of backticks, whatever its length: `isFenceLine`
    // accepts three OR MORE, and a fixed three would read "`swift" off a ````
    // fence and match no language table.
    let language = string.substring(with: infoRange)
      .drop(while: { $0 == "`" || $0 == " " || $0 == "\t" })
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    return CodeBlockHighlighter.BlockSlice(
      blockRange: NSRange(location: open.location, length: NSMaxRange(close) - open.location),
      codeRange: NSRange(location: codeStart, length: codeEnd - codeStart),
      language: language)
  }

  /// Returns the cached document-order fence-line ranges, rebuilding the cache
  /// with a single full-document walk if it is stale (`nil`). The rebuild only
  /// happens on full-refresh / fence-touching edits, never on plain keystrokes.
  private func fenceLineRanges(in string: NSString) -> [NSRange] {
    if let cached = fenceLineRangesCache {
      return cached
    }
    let computed = computeFenceLineRanges(in: string)
    fenceLineRangesCache = computed
    return computed
  }

  private func computeFenceLineRanges(in string: NSString) -> [NSRange] {
    var fences: [NSRange] = []
    var location = 0
    while location < string.length {
      let lineRange = lineRange(at: location, in: string)
      let contentRange = lineContentRange(from: lineRange, in: string)
      if isFenceLine(in: string, range: contentRange) {
        fences.append(lineRange)
      }

      guard NSMaxRange(lineRange) > location else { break }
      location = NSMaxRange(lineRange)
    }
    return fences
  }

  /// Index of the first fence whose `location` is `>= target` (binary search).
  private func lowerBound(of target: Int, in fences: [NSRange]) -> Int {
    var low = 0
    var high = fences.count
    while low < high {
      let mid = (low + high) / 2
      if fences[mid].location < target {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }

  private func editTouchesFence(
    oldString: NSString,
    newString: NSString,
    newCharRange: NSRange,
    invalidatedCharRange: NSRange,
    delta: Int
  ) -> Bool {
    let oldAffectedRange = scopedHighlightRange(
      for: clampedRange(invalidatedCharRange, textLength: oldString.length),
      in: oldString
    )
    let newAffectedRange = scopedHighlightRange(
      for: postEditRange(
        newCharRange: newCharRange,
        invalidatedCharRange: invalidatedCharRange,
        delta: delta,
        textLength: newString.length
      ),
      in: newString
    )

    return containsFenceLine(in: oldString, range: oldAffectedRange)
      || containsFenceLine(in: newString, range: newAffectedRange)
  }

  private func adjustPendingHighlightRange(for editedRange: NSRange, delta: Int, textLength: Int) {
    guard delta != 0, var pendingRange = pendingHighlightRange else { return }

    if editedRange.location <= pendingRange.location {
      pendingRange.location = max(0, pendingRange.location + delta)
    } else if editedRange.location < NSMaxRange(pendingRange) {
      pendingRange.length = max(0, pendingRange.length + delta)
    }

    pendingHighlightRange = clampedRange(pendingRange, textLength: textLength)
  }

  private func clampedRange(_ range: NSRange, textLength: Int) -> NSRange {
    let location = min(max(0, range.location), textLength)
    let length = min(max(0, range.length), textLength - location)
    return NSRange(location: location, length: length)
  }

  private func contextRangeAround(_ range: NSRange, textLength: Int) -> NSRange {
    guard textLength > 0 else { return NSRange(location: 0, length: 0) }

    let clamped = clampedRange(range, textLength: textLength)
    let start = max(0, clamped.location - 1)
    let end = min(textLength, max(NSMaxRange(clamped), clamped.location) + 1)
    return NSRange(location: start, length: end - start)
  }

  private func containsFenceLine(in string: NSString, range: NSRange) -> Bool {
    let targetRange = clampedRange(range, textLength: string.length)
    guard string.length > 0 else { return false }

    var location = targetRange.location
    let end = max(targetRange.location, NSMaxRange(targetRange))
    while location < min(end, string.length) {
      let lineRange = lineRange(at: location, in: string)
      let contentRange = lineContentRange(from: lineRange, in: string)
      if isFenceLine(in: string, range: contentRange) {
        return true
      }

      guard NSMaxRange(lineRange) > location else { break }
      location = NSMaxRange(lineRange)
    }

    let currentLineRange = lineRange(at: targetRange.location, in: string)
    let currentContentRange = lineContentRange(from: currentLineRange, in: string)
    return targetRange.length == 0 && isFenceLine(in: string, range: currentContentRange)
  }

  private func isFenceLine(in string: NSString, range: NSRange) -> Bool {
    guard range.length > 0 else { return false }
    let line = string.substring(with: range).trimmingCharacters(in: .whitespaces)
    return line.hasPrefix("```")
  }

  private func lineRange(at location: Int, in string: NSString) -> NSRange {
    let safeLocation = min(max(0, location), max(0, string.length - 1))
    var lineStart = 0
    var lineEnd = 0
    var contentsEnd = 0
    string.getLineStart(
      &lineStart,
      end: &lineEnd,
      contentsEnd: &contentsEnd,
      for: NSRange(location: safeLocation, length: 0)
    )
    return NSRange(location: lineStart, length: lineEnd - lineStart)
  }

  private func lineContentRange(from lineRange: NSRange, in string: NSString) -> NSRange {
    var lineStart = 0
    var lineEnd = 0
    var contentsEnd = 0
    string.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: lineRange)
    return NSRange(location: lineStart, length: contentsEnd - lineStart)
  }

  private func rangesTouchOrIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    NSIntersectionRange(lhs, rhs).length > 0
      || NSMaxRange(lhs) == rhs.location
      || NSMaxRange(rhs) == lhs.location
  }
}
