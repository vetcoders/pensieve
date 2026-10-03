import CoreGraphics
import Foundation

/// Ask markdown vocabulary transplanted from the Codescribe chat donor.
///
/// Block structure, table geometry and inline runs are resolved here. A SwiftUI
/// body only reads the result. `copyableSource` stays the exact original text,
/// including escaped pipes and fence markers that the structured view does not
/// display literally.

struct AskMarkdownDocument: Equatable, Sendable {
  var source: String
  var blocks: [AskMarkdownBlock]

  var copyableSource: String { source }
}

struct AskMarkdownText: Equatable, Sendable {
  var source: String
  var inlines: [AskMarkdownInline]
}

enum AskMarkdownInline: Equatable, Sendable {
  case text(String)
  case strong(String)
  case emphasis(String)
  case code(String)
  case link(label: String, url: String)
}

enum AskCalloutKind: String, Equatable, Sendable {
  case note = "NOTE"
  case tip = "TIP"
  case important = "IMPORTANT"
  case warning = "WARNING"
  case caution = "CAUTION"

  var label: String { rawValue }

  var systemImage: String {
    switch self {
    case .note: return "info.circle"
    case .tip: return "lightbulb"
    case .important: return "exclamationmark.circle"
    case .warning: return "exclamationmark.triangle"
    case .caution: return "exclamationmark.octagon"
    }
  }
}

enum AskMarkdownBlock: Equatable, Sendable {
  case paragraph(AskMarkdownText)
  case heading(level: Int, AskMarkdownText)
  case bullet(indent: Int, AskMarkdownText)
  case ordered(indent: Int, number: Int, AskMarkdownText)
  case task(indent: Int, done: Bool, AskMarkdownText)
  case table(header: [AskMarkdownText], rows: [[AskMarkdownText]], columnCount: Int)
  case code(language: String?, String)
  indirect case blockquote(AskMarkdownText, children: [AskMarkdownBlock])
  indirect case callout(AskCalloutKind, AskMarkdownText, children: [AskMarkdownBlock])
  case thematicBreak
}

enum AskMarkdownParser {
  static func parse(_ source: String) -> AskMarkdownDocument {
    AskMarkdownDocument(source: source, blocks: blocks(from: source))
  }

  static func blocks(from source: String) -> [AskMarkdownBlock] {
    var blocks: [AskMarkdownBlock] = []
    var paragraph: [String] = []

    func flush() {
      guard !paragraph.isEmpty else { return }
      blocks.append(.paragraph(text(paragraph.joined(separator: "\n"))))
      paragraph.removeAll(keepingCapacity: true)
    }

    let lines = linesOf(source)
    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if let fence = openingFence(trimmed) {
        flush()
        var body: [String] = []
        index += 1
        while index < lines.count {
          let closeTrim = lines[index].trimmingCharacters(in: .whitespaces)
          if let closeTicks = closingFence(closeTrim), closeTicks >= fence.ticks {
            index += 1
            break
          }
          body.append(lines[index])
          index += 1
        }
        blocks.append(.code(language: fence.language, body.joined(separator: "\n")))
        continue
      }

      if trimmed.isEmpty {
        flush()
        index += 1
        continue
      }

      if isThematicBreak(trimmed) {
        flush()
        blocks.append(.thematicBreak)
        index += 1
        continue
      }

      if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
        flush()
        let header = tableCells(trimmed)
        index += 2
        var rows: [[String]] = []
        while index < lines.count {
          let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
          guard !rowLine.isEmpty, rowLine.contains("|") else { break }
          rows.append(tableCells(rowLine))
          index += 1
        }
        let grid = normalizedTable(header: header, rows: rows)
        blocks.append(
          .table(
            header: grid.header.map(text),
            rows: grid.rows.map { $0.map(text) },
            columnCount: grid.columnCount))
        continue
      }

      if trimmed.hasPrefix(">") {
        flush()
        var quote: [String] = []
        while index < lines.count {
          let quoted = lines[index].trimmingCharacters(in: .whitespaces)
          guard quoted.hasPrefix(">") else { break }
          quote.append(stripQuoteMarker(quoted))
          index += 1
        }
        blocks.append(quoteBlock(quote.joined(separator: "\n")))
        continue
      }

