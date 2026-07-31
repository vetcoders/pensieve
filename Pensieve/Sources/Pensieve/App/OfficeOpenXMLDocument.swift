import AppKit
import zlib

enum OfficeOpenXMLDocument {
  enum Error: Swift.Error {
    case invalidArchive
    case invalidDocument
    case partTooLarge
    case unsupportedCompression(UInt16)
  }

  static func write(_ attributed: NSAttributedString) throws -> Data {
    let writer = WordDocumentWriter(attributed: attributed)
    return ZipArchive.write(entries: writer.entries())
  }

  /// Read one package part out of a written archive. Lets callers — tests and
  /// diagnostics — assert on the emitted OOXML instead of only on round-tripped
  /// markdown, which hides layout geometry entirely.
  static func part(named name: String, in data: Data) throws -> Data? {
    try ZipArchive(data: data).data(for: name)
  }

  static func readMarkdown(_ data: Data) throws -> String {
    let archive = try ZipArchive(data: data)
    guard let documentXML = try archive.data(for: "word/document.xml") else {
      throw Error.invalidDocument
    }

    let relationships =
      try archive.data(for: "word/_rels/document.xml.rels")
      .map(RelationshipsParser.parse) ?? [:]
    let numbering =
      try archive.data(for: "word/numbering.xml")
      .map(NumberingParser.parse) ?? [:]
    return try WordDocumentParser.parse(
      documentXML,
      relationships: relationships,
      numberingFormats: numbering
    )
  }
}

private struct WordRun {
  var text: String
  var isBold: Bool
  var isItalic: Bool
  var pointSize: CGFloat
  var hyperlink: String?
}

private struct WordParagraph {
  enum Kind {
    case body
    case heading(Int)
    case bullet
    case ordered
  }

  var kind: Kind
  var runs: [WordRun]
}

private struct WordDocumentWriter {
  let attributed: NSAttributedString

  func entries() -> [(name: String, data: Data)] {
    let paragraphs = makeParagraphs()
    var hyperlinks: [String: String] = [:]
    var nextHyperlinkID = 3

    let body = paragraphs.map { paragraph -> String in
      let paragraphProperties: String
      switch paragraph.kind {
      case .body:
        paragraphProperties = ""
      case .heading(let level):
        paragraphProperties = "<w:pPr><w:pStyle w:val=\"Heading\(level)\"/></w:pPr>"
      case .bullet:
        paragraphProperties =
          "<w:pPr><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr>"
      case .ordered:
        paragraphProperties =
          "<w:pPr><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"2\"/></w:numPr></w:pPr>"
      }

      let runs = paragraph.runs.map { run -> String in
        var properties: [String] = []
        if run.isBold { properties.append("<w:b/>") }
        if run.isItalic { properties.append("<w:i/>") }
        if run.pointSize > 0 {
          properties.append("<w:sz w:val=\"\(Int((run.pointSize * 2).rounded()))\"/>")
        }
        let runProperties = properties.isEmpty ? "" : "<w:rPr>\(properties.joined())</w:rPr>"
        let text =
          "<w:r>\(runProperties)<w:t xml:space=\"preserve\">\(xmlEscaped(run.text))</w:t></w:r>"

        guard let target = run.hyperlink else { return text }
        let relationshipID: String
        if let existing = hyperlinks[target] {
          relationshipID = existing
        } else {
          relationshipID = "rId\(nextHyperlinkID)"
          nextHyperlinkID += 1
          hyperlinks[target] = relationshipID
        }
        return "<w:hyperlink r:id=\"\(relationshipID)\" w:history=\"1\">\(text)</w:hyperlink>"
      }.joined()

      return "<w:p>\(paragraphProperties)\(runs)</w:p>"
    }.joined()

    let document = xmlData(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body>
      </w:document>
      """
    )

    let hyperlinkRelationships =
      hyperlinks
      .sorted { $0.value < $1.value }
      .map { target, relationshipID in
        "<Relationship Id=\"\(relationshipID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xmlAttributeEscaped(target))\" TargetMode=\"External\"/>"
      }
      .joined()
    let documentRelationships = xmlData(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        \(hyperlinkRelationships)
      </Relationships>
      """
    )

    return [
      ("[Content_Types].xml", Self.contentTypes),
      ("_rels/.rels", Self.rootRelationships),
      ("word/document.xml", document),
      ("word/_rels/document.xml.rels", documentRelationships),
      ("word/styles.xml", Self.styles),
      ("word/numbering.xml", Self.numbering),
    ]
  }

