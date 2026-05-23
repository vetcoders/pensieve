import SwiftUI
import Combine
import AppKit
import WebKit

// MARK: - SwiftUI surface

/// Real markdown preview: swift-markdown AST → HTML emitted into a WKWebView,
/// themed CSS injected from Bundle.module, re-render debounced 200ms.
///
/// Public shape preserved for upstream wiring (ContentView mounts this with
/// the AppState environment object — same as the placeholder it replaces).
struct PreviewView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var themeManager = ThemeManager()

    var body: some View {
        PreviewRepresentable(
            markdown: appState.activeDocumentText,
            fontSize: appState.fontSize,
            theme: themeManager.current,
            themeManager: themeManager
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - NSViewRepresentable bridge

struct PreviewRepresentable: NSViewRepresentable {
    let markdown: String
    let fontSize: CGFloat
    let theme: ThemeManager.Theme
    let themeManager: ThemeManager

    func makeCoordinator() -> Coordinator {
        Coordinator(themeManager: themeManager)
    }

    func makeNSView(context: Context) -> PreviewWebView {
        let view = PreviewWebView(frame: .zero)
        context.coordinator.attach(view: view)
        context.coordinator.submit(
            markdown: markdown,
            fontSize: fontSize,
            theme: theme,
            initial: true
        )
        return view
    }

    func updateNSView(_ nsView: PreviewWebView, context: Context) {
        context.coordinator.submit(
            markdown: markdown,
            fontSize: fontSize,
            theme: theme,
            initial: false
        )
    }

    static func dismantleNSView(_ nsView: PreviewWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    final class Coordinator {
        private struct Input: Equatable {
            let markdown: String
            let fontSize: CGFloat
            let theme: ThemeManager.Theme
        }

        private let renderer = MarkdownRenderer()
        private let themeManager: ThemeManager
        private let subject = PassthroughSubject<(Input, Bool), Never>()
        private var cancellable: AnyCancellable?
        private weak var view: PreviewWebView?
        private var lastInput: Input?

        init(themeManager: ThemeManager) {
            self.themeManager = themeManager
        }

        func attach(view: PreviewWebView) {
            self.view = view
            cancellable = subject
                .removeDuplicates(by: { $0.0 == $1.0 && $0.1 == $1.1 })
                .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                .sink { [weak self] payload in
                    self?.apply(payload.0)
                }
        }

        func detach() {
            cancellable?.cancel()
            cancellable = nil
            view = nil
        }

        func submit(markdown: String,
                    fontSize: CGFloat,
                    theme: ThemeManager.Theme,
                    initial: Bool) {
            let input = Input(markdown: markdown, fontSize: fontSize, theme: theme)
            if initial {
                // First mount: render immediately so the user does not stare
                // at an empty pane for the debounce interval.
                apply(input)
            }
            subject.send((input, initial))
        }

        private func apply(_ input: Input) {
            guard let view else { return }
            if input == lastInput { return }
            lastInput = input

            let output = renderer.render(input.markdown)
            let css = themeManager.css(for: input.theme)
            view.loadDocument(
                body: output.body,
                css: css,
                fontSize: input.fontSize,
                baseURL: Bundle.module.resourceURL
            )
        }
    }
}