      if let heading = headingBlock(trimmed) {
        flush()
        blocks.append(heading)
        index += 1
        continue
      }

      if let item = listBlock(line) {
        flush()
        blocks.append(item)
        index += 1
        continue
      }

      paragraph.append(trimmed)
      index += 1
    }
    flush()
    return blocks
  }

  /// `components(separatedBy:)` invents an empty line for a terminating
  /// newline. That line is not content; a real blank line still remains.
  private static func linesOf(_ source: String) -> [String] {
    let normalized =
      source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var lines = normalized.components(separatedBy: "\n")
    if normalized.hasSuffix("\n"), lines.last?.isEmpty == true {
      lines.removeLast()
    }
    return lines
  }

  static func tableCells(_ line: String) -> [String] {
    var body = line.trimmingCharacters(in: .whitespaces)
    if body.hasPrefix("|"), !body.hasPrefix("\\|") { body.removeFirst() }
    if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }

    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in body {
      if escaped {
        if character == "|" || character == "\\" {
          current.append(character)
        } else {
          current.append("\\")
          current.append(character)
        }
        escaped = false
        continue
      }
      if character == "\\" {
        escaped = true
        continue
      }
      if character == "|" {
        cells.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
        continue
      }
      current.append(character)
    }
    if escaped { current.append("\\") }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
  }

  static func isTableSeparator(_ line: String) -> Bool {
    let cells = tableCells(line)
    guard !cells.isEmpty, cells.contains(where: { $0.contains("-") }) else { return false }
    return cells.allSatisfy { cell in
      !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
    }
  }

  static func normalizedTable(
    header: [String], rows: [[String]]
  ) -> (header: [String], rows: [[String]], columnCount: Int) {
    let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
    func pad(_ row: [String]) -> [String] {
      guard row.count < columnCount else { return row }
      return row + Array(repeating: "", count: columnCount - row.count)
    }
    guard columnCount > 0 else { return ([], [], 0) }
    return (pad(header), rows.map(pad), columnCount)
  }

  static func columnWeights(header: [String], rows: [[String]], count: Int) -> [CGFloat] {
    guard count > 0 else { return [] }
    var weights = [CGFloat](repeating: 1, count: count)
    func consider(_ row: [String]) {
      for column in 0..<count where column < row.count {
        weights[column] = max(weights[column], CGFloat(row[column].count))
      }
    }
    consider(header)
    rows.forEach(consider)
    return weights.map { min(max($0, 3), 48) }
  }

  private static func text(_ source: String) -> AskMarkdownText {
    AskMarkdownText(source: source, inlines: AskMarkdownInlineParser.parse(source))
  }

  private static func quoteBlock(_ raw: String) -> AskMarkdownBlock {
    if let callout = AskCalloutKind.detect(raw) {
      return .callout(
        callout.kind, text(callout.body), children: blocks(from: callout.body))
    }
    return .blockquote(text(raw), children: blocks(from: raw))
  }

  private static func headingBlock(_ line: String) -> AskMarkdownBlock? {
    var level = 0
    var index = line.startIndex
    while index < line.endIndex, line[index] == "#", level < 6 {
      level += 1
      index = line.index(after: index)
    }
    guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
    let body = String(line[index...]).trimmingCharacters(in: .whitespaces)
    return .heading(level: level, text(body))
  }

  private static func listBlock(_ line: String) -> AskMarkdownBlock? {
    let leading = line.prefix { $0 == " " }.count
    let indent = leading / 2
    let content = line.drop { $0 == " " }
    if let first = content.first, "-*+".contains(first) {
      let after = content.dropFirst()
      if after.first == " " {
        let body = String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
        if let task = taskBlock(indent: indent, body: body) { return task }
        return .bullet(indent: indent, text(body))
      }
    }
    let digits = content.prefix { $0.isNumber }
    if !digits.isEmpty {
      let rest = content.dropFirst(digits.count)
      if rest.first == ".", rest.dropFirst().first == " " {
        let body = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return .ordered(indent: indent, number: Int(digits) ?? 1, text(body))
      }
    }
    return nil
  }

  private static func taskBlock(indent: Int, body: String) -> AskMarkdownBlock? {
    guard body.hasPrefix("[") else { return nil }
    let inner = body.dropFirst()
    guard let mark = inner.first, inner.dropFirst().first == "]" else { return nil }
    let rest = inner.dropFirst(2)
    guard rest.isEmpty || rest.first == " " else { return nil }
    let done: Bool
    switch mark {
    case "x", "X": done = true
    case " ": done = false
    default: return nil
    }
    return .task(
      indent: indent, done: done, text(String(rest).trimmingCharacters(in: .whitespaces)))
  }

  private static func stripQuoteMarker(_ line: String) -> String {
    var slice = Substring(line)
    if slice.first == ">" { slice = slice.dropFirst() }
    if slice.first == " " { slice = slice.dropFirst() }
    return String(slice)
  }

  /// An opening fence is at least three backticks. The info string cannot
  /// contain a backtick, so an inline code span is not read as a fence. A
  /// longer fence can contain a shorter one verbatim.
  private static func openingFence(_ line: String) -> (ticks: Int, language: String?)? {
    let ticks = line.prefix { $0 == "`" }.count
    guard ticks >= 3 else { return nil }
    let info = line.dropFirst(ticks)
    guard !info.contains("`") else { return nil }
    let language = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    return (ticks, language?.isEmpty == true ? nil : language)
  }

  private static func closingFence(_ line: String) -> Int? {
    let ticks = line.prefix { $0 == "`" }.count
    guard ticks >= 3 else { return nil }
    return line.dropFirst(ticks).allSatisfy { $0 == " " } ? ticks : nil
  }

  private static func isThematicBreak(_ line: String) -> Bool {
    let core = line.filter { $0 != " " && $0 != "\t" }
    guard core.count >= 3, let first = core.first, "-*_".contains(first) else { return false }
    return core.allSatisfy { $0 == first }
  }
}