  private func makeParagraphs() -> [WordParagraph] {
    let source = attributed.string as NSString
    guard source.length > 0 else { return [] }

    let baseSize = bodyPointSize()
    var result: [WordParagraph] = []
    var cursor = 0
    while cursor < source.length {
      var start = 0
      var end = 0
      var contentsEnd = 0
      source.getParagraphStart(
        &start,
        end: &end,
        contentsEnd: &contentsEnd,
        for: NSRange(location: cursor, length: 0)
      )
      let range = NSRange(location: start, length: contentsEnd - start)
      result.append(makeParagraph(range: range, baseSize: baseSize))
      cursor = max(end, cursor + 1)
    }
    return result
  }

  /// The document's running-text point size: the size covering the most
  /// characters, smaller size winning a tie. Heading detection is relative to
  /// this because the preview's base size is a user setting — absolute
  /// thresholds classified ordinary 16pt body text as a heading.
  private func bodyPointSize() -> CGFloat {
    var histogram: [CGFloat: Int] = [:]
    attributed.enumerateAttribute(
      .font,
      in: NSRange(location: 0, length: attributed.length)
    ) { value, range, _ in
      guard let font = value as? NSFont, font.pointSize > 0 else { return }
      histogram[font.pointSize.rounded(), default: 0] += range.length
    }
    return
      histogram
      .max { lhs, rhs in
        lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
      }?.key ?? 12
  }

  private func makeParagraph(range: NSRange, baseSize: CGFloat) -> WordParagraph {
    guard range.length > 0 else { return WordParagraph(kind: .body, runs: []) }
    let style =
      attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
      as? NSParagraphStyle
    let isList = style?.textLists.isEmpty == false
    let contentRange = isList ? rangeAfterListMarker(range) : range

    let kind: WordParagraph.Kind
    if isList {
      let format = String(describing: style?.textLists.last?.markerFormat).lowercased()
      kind =
        ["decimal", "roman", "alpha", "latin"].contains(where: format.contains)
        ? .ordered : .bullet
    } else {
      kind = headingLevel(range, baseSize: baseSize).map(WordParagraph.Kind.heading) ?? .body
    }

    var runs: [WordRun] = []
    attributed.enumerateAttributes(in: contentRange) { attributes, runRange, _ in
      let text = (attributed.string as NSString).substring(with: runRange)
      guard !text.isEmpty else { return }
      let font = attributes[.font] as? NSFont
      let traits = font?.fontDescriptor.symbolicTraits ?? []
      let hyperlink: String?
      if let url = attributes[.link] as? URL {
        hyperlink = url.absoluteString
      } else if let link = attributes[.link] {
        hyperlink = String(describing: link)
      } else {
        hyperlink = nil
      }
      runs.append(
        WordRun(
          text: text.replacingOccurrences(of: "\t", with: " "),
          isBold: traits.contains(.bold),
          isItalic: traits.contains(.italic),
          pointSize: font?.pointSize ?? 0,
          hyperlink: hyperlink
        )
      )
    }
    return WordParagraph(kind: kind, runs: runs)
  }

