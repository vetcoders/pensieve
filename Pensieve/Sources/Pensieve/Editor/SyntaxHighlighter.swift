import AppKit

class SyntaxHighlighter {
    var baseFontSize: CGFloat = 14
    
    func highlight(_ textStorage: NSTextStorage, range: NSRange) {
        guard let targetRange = validRange(range, in: textStorage) else { return }
        let string = textStorage.string as NSString
        applyMarkdownAttributes(textStorage, string: string, targetRange: targetRange)
    }

    func resetBaseAttributes(_ textStorage: NSTextStorage, range: NSRange) {
        guard let targetRange = validRange(range, in: textStorage) else { return }
        let baseFont = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
        let baseColor = NSColor.textColor

        textStorage.removeAttribute(.font, range: targetRange)
        textStorage.removeAttribute(.foregroundColor, range: targetRange)
        textStorage.removeAttribute(.backgroundColor, range: targetRange)
        textStorage.removeAttribute(.underlineStyle, range: targetRange)

        textStorage.addAttribute(.font, value: baseFont, range: targetRange)
        textStorage.addAttribute(.foregroundColor, value: baseColor, range: targetRange)
    }

    private func validRange(_ range: NSRange, in textStorage: NSTextStorage) -> NSRange? {
        let string = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)

        guard NSIntersectionRange(range, fullRange).length > 0 || range.length == 0 else { return nil }
        return NSIntersectionRange(range, fullRange)
    }

    private func applyMarkdownAttributes(_ textStorage: NSTextStorage, string: NSString, targetRange: NSRange) {
        let baseFont = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)

        // Blockquote: ^> text
        highlightRegex("(?m)^>.*$", in: string, storage: textStorage, targetRange: targetRange, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        
        // Headings: ^# text
        let headingRegex = try! NSRegularExpression(pattern: "(?m)^#{1,6}\\s+.*$", options: [])
        headingRegex.enumerateMatches(in: string as String, options: [], range: targetRange) { match, _, _ in
            guard let match = match else { return }
            let matchedString = string.substring(with: match.range)
            let level = matchedString.prefix(while: { $0 == "#" }).count
            let size = baseFontSize + CGFloat((7 - level) * 2)
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            textStorage.addAttribute(.font, value: font, range: match.range)
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
        }
        
        // Bold: **text** or __text__
        let boldFont = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .bold)
        highlightRegex("\\*\\*.*?\\*\\*|__.*?__", in: string, storage: textStorage, targetRange: targetRange, attributes: [
            .font: boldFont
        ])
        
        // Italic: *text* or _text_ (basic regex)
        // macOS doesn't have a built-in italic monospaced font easily, we use regular italic trait if available
        let fontManager = NSFontManager.shared
        let italicizedFont = fontManager.convert(baseFont, toHaveTrait: .italicFontMask)
        highlightRegex("(?<!\\*)\\*(?!\\*).*?(?<!\\*)\\*(?!\\*)|(?<!_)_(?!_).*?(?<!_)_(?!_)", in: string, storage: textStorage, targetRange: targetRange, attributes: [
            .font: italicizedFont
        ])
        
        // Inline code: `code`
        highlightRegex("`[^`\n]+`", in: string, storage: textStorage, targetRange: targetRange, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular),
            .backgroundColor: NSColor.textBackgroundColor.withSystemEffect(.disabled),
            .foregroundColor: NSColor.systemPink
        ])
        
        // Links: [text](url)
        highlightRegex("\\[.*?\\]\\(.*?\\)", in: string, storage: textStorage, targetRange: targetRange, attributes: [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
    }
    
    private func highlightRegex(_ pattern: String, in string: NSString, storage: NSTextStorage, targetRange: NSRange, attributes: [NSAttributedString.Key: Any]) {
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        regex.enumerateMatches(in: string as String, options: [], range: targetRange) { match, _, _ in
            if let range = match?.range {
                storage.addAttributes(attributes, range: range)
            }
        }
    }
}
