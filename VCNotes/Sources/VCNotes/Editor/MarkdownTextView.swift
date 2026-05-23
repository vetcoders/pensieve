import AppKit

class MarkdownTextView: NSTextView {
    
    weak var gutter: LineNumberGutter?
    
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        allowsUndo = true
        usesFindBar = true
        isRichText = false
    }
    
    func setupGutter(layoutManager: NSTextLayoutManager) {
        guard let scrollView = enclosingScrollView else { return }
        let newGutter = LineNumberGutter(scrollView: scrollView, textLayoutManager: layoutManager)
        scrollView.verticalRulerView = newGutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        self.gutter = newGutter
        
        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    
    @objc private func boundsDidChange() {
        gutter?.needsDisplay = true
    }
    
    override func layout() {
        super.layout()
        gutter?.needsDisplay = true
    }
}