  private func rangeAfterListMarker(_ range: NSRange) -> NSRange {
    let raw = (attributed.string as NSString).substring(with: range)
    guard
      // AppKit's HTML importer writes an ordered marker as "\t1\t" — no
      // punctuation — so the `\d+[.)]` branch missed it and the numeral was
      // exported as body text *next to* the numbering Word renders itself
      // ("1. 1 First item"). Accept a tab-delimited numeral too.
      let regex = try? NSRegularExpression(pattern: #"^\s*(?:[•◦▪‣]\s*|\d+[.)]\s*|\d+\t\s*)"#),
      let match = regex.firstMatch(
        in: raw,
        range: NSRange(location: 0, length: (raw as NSString).length)
      )
    else { return range }
    return NSRange(
      location: range.location + match.range.length,
      length: max(0, range.length - match.range.length)
    )
  }

  /// A heading is set entirely in bold and larger than the running text.
  /// Requiring *every* run to be bold matters: a body paragraph containing one
  /// bold phrase used to satisfy the old "any run is bold" test and shipped as
  /// a Heading3, so whole paragraphs arrived in Word as bold headings.
  private func headingLevel(_ range: NSRange, baseSize: CGFloat) -> Int? {
    var size: CGFloat = 0
    var sawFont = false
    var allBold = true
    attributed.enumerateAttribute(.font, in: range) { value, _, _ in
      guard let font = value as? NSFont else { return }
      sawFont = true
      size = max(size, font.pointSize)
      allBold = allBold && font.fontDescriptor.symbolicTraits.contains(.bold)
    }
    guard sawFont, allBold, baseSize > 0 else { return nil }

    let ratio = size / baseSize
    if ratio >= 1.8 { return 1 }
    if ratio >= 1.4 { return 2 }
    if ratio >= 1.12 { return 3 }
    return nil
  }

  private static let contentTypes = xmlData(
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
      <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
    </Types>
    """
  )

  private static let rootRelationships = xmlData(
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """
  )

  private static let styles = xmlData(
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
    </w:styles>
    """
  )

  // Every `w:lvl` MUST carry `w:pPr/w:ind`. A level without it leaves the list
  // paragraph's text indent undefined, and consumers (reproduced in Pages,
  // which is the default .docx handler on a Mac without Office) resolve it to
  // roughly the full text column — every list paragraph then collapses into a
  // two-character sliver hugging the right margin and drags the rest of the
  // document across dozens of near-empty pages. `w:lvlJc` alone does not fix
  // it; the indent is the load-bearing part.
  private static let numbering = xmlData(
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
      <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
      <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
      <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """
  )
}

private final class WordDocumentParser: NSObject, XMLParserDelegate {
  private let relationships: [String: String]
  private let numberingFormats: [String: String]
  private var paragraphs: [WordParagraph] = []
  private var paragraph: WordParagraph?
  private var run: WordRun?
  private var hyperlinkID: String?
  private var isReadingText = false

  init(relationships: [String: String], numberingFormats: [String: String]) {
    self.relationships = relationships
    self.numberingFormats = numberingFormats
  }

  static func parse(
    _ data: Data,
    relationships: [String: String],
    numberingFormats: [String: String]
  ) throws -> String {
    let delegate = WordDocumentParser(
      relationships: relationships,
      numberingFormats: numberingFormats
    )
    let parser = try safeXMLParser(data)
    parser.delegate = delegate
    guard parser.parse() else { throw OfficeOpenXMLDocument.Error.invalidDocument }
    return delegate.markdown()
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let name = localName(elementName)
    switch name {
    case "p":
      paragraph = WordParagraph(kind: .body, runs: [])
    case "pStyle":
      guard let value = namespacedValue("val", in: attributeDict),
        value.lowercased().hasPrefix("heading"),
        let level = Int(value.filter(\.isNumber))
      else { return }
      paragraph?.kind = .heading(min(max(level, 1), 6))
    case "numId":
      guard let value = namespacedValue("val", in: attributeDict) else { return }
      paragraph?.kind = numberingFormats[value] == "bullet" ? .bullet : .ordered
    case "hyperlink":
      hyperlinkID = namespacedValue("id", in: attributeDict)
    case "r":
      run = WordRun(
        text: "", isBold: false, isItalic: false, pointSize: 0,
        hyperlink: hyperlinkID.flatMap { relationships[$0] })
    case "b":
      run?.isBold = namespacedValue("val", in: attributeDict) != "0"
    case "i":
      run?.isItalic = namespacedValue("val", in: attributeDict) != "0"
    case "sz":
      if let value = namespacedValue("val", in: attributeDict), let halfPoints = Double(value) {
        run?.pointSize = CGFloat(halfPoints / 2)
      }
    case "t":
      isReadingText = true
    case "tab":
      run?.text += "\t"
    case "br", "cr":
      run?.text += "\n"
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if isReadingText { run?.text += string }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    switch localName(elementName) {
    case "t":
      isReadingText = false
    case "r":
      if let run, !run.text.isEmpty { paragraph?.runs.append(run) }
      run = nil
    case "hyperlink":
      hyperlinkID = nil
    case "p":
      if let paragraph { paragraphs.append(paragraph) }
      paragraph = nil
    default:
      break
    }
  }

  private func markdown() -> String {
    var lines: [String] = []
    var previousWasList = false
    for paragraph in paragraphs {
      let isHeading: Bool
      let prefix: String
      let isList: Bool
      switch paragraph.kind {
      case .body:
        prefix = ""
        isHeading = false
        isList = false
      case .heading(let level):
        prefix = String(repeating: "#", count: level) + " "
        isHeading = true
        isList = false
      case .bullet:
        prefix = "- "
        isHeading = false
        isList = true
      case .ordered:
        prefix = "1. "
        isHeading = false
        isList = true
      }

      let content = paragraph.runs.map { run in
        markdown(run: run, suppressEmphasis: isHeading)
      }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

      guard !content.isEmpty else {
        if lines.last?.isEmpty == false { lines.append("") }
        previousWasList = false
        continue
      }
      if !lines.isEmpty, lines.last?.isEmpty == false, !(previousWasList && isList) {
        lines.append("")
      }
      lines.append(prefix + content)
      previousWasList = isList
    }

    while lines.first?.isEmpty == true { lines.removeFirst() }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }

  private func markdown(run: WordRun, suppressEmphasis: Bool) -> String {
    let leading = run.text.prefix(while: \.isWhitespace)
    let afterLeading = run.text.dropFirst(leading.count)
    let trailing = afterLeading.reversed().prefix(while: \.isWhitespace).reversed()
    let core = afterLeading.dropLast(trailing.count)
    guard !core.isEmpty else { return run.text }

    var rendered = markdownEscaped(String(core))
    if let target = run.hyperlink {
      rendered = "[\(rendered)](\(target))"
    }
    if !suppressEmphasis {
      if run.isBold && run.isItalic {
        rendered = "***\(rendered)***"
      } else if run.isBold {
        rendered = "**\(rendered)**"
      } else if run.isItalic {
        rendered = "*\(rendered)*"
      }
    }
    return String(leading) + rendered + String(trailing)
  }
}

private final class RelationshipsParser: NSObject, XMLParserDelegate {
  private(set) var relationships: [String: String] = [:]

