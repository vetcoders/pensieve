import AppKit

class MarkdownTextStorage: NSTextContentStorage {
    let highlighter = SyntaxHighlighter()
    let codeBlockHighlighter = CodeBlockHighlighter()

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
    
    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions, range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
        
        if editMask.contains(.editedCharacters) {
            // For MVP, highlight the entire string to ensure multi-line blocks like ``` sync properly
            refreshHighlighting()
        }
    }
    
    func refreshHighlighting() {
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
    }
}