extension AskCalloutKind {
  static func detect(_ raw: String) -> (kind: AskCalloutKind, body: String)? {
    let lines = raw.components(separatedBy: "\n")
    guard let head = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    else { return nil }
    let first = lines[head].trimmingCharacters(in: .whitespaces)
    guard first.hasPrefix("[!"), let close = first.firstIndex(of: "]") else { return nil }
    let tag = String(first[first.index(first.startIndex, offsetBy: 2)..<close]).uppercased()
    guard let kind = AskCalloutKind(rawValue: tag) else { return nil }
    let trailing = String(first[first.index(after: close)...])
      .trimmingCharacters(in: .whitespaces)
    var body = head + 1 <= lines.count - 1 ? Array(lines[(head + 1)...]) : []
    if !trailing.isEmpty { body.insert(trailing, at: 0) }
    return (kind, body.joined(separator: "\n"))
  }
}

enum AskMarkdownInlineParser {
  static func parse(_ text: String) -> [AskMarkdownInline] {
    var runs: [AskMarkdownInline] = []
    var buffer = ""
    let chars = Array(text)
    var index = 0

    func flush() {
      guard !buffer.isEmpty else { return }
      runs.append(.text(buffer))
      buffer = ""
    }

    while index < chars.count {
      if chars[index] == "`" {
        var ticks = 0
        var cursor = index
        while cursor < chars.count, chars[cursor] == "`" {
          ticks += 1
          cursor += 1
        }
        if let close = closingRun(chars, from: cursor, ticks: ticks) {
          flush()
          runs.append(.code(String(chars[cursor..<close])))
          index = close + ticks
          continue
        }
        buffer += String(repeating: "`", count: ticks)
        index = cursor
        continue
      }

      if chars[index] == "[", let link = linkAt(chars, from: index) {
        flush()
        runs.append(.link(label: link.label, url: link.url))
        index = link.next
        continue
      }

      if chars[index] == "*", index + 1 < chars.count, chars[index + 1] == "*",
        let end = delimiter(chars, from: index + 2, token: "*")
      {
        let after = end + 1
        if after < chars.count, chars[after] == "*" {
          flush()
          runs.append(.strong(String(chars[(index + 2)..<end])))
          index = after + 1
          continue
        }
      }

      if chars[index] == "*",
        let end = delimiter(chars, from: index + 1, token: "*"),
        end > index + 1,
        chars[end - 1] != "*"
      {
        flush()
        runs.append(.emphasis(String(chars[(index + 1)..<end])))
        index = end + 1
        continue
      }

      buffer.append(chars[index])
      index += 1
    }
    flush()
    return runs
  }