  static func parse(_ data: Data) throws -> [String: String] {
    let delegate = RelationshipsParser()
    let parser = try safeXMLParser(data)
    parser.delegate = delegate
    guard parser.parse() else { throw OfficeOpenXMLDocument.Error.invalidDocument }
    return delegate.relationships
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    guard localName(elementName) == "Relationship",
      attributeDict["Type"]?.hasSuffix("/hyperlink") == true,
      let id = attributeDict["Id"],
      let target = attributeDict["Target"]
    else { return }
    relationships[id] = target
  }
}

private final class NumberingParser: NSObject, XMLParserDelegate {
  private var currentAbstractID: String?
  private var currentNumID: String?
  private var formats: [String: String] = [:]
  private var numToAbstract: [String: String] = [:]

  static func parse(_ data: Data) throws -> [String: String] {
    let delegate = NumberingParser()
    let parser = try safeXMLParser(data)
    parser.delegate = delegate
    guard parser.parse() else { throw OfficeOpenXMLDocument.Error.invalidDocument }
    return delegate.numToAbstract.reduce(into: [:]) { result, pair in
      result[pair.key] = delegate.formats[pair.value] ?? "decimal"
    }
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    switch localName(elementName) {
    case "abstractNum":
      currentAbstractID = namespacedValue("abstractNumId", in: attributeDict)
    case "numFmt":
      if let currentAbstractID, formats[currentAbstractID] == nil,
        let value = namespacedValue("val", in: attributeDict)
      {
        formats[currentAbstractID] = value
      }
    case "num":
      currentNumID = namespacedValue("numId", in: attributeDict)
    case "abstractNumId":
      if let currentNumID, let value = namespacedValue("val", in: attributeDict) {
        numToAbstract[currentNumID] = value
      }
    default:
      break
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    switch localName(elementName) {
    case "abstractNum": currentAbstractID = nil
    case "num": currentNumID = nil
    default: break
    }
  }
}

private struct ZipArchive {
  private static let maximumPartSize = 64 * 1_024 * 1_024
  private static let maximumEntryCount = 10_000

  private struct Entry {
    let flags: UInt16
    let method: UInt16
    let checksum: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
  }

  private let data: Data
  private let entries: [String: Entry]

  init(data: Data) throws {
    // ZIP offsets are relative to the first archive byte. A Data slice keeps
    // its parent's nonzero indices, so normalize once at the parser boundary
    // instead of making every range and integer read translate indices.
    let archive = Data(data)
    self.data = archive
    self.entries = try Self.readDirectory(from: archive)
  }

