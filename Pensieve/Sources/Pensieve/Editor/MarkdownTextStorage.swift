import AppKit

class MarkdownTextStorage: NSTextContentStorage {
  let highlighter = SyntaxHighlighter()
  let codeBlockHighlighter = CodeBlockHighlighter()
  private var highlightWorkItem: DispatchWorkItem?
  private var pendingHighlightRange: NSRange?
  private var pendingRequiresFullRefresh = false
  private var lastProcessedString = ""

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
    if requiresFullRefresh {
      pendingRequiresFullRefresh = true
      pendingHighlightRange = nil
    } else if !pendingRequiresFullRefresh {
      adjustPendingHighlightRange(
        for: editedRange,
        delta: delta,
        textLength: textStorage?.length ?? 0
      )
      let codeBlockRange = codeBlockAwareRange(for: scopedRange)
      pendingHighlightRange =
        pendingHighlightRange.map { NSUnionRange($0, codeBlockRange) } ?? codeBlockRange
    }

    let workItem = DispatchWorkItem { [weak self] in
      self?.applyScheduledHighlightingRefresh()
    }
    highlightWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(70), execute: workItem)
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
    refreshHighlighting(in: scopedRange)
  }

  func refreshHighlighting() {
    highlightWorkItem?.cancel()
    highlightWorkItem = nil
    pendingHighlightRange = nil
    pendingRequiresFullRefresh = false
    guard let textStorage = textStorage else { return }
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
  }

  private func refreshHighlighting(in range: NSRange) {
    guard let textStorage = textStorage else { return }
    let string = textStorage.string as NSString
    let scopedRange = clampedRange(range, textLength: string.length)

    textStorage.beginEditing()
    highlighter.resetBaseAttributes(textStorage, range: scopedRange)
    if syntaxHighlightingEnabled {
      highlighter.highlight(textStorage, range: scopedRange)
      codeBlockHighlighter.highlight(textStorage, range: scopedRange)
    }
    textStorage.endEditing()
    lastProcessedString = textStorage.string
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

  private func codeBlockAwareRange(for range: NSRange) -> NSRange {
    guard let textStorage = textStorage else { return range }
    let string = textStorage.string as NSString
    var result = clampedRange(range, textLength: string.length)
    var openFenceLineRange: NSRange?
    var location = 0

    while location < string.length {
      let lineRange = lineRange(at: location, in: string)
      let contentRange = lineContentRange(from: lineRange, in: string)

      if isFenceLine(in: string, range: contentRange) {
        if let openingRange = openFenceLineRange {
          let blockRange = NSRange(
            location: openingRange.location,
            length: NSMaxRange(lineRange) - openingRange.location
          )
          if rangesTouchOrIntersect(blockRange, result) {
            result = NSUnionRange(result, blockRange)
          }
          openFenceLineRange = nil
        } else {
          openFenceLineRange = lineRange
        }
      }

      guard NSMaxRange(lineRange) > location else { break }
      location = NSMaxRange(lineRange)
    }

    return result
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
