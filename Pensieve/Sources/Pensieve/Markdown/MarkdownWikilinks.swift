import Foundation

struct MarkdownWikilink: Equatable {
  let target: String
  let label: String
  let slug: String
}

enum MarkdownWikilinks {
  static func extract(from text: String) -> [MarkdownWikilink] {
    var links: [MarkdownWikilink] = []
    scan(text) { link, _, _ in
      links.append(link)
    }
    return links
  }

  static func renderText(_ text: String) -> String {
    var html = ""
    var cursor = text.startIndex
    scan(text) { link, range, _ in
      html += HTMLEmitter.escapeText(String(text[cursor..<range.lowerBound]))
      html += render(link)
      cursor = range.upperBound
    }
    html += HTMLEmitter.escapeText(String(text[cursor...]))
    return html
  }

  private static func scan(
    _ text: String,
    visit: (MarkdownWikilink, Range<String.Index>, Int) -> Void
  ) {
    var cursor = text.startIndex
    var ordinal = 0
    while cursor < text.endIndex {
      guard
        let open = text[cursor...].range(of: "[["),
        let close = text[open.upperBound...].range(of: "]]")
      else {
        break
      }

      let raw = String(text[open.upperBound..<close.lowerBound])
      if let link = parse(raw) {
        visit(link, open.lowerBound..<close.upperBound, ordinal)
        ordinal += 1
      }
      cursor = close.upperBound
    }
  }

  private static func parse(_ raw: String) -> MarkdownWikilink? {
    let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    let target = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    let explicitLabel: String
    if parts.count > 1 {
      explicitLabel = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      explicitLabel = ""
    }
    let label = explicitLabel.isEmpty ? target : explicitLabel
    return MarkdownWikilink(target: target, label: label, slug: slug(for: target))
  }

  private static func render(_ link: MarkdownWikilink) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "?#[]@!$&'()*+,;=:%")
    let hrefTarget =
      link.target.addingPercentEncoding(withAllowedCharacters: allowed)
      ?? link.target
    let href = "pensieve://wikilink/\(HTMLEmitter.escapeAttribute(hrefTarget))"
    let slug = HTMLEmitter.escapeAttribute(link.slug)
    let title = HTMLEmitter.escapeAttribute(link.target)
    let label = HTMLEmitter.escapeText(link.label)
    return "<a class=\"wikilink\" href=\"\(href)\""
      + " data-vc-wikilink-target=\"\(slug)\""
      + " data-vc-wikilink-title=\"\(title)\">\(label)</a>"
  }

  static func slug(for target: String) -> String {
    let folded = target.folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: .current
    )
    var slug = ""
    var previousWasSeparator = false
    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        slug.unicodeScalars.append(scalar)
        previousWasSeparator = false
      } else if !previousWasSeparator {
        slug.append("-")
        previousWasSeparator = true
      }
    }
    return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }
}
