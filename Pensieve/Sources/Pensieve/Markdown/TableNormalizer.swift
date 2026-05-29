import Foundation

enum TableNormalizer {
  private static let ansiPattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
  private static let ansiRegex = try! NSRegularExpression(pattern: ansiPattern)

  private static let boxScalarValues: Set<UInt32> = [
    0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C,
    0x2500, 0x2550, 0x2554, 0x2557, 0x255A, 0x255D, 0x2560, 0x2563, 0x2566,
    0x2569, 0x256C, 0x250F, 0x2513, 0x2517, 0x251B, 0x251D, 0x2525, 0x2533,
    0x253B, 0x256D, 0x256E, 0x2570, 0x256F, 0x2502, 0x2503, 0x2551,
  ]

  private static let borderScalarValues: Set<UInt32> = boxScalarValues.union([
    0x007C, 0x002B, 0x002D, 0x003D, 0x003A,
  ])

  private static let unicodeReplacements: [(String, String)] = [
    ("\u{2325}", "Option"),
    ("\u{2318}", "Cmd"),
    ("\u{21E7}", "Shift"),
    ("\u{2303}", "Ctrl"),
    ("\u{232B}", "Backspace"),
    ("\u{238B}", "Esc"),
    ("\u{21E5}", "Tab"),
    ("\u{21A9}", "Enter"),
    ("\u{2192}", "->"),
    ("\u{2190}", "<-"),
    ("\u{2191}", "^"),
    ("\u{2193}", "v"),
    ("\u{2713}", "[x]"),
    ("\u{2717}", "[ ]"),
    ("\u{2022}", "*"),
    ("\u{2026}", "..."),
    ("\u{2014}", "--"),
    ("\u{2013}", "-"),
    ("\u{201C}", "\""),
    ("\u{201D}", "\""),
    ("\u{2018}", "'"),
    ("\u{2019}", "'"),
  ]

  static func normalize(_ text: String, asciiSafe: Bool = false) -> String {
    let text = normalizeNewlines(text)
    let lines = text.components(separatedBy: "\n")
    var output: [String] = []
    var buffer: [String] = []

    func flushBuffer() {
      guard !buffer.isEmpty else { return }
      if let markdown = tableToMarkdown(buffer) {
        output.append(markdown)
      } else {
        output.append(contentsOf: buffer)
      }
      buffer.removeAll()
    }

    for line in lines {
      if looksLikeTableRow(line) {
        buffer.append(line)
      } else {
        flushBuffer()
        output.append(line)
      }
    }
    flushBuffer()

    let normalized = output.joined(separator: "\n")
    return asciiSafe ? makeASCIISafe(normalized) : normalized
  }

  static func containsTableSmell(_ text: String) -> Bool {
    normalizeNewlines(text)
      .components(separatedBy: "\n")
      .contains(where: looksLikeTableRow)
  }

  private static func stripANSI(_ string: String) -> String {
    let range = NSRange(location: 0, length: (string as NSString).length)
    return ansiRegex.stringByReplacingMatches(
      in: string,
      options: [],
      range: range,
      withTemplate: ""
    )
  }

  private static func normalizeNewlines(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\u{2028}", with: "\n")
      .replacingOccurrences(of: "\u{2029}", with: "\n")
  }

  private static func makeASCIISafe(_ text: String) -> String {
    unicodeReplacements.reduce(text) { partial, replacement in
      partial.replacingOccurrences(of: replacement.0, with: replacement.1)
    }
  }

  private static func normalizePipes(_ line: String) -> String {
    line
      .replacingOccurrences(of: "\u{2502}", with: "|")
      .replacingOccurrences(of: "\u{2503}", with: "|")
      .replacingOccurrences(of: "\u{2551}", with: "|")
      .replacingOccurrences(of: "\u{00A6}", with: "|")
  }

  private static func looksLikeBorderLine(_ line: String) -> Bool {
    let stripped = normalizePipes(stripANSI(line)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stripped.isEmpty else { return false }

    if stripped.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
      return false
    }

    return stripped.unicodeScalars.allSatisfy { scalar in
      CharacterSet.whitespacesAndNewlines.contains(scalar)
        || borderScalarValues.contains(scalar.value)
    }
  }