  func data(for name: String) throws -> Data? {
    guard let entry = entries[name] else { return nil }
    guard entry.flags & 0x0001 == 0 else {
      throw OfficeOpenXMLDocument.Error.invalidArchive
    }
    guard entry.compressedSize <= Self.maximumPartSize,
      entry.uncompressedSize <= Self.maximumPartSize
    else { throw OfficeOpenXMLDocument.Error.partTooLarge }
    let offset = entry.localHeaderOffset
    guard data.uint32(at: offset) == 0x0403_4B50,
      let nameLength = data.uint16(at: offset + 26),
      let extraLength = data.uint16(at: offset + 28)
    else { throw OfficeOpenXMLDocument.Error.invalidArchive }

    let start = offset + 30 + Int(nameLength) + Int(extraLength)
    let end = start + entry.compressedSize
    guard start >= 0, end <= data.count else {
      throw OfficeOpenXMLDocument.Error.invalidArchive
    }
    let payload = data.subdata(in: start..<end)
    let decoded: Data
    switch entry.method {
    case 0:
      guard entry.compressedSize == entry.uncompressedSize else {
        throw OfficeOpenXMLDocument.Error.invalidArchive
      }
      decoded = payload
    case 8:
      decoded = try Self.inflate(payload, uncompressedSize: entry.uncompressedSize)
    default:
      throw OfficeOpenXMLDocument.Error.unsupportedCompression(entry.method)
    }
    guard decoded.count == entry.uncompressedSize, Self.crc(decoded) == entry.checksum else {
      throw OfficeOpenXMLDocument.Error.invalidArchive
    }
    return decoded
  }

  static func write(entries: [(name: String, data: Data)]) -> Data {
    struct CentralEntry {
      let name: Data
      let checksum: UInt32
      let size: UInt32
      let offset: UInt32
    }

    var archive = Data()
    var centralEntries: [CentralEntry] = []
    for entry in entries {
      let name = Data(entry.name.utf8)
      let size = UInt32(entry.data.count)
      let checksum = crc(entry.data)
      let offset = UInt32(archive.count)

      archive.appendLE(UInt32(0x0403_4B50))
      archive.appendLE(UInt16(20))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(checksum)
      archive.appendLE(size)
      archive.appendLE(size)
      archive.appendLE(UInt16(name.count))
      archive.appendLE(UInt16(0))
      archive.append(name)
      archive.append(entry.data)
      centralEntries.append(
        CentralEntry(name: name, checksum: checksum, size: size, offset: offset))
    }

    let centralOffset = UInt32(archive.count)
    for entry in centralEntries {
      archive.appendLE(UInt32(0x0201_4B50))
      archive.appendLE(UInt16(20))
      archive.appendLE(UInt16(20))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(entry.checksum)
      archive.appendLE(entry.size)
      archive.appendLE(entry.size)
      archive.appendLE(UInt16(entry.name.count))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt32(0))
      archive.appendLE(entry.offset)
      archive.append(entry.name)
    }

    let centralSize = UInt32(archive.count) - centralOffset
    archive.appendLE(UInt32(0x0605_4B50))
    archive.appendLE(UInt16(0))
    archive.appendLE(UInt16(0))
    archive.appendLE(UInt16(centralEntries.count))
    archive.appendLE(UInt16(centralEntries.count))
    archive.appendLE(centralSize)
    archive.appendLE(centralOffset)
    archive.appendLE(UInt16(0))
    return archive
  }

  private static func readDirectory(from data: Data) throws -> [String: Entry] {
    guard data.count >= 22 else { throw OfficeOpenXMLDocument.Error.invalidArchive }
    let lowerBound = max(0, data.count - 65_557)
    guard
      let endOffset = stride(from: data.count - 22, through: lowerBound, by: -1)
        .first(where: { data.uint32(at: $0) == 0x0605_4B50 }),
      let entryCount = data.uint16(at: endOffset + 10),
      let centralOffset = data.uint32(at: endOffset + 16)
    else { throw OfficeOpenXMLDocument.Error.invalidArchive }

    guard entryCount <= maximumEntryCount else {
      throw OfficeOpenXMLDocument.Error.invalidArchive
    }
    var result: [String: Entry] = [:]
    var cursor = Int(centralOffset)
    for _ in 0..<entryCount {
      guard data.uint32(at: cursor) == 0x0201_4B50,
        let flags = data.uint16(at: cursor + 8),
        let method = data.uint16(at: cursor + 10),
        let checksum = data.uint32(at: cursor + 16),
        let compressedSize = data.uint32(at: cursor + 20),
        let uncompressedSize = data.uint32(at: cursor + 24),
        let nameLength = data.uint16(at: cursor + 28),
        let extraLength = data.uint16(at: cursor + 30),
        let commentLength = data.uint16(at: cursor + 32),
        let localOffset = data.uint32(at: cursor + 42)
      else { throw OfficeOpenXMLDocument.Error.invalidArchive }

      let nameStart = cursor + 46
      let nameEnd = nameStart + Int(nameLength)
      guard nameEnd <= data.count,
        let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8)
      else { throw OfficeOpenXMLDocument.Error.invalidArchive }
      result[name] = Entry(
        flags: flags,
        method: method,
        checksum: checksum,
        compressedSize: Int(compressedSize),
        uncompressedSize: Int(uncompressedSize),
        localHeaderOffset: Int(localOffset)
      )
      cursor = nameEnd + Int(extraLength) + Int(commentLength)
    }
    return result
  }

