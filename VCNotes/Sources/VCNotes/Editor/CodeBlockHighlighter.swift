import AppKit

class CodeBlockHighlighter {
    var baseFontSize: CGFloat = 14
    
    func highlight(_ textStorage: NSTextStorage, range: NSRange) {
        let string = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        guard NSIntersectionRange(range, fullRange).length > 0 || range.length == 0 else { return }
        let targetRange = NSIntersectionRange(range, fullRange)
        
        let regex = try! NSRegularExpression(pattern: "(?s)```(.*?)\\n(.*?)```", options: [])
        
        regex.enumerateMatches(in: string as String, options: [], range: targetRange) { match, _, _ in
            guard let match = match else { return }
            let langRange = match.range(at: 1)
            let codeRange = match.range(at: 2)
            
            let lang = langRange.length > 0 ? string.substring(with: langRange).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
            
            // Base code block styling
            let baseColor = NSColor.secondaryLabelColor
            textStorage.addAttribute(.foregroundColor, value: baseColor, range: match.range)
            
            // Highlight actual code
            let codeString = string.substring(with: codeRange)
            let nsCodeString = codeString as NSString
            let codeStart = codeRange.location
            
            func colorRegex(_ pattern: String, color: NSColor) {
                let r = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
                r.enumerateMatches(in: codeString, options: [], range: NSRange(location: 0, length: nsCodeString.length)) { m, _, _ in
                    if let codeMatch = m {
                        let finalRange = NSRange(location: codeStart + codeMatch.range.location, length: codeMatch.range.length)
                        textStorage.addAttribute(.foregroundColor, value: color, range: finalRange)
                    }
                }
            }
            
            switch lang {
            case "json":
                colorRegex("\".*?\"\\s*:", color: NSColor.systemPurple)
                colorRegex(":\\s*\".*?\"", color: NSColor.systemGreen)
                colorRegex("\\b[0-9]+\\b", color: NSColor.systemOrange)
                colorRegex("\\b(true|false|null)\\b", color: NSColor.systemBlue)
            case "swift":
                colorRegex("\\b(func|var|let|class|struct|enum|if|else|guard|return|import|switch|case)\\b", color: NSColor.systemPink)
                colorRegex("\".*?\"", color: NSColor.systemRed)
                colorRegex("//.*$", color: NSColor.systemGray)
            case "python":
                colorRegex("\\b(def|class|if|else|elif|return|import|from|for|in|while)\\b", color: NSColor.systemPink)
                colorRegex("(\"\"\".*?\"\"\"|'''.*?''')", color: NSColor.systemGray)
                colorRegex("(\".*?\"|'.*?')", color: NSColor.systemGreen)
                colorRegex("#.*$", color: NSColor.systemGray)
            case "rust":
                colorRegex("\\b(fn|let|mut|struct|enum|impl|if|else|match|return|use|mod|pub)\\b", color: NSColor.systemPink)
                colorRegex("\".*?\"", color: NSColor.systemGreen)
                colorRegex("//.*$", color: NSColor.systemGray)
            case "bash":
                colorRegex("\\b(if|fi|then|else|for|do|done|while|echo|export|local)\\b", color: NSColor.systemPink)
                colorRegex("(\".*?\"|'.*?')", color: NSColor.systemGreen)
                colorRegex("#.*$", color: NSColor.systemGray)
            case "yaml", "yml":
                colorRegex("^\\s*.*?\\s*:", color: NSColor.systemPurple)
                colorRegex("#.*$", color: NSColor.systemGray)
            default:
                break
            }
        }
    }
}