  private static func looksLikeTableRow(_ line: String) -> Bool {
    let stripped = stripANSI(line)
    if stripped.unicodeScalars.contains(where: { boxScalarValues.contains($0.value) }) {
      return true
    }

    let pipeNormalized = normalizePipes(stripped)
    let trimmed = pipeNormalized.trimmingCharacters(in: .whitespacesAndNewlines)

    if isASCIIBorder(trimmed) {
      return true
    }

    let pipeCount = trimmed.reduce(0) { count, character in
      count + (character == "|" ? 1 : 0)
    }
    return pipeCount >= 3 && (trimmed.hasPrefix("|") || trimmed.hasSuffix("|"))
  }

  private static func isASCIIBorder(_ line: String) -> Bool {
    guard line.hasPrefix("+"), line.hasSuffix("+"), line.count >= 3 else { return false }
    let inner = line.dropFirst().dropLast()
    return !inner.isEmpty
      && inner.allSatisfy { character in
        character == "-" || character == "=" || character == "+"
      }
  }

  private static func parseRowCells(_ line: String) -> [String]? {
    let normalized = normalizePipes(stripANSI(line))
    guard normalized.contains("|") else { return nil }

    var parts =
      normalized
      .split(separator: "|", omittingEmptySubsequences: false)
      .map(String.init)

    if parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
      parts.removeFirst()
    }
    if parts.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
      parts.removeLast()
    }

    let cells = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return cells.isEmpty ? nil : cells
  }

  private static func isContinuationLine(_ cells: [String]) -> Bool {
    guard cells.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else {
      return false
    }
    return cells.dropFirst().contains {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private static func mergeCells(_ base: [String], _ continuation: [String]) -> [String] {
    var merged = base
    for (index, content) in continuation.enumerated() where index < merged.count && !content.isEmpty
    {
      merged[index] = merged[index].isEmpty ? content : "\(merged[index]) \(content)"
    }
    return merged
  }

  private static func tableToMarkdown(_ tableLines: [String]) -> String? {
    var data: [[String]] = []
    for line in tableLines {
      if looksLikeBorderLine(line) {
        continue
      }
      if let cells = parseRowCells(line) {
        data.append(cells)
      }
    }

    guard !data.isEmpty else { return nil }

    var rows: [[String]] = []
    var current: [String]?
    for cells in data {
      if isContinuationLine(cells), let existing = current {
        current = mergeCells(existing, cells)
      } else {
        if let existing = current {
          rows.append(existing)
        }
        current = cells
      }
    }
    if let current {
      rows.append(current)
    }

    guard rows.count >= 2 else { return nil }

    let widths = rows.map(\.count)
    let commonWidth = mostCommonWidth(in: widths)
    let matchingRows = widths.filter { $0 == commonWidth }.count
    guard matchingRows >= max(2, Int(0.7 * Double(rows.count))) else {
      return nil
    }

    let normalizedRows = rows.map { row in
      let padded =
        Array(row.prefix(commonWidth))
        + Array(repeating: "", count: max(0, commonWidth - row.count))
      return padded.map(collapseWhitespace)
    }

    var markdown: [String] = []
    markdown.append("| " + normalizedRows[0].joined(separator: " | ") + " |")
    markdown.append("|" + Array(repeating: "---", count: commonWidth).joined(separator: "|") + "|")
    markdown.append(
      contentsOf: normalizedRows.dropFirst().map { row in
        "| " + row.joined(separator: " | ") + " |"
      }
    )
    return markdown.joined(separator: "\n")
  }

  private static func mostCommonWidth(in widths: [Int]) -> Int {
    var counts: [Int: Int] = [:]
    var best = widths[0]
    for width in widths {
      counts[width, default: 0] += 1
      if counts[width, default: 0] > counts[best, default: 0] {
        best = width
      }
    }
    return best
  }

  private static func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