  private static func closingRun(_ chars: [Character], from start: Int, ticks: Int) -> Int? {
    var index = start
    while index < chars.count {
      if chars[index] == "`" {
        var run = 0
        var cursor = index
        while cursor < chars.count, chars[cursor] == "`" {
          run += 1
          cursor += 1
        }
        if run == ticks { return index }
        index = cursor
        continue
      }
      index += 1
    }
    return nil
  }

  private static func linkAt(
    _ chars: [Character], from start: Int
  ) -> (label: String, url: String, next: Int)? {
    guard let labelEnd = chars[start...].firstIndex(of: "]"), labelEnd > start else { return nil }
    let urlStart = labelEnd + 1
    guard urlStart < chars.count, chars[urlStart] == "(" else { return nil }
    guard let urlEnd = chars[(urlStart + 1)...].firstIndex(of: ")"), urlEnd > urlStart + 1 else {
      return nil
    }
    let label = String(chars[(start + 1)..<labelEnd])
    let url = String(chars[(urlStart + 1)..<urlEnd])
    guard !label.isEmpty, !url.isEmpty, !url.contains(where: \.isWhitespace) else { return nil }
    return (label, url, urlEnd + 1)
  }

  private static func delimiter(_ chars: [Character], from start: Int, token: Character) -> Int? {
    guard start < chars.count else { return nil }
    var index = start
    while index < chars.count {
      if chars[index] == token { return index }
      index += 1
    }
    return nil
  }
}

/// Prose wraps inside the message. Wide tables and code keep their content
/// width and scroll inside that same width, so a long row cannot push the
/// surrounding prose past the viewport.
struct AskMarkdownOverflow: Equatable, Sendable {
  static let minColumn: CGFloat = 46
  static let monoAdvance: CGFloat = 7.2
  static let proseComfortCap: CGFloat = 920

  var containerWidth: CGFloat
  var proseWidth: CGFloat
  var codeViewportWidth: CGFloat
  var tableViewportWidth: CGFloat
  var tableContentWidth: CGFloat
  var codeContentWidth: CGFloat

  var proseStaysInsideContainer: Bool {
    proseWidth <= containerWidth + 0.001
  }

  var wideContentScrollsInsideMessage: Bool {
    codeViewportWidth <= proseWidth + 0.001
      && tableViewportWidth <= proseWidth + 0.001
      && proseWidth <= containerWidth + 0.001
  }

  static func plan(
    containerWidth: CGFloat,
    codeCharacters: Int,
    tableColumns: Int,
    proseCap: CGFloat? = proseComfortCap
  ) -> AskMarkdownOverflow {
    let container = max(0, containerWidth)
    let column: CGFloat
    if container == 0 {
      column = 0
    } else if let proseCap {
      column = min(container, proseCap)
    } else {
      column = container
    }
    let tableContent = max(column, CGFloat(max(tableColumns, 0)) * minColumn)
    let codeContent = max(column, CGFloat(max(codeCharacters, 0)) * monoAdvance)
    return AskMarkdownOverflow(
      containerWidth: container,
      proseWidth: column,
      codeViewportWidth: column,
      tableViewportWidth: column,
      tableContentWidth: tableContent,
      codeContentWidth: codeContent)
  }
}

struct AskStreamPublication: Equatable, Sendable {
  var text: String
  var generation: UInt64
  var isFinal: Bool
  var time: TimeInterval
}

/// Coalesces a growing turn to at most ten publications a second. The closing
/// sample flushes immediately. A generation older than the newest accepted
/// sample is refused and cannot replace the newer text.
///
/// `publications` is a diagnostic ring, not a transcript. Keeping every
/// growing snapshot would retain quadratic bytes for a long reply. The newest
/// full text stays on the turn; older snapshots fall out of the ring.
struct AskMarkdownStreamScheduler: Equatable, Sendable {
  static let minimumInterval: TimeInterval = 0.1
  static let maxPublicationsPerSecond = 10
  static let retainedPublicationLimit = 12