  private static func inflate(_ data: Data, uncompressedSize: Int) throws -> Data {
    guard uncompressedSize > 0 else { return Data() }
    var output = Data(count: uncompressedSize)
    let outputCount = output.count
    let result = data.withUnsafeBytes { inputBuffer in
      output.withUnsafeMutableBytes { outputBuffer -> (status: Int32, input: Int, output: Int) in
        guard let input = inputBuffer.bindMemory(to: Bytef.self).baseAddress,
          let destination = outputBuffer.bindMemory(to: Bytef.self).baseAddress
        else { return (Z_DATA_ERROR, 0, 0) }
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer(mutating: input)
        stream.avail_in = uInt(data.count)
        stream.next_out = destination
        stream.avail_out = uInt(outputCount)
        let initialized = inflateInit2_(
          &stream,
          -MAX_WBITS,
          ZLIB_VERSION,
          Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { return (initialized, 0, 0) }
        defer { inflateEnd(&stream) }
        let status = zlib.inflate(&stream, Z_FINISH)
        return (status, Int(stream.total_in), Int(stream.total_out))
      }
    }
    guard result.status == Z_STREAM_END,
      result.input == data.count,
      result.output == uncompressedSize
    else { throw OfficeOpenXMLDocument.Error.invalidArchive }
    return output
  }

  private static func crc(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.bindMemory(to: Bytef.self).baseAddress else { return 0 }
      return UInt32(zlib.crc32(0, baseAddress, uInt(data.count)))
    }
  }
}

private func localName(_ qualifiedName: String) -> String {
  qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName
}

private func namespacedValue(_ name: String, in attributes: [String: String]) -> String? {
  attributes[name] ?? attributes.first { localName($0.key) == name }?.value
}

private func xmlData(_ string: String) -> Data {
  Data(string.utf8)
}

private func xmlEscaped(_ string: String) -> String {
  string
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
}

private func xmlAttributeEscaped(_ string: String) -> String {
  xmlEscaped(string)
    .replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&apos;")
}

private func markdownEscaped(_ string: String) -> String {
  var escaped = string.replacingOccurrences(of: "\\", with: "\\\\")
  for character in ["`", "*", "_", "[", "]"] {
    escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
  }
  return escaped
}

private func safeXMLParser(_ data: Data) throws -> XMLParser {
  guard data.count <= 64 * 1_024 * 1_024,
    data.range(of: Data("<!DOCTYPE".utf8)) == nil,
    data.range(of: Data("<!ENTITY".utf8)) == nil
  else { throw OfficeOpenXMLDocument.Error.invalidDocument }

  let parser = XMLParser(data: data)
  parser.shouldResolveExternalEntities = false
  return parser
}

extension Data {
  fileprivate func uint16(at offset: Int) -> UInt16? {
    guard offset >= 0, offset <= count, count - offset >= 2 else { return nil }
    let start = index(startIndex, offsetBy: offset)
    return UInt16(self[start]) | (UInt16(self[index(after: start)]) << 8)
  }

  fileprivate func uint32(at offset: Int) -> UInt32? {
    guard offset >= 0, offset <= count, count - offset >= 4 else { return nil }
    let start = index(startIndex, offsetBy: offset)
    return UInt32(self[start])
      | (UInt32(self[index(start, offsetBy: 1)]) << 8)
      | (UInt32(self[index(start, offsetBy: 2)]) << 16)
      | (UInt32(self[index(start, offsetBy: 3)]) << 24)
  }

  fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
