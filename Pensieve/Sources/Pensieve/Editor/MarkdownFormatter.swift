import Foundation

enum MarkdownFormat: CaseIterable, Identifiable {
  case bold
  case strike
  case italic
  case quote
  case code
  case link
  case bulletedList
  case numberedList

  var id: Self { self }

  var label: String {
    switch self {
    case .bold: return "Bold"
    case .strike: return "Strikethrough"
    case .italic: return "Italic"
    case .quote: return "Quote"
    case .code: return "Code"
    case .link: return "Link"
    case .bulletedList: return "Bulleted List"
    case .numberedList: return "Numbered List"
    }
  }

  var systemImageName: String {
    switch self {
    case .bold: return "bold"
    case .strike: return "strikethrough"
    case .italic: return "italic"
    case .quote: return "quote.opening"
    case .code: return "chevron.left.forwardslash.chevron.right"
    case .link: return "link"
    case .bulletedList: return "list.bullet"
    case .numberedList: return "list.number"
    }
  }
}

struct MarkdownFormatCommand: Equatable, Identifiable {
  let id: UUID
  let format: MarkdownFormat

  init(format: MarkdownFormat, id: UUID = UUID()) {
    self.id = id
    self.format = format
  }
}

enum MarkdownFormatter {
  static func format(_ text: String, as format: MarkdownFormat) -> String {
    switch format {
    case .bold:
      return "**\(text)**"
    case .italic:
      return "*\(text)*"
    case .strike:
      return "~~\(text)~~"
    case .code:
      return "```\n\(text)\n```"
    case .link:
      return "[\(text)](url)"
    case .quote:
      return prefixLines(in: text, with: "> ")
    case .bulletedList:
      return prefixLines(in: text, with: "- ")
    case .numberedList:
      return prefixLines(in: text, with: "1. ")
    }
  }

  private static func prefixLines(in text: String, with prefix: String) -> String {
    text
      .components(separatedBy: "\n")
      .map { "\(prefix)\($0)" }
      .joined(separator: "\n") + "\n"
  }
}