  private(set) var acceptedGeneration: UInt64 = 0
  private(set) var hasGeneration = false
  private(set) var lastPublishedAt: TimeInterval?
  private var pendingText: String?
  private var pendingGeneration: UInt64 = 0
  private(set) var publications: [AskStreamPublication] = []

  var pending: String? { pendingText }

  var retainedPublicationUTF8: Int {
    publications.reduce(0) { $0 + $1.text.utf8.count }
  }

  mutating func ingest(
    text: String, generation: UInt64, at time: TimeInterval, isFinal: Bool
  ) -> AskStreamPublication? {
    if hasGeneration, generation < acceptedGeneration { return nil }
    hasGeneration = true
    acceptedGeneration = generation
    if isFinal {
      pendingText = nil
      return publish(text: text, generation: generation, at: time, isFinal: true)
    }
    if let lastPublishedAt, time - lastPublishedAt < Self.minimumInterval {
      pendingText = text
      pendingGeneration = generation
      return nil
    }
    pendingText = nil
    return publish(text: text, generation: generation, at: time, isFinal: false)
  }

  /// Publishes the newest sample held inside the coalesce window once the
  /// interval has elapsed, when no newer ingest arrived to carry it.
  mutating func advance(to time: TimeInterval) -> AskStreamPublication? {
    guard let pendingText, let lastPublishedAt, time - lastPublishedAt >= Self.minimumInterval
    else { return nil }
    let generation = pendingGeneration
    let text = pendingText
    self.pendingText = nil
    return publish(text: text, generation: generation, at: time, isFinal: false)
  }

  private mutating func publish(
    text: String, generation: UInt64, at time: TimeInterval, isFinal: Bool
  ) -> AskStreamPublication {
    lastPublishedAt = time
    let publication = AskStreamPublication(
      text: text, generation: generation, isFinal: isFinal, time: time)
    publications.append(publication)
    if publications.count > Self.retainedPublicationLimit {
      publications.removeFirst(publications.count - Self.retainedPublicationLimit)
    }
    return publication
  }
}

/// One finished document per turn. Repeating that same source does not parse
/// again. A newer generation makes an older in-flight result stale; storing
/// it does not parse and does not replace the current document.
///
/// Earlier revisions of a growing reply are not kept. A short ring of byte
/// counts is the only per-turn history, so a long stream cannot accumulate
/// every prefix.
struct AskMarkdownCache: Equatable, Sendable {
  struct RevisionSample: Equatable, Sendable {
    var generation: UInt64
    var utf8Count: Int
  }

  static let revisionSampleLimit = 8

  private var current: [String: AskMarkdownDocument] = [:]
  private var latestGeneration: [String: UInt64] = [:]
  private var parses: [String: Int] = [:]
  private var samples: [String: [RevisionSample]] = [:]

  func parseCount(for id: String) -> Int { parses[id] ?? 0 }

  func document(id: String) -> AskMarkdownDocument? { current[id] }

  func revisionSamples(for id: String) -> [RevisionSample] { samples[id] ?? [] }

  /// UTF-8 bytes of markdown sources still held. Each turn contributes its
  /// newest finished source only.
  var retainedSourceUTF8: Int {
    current.values.reduce(0) { $0 + $1.source.utf8.count }
  }

  mutating func observe(id: String, generation: UInt64) {
    if generation >= (latestGeneration[id] ?? 0) {
      latestGeneration[id] = generation
    }
  }

  mutating func finish(
    id: String, source: String, generation: UInt64
  ) -> AskMarkdownDocument? {
    guard latestGeneration[id] == generation else { return nil }
    let document: AskMarkdownDocument
    if let cached = current[id], cached.source == source {
      document = cached
    } else {
      document = AskMarkdownParser.parse(source)
      current[id] = document
      parses[id, default: 0] += 1
    }
    var ring = samples[id] ?? []
    ring.append(RevisionSample(generation: generation, utf8Count: source.utf8.count))
    if ring.count > Self.revisionSampleLimit {
      ring.removeFirst(ring.count - Self.revisionSampleLimit)
    }
    samples[id] = ring
    return document
  }
}
