import AppKit
import SwiftUI

/// Generic Ask chrome. The transcript and composer are slots the assembly
/// worker fills with whichever transport owns the turn. This view does not
/// create a session or subscribe to a stream.
///
/// In docked mode, it is placed in the owner window's detail view above the
/// status bar. In floating mode, it lives inside the native AppKit panel (`TaflaPanel`).
///
/// Narrow panels put scope/provider/readiness on a second compact row; the
/// title and surface buttons retain their width instead of wrapping or clipping.
struct AskSurface<Transcript: View, Composer: View, HeaderControls: View>: View {
  @Binding var presentation: AskPresentationState
  @ViewBuilder var headerControls: (Bool) -> HeaderControls
  @ViewBuilder var transcript: () -> Transcript
  @ViewBuilder var composer: () -> Composer
  @EnvironmentObject private var themeManager: ThemeManager
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  @State private var dockDragStart: CGFloat?

  var body: some View {
    GeometryReader { proxy in
      let content = proxy.size
      let layout = AskSurfaceLayout.allocate(content: content, presentation: presentation)
      let tokens = themeManager.skin.tokens
      let shellRole: AskChromeRole =
        presentation.mode == .floating ? .floatingShell : .dockShell
      let shellMaterial = AskChromeMaterial.resolve(
        majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        reduceTransparency: reduceTransparency,
        role: shellRole)
      let palette = AskSurfacePalette.resolve(tokens: tokens, material: shellMaterial)
      panel(layout: layout, content: content, palette: palette, material: shellMaterial)
        .frame(width: max(layout.askRegion.width, 0), height: max(layout.askRegion.height, 0))
        .opacity(presentation.mode == .hidden ? 0 : 1)
        .allowsHitTesting(presentation.mode != .hidden && layout.askRegion.height > 1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("pensieve.askSurface")
  }

  private func panel(
    layout: AskSurfaceAllocation,
    content: CGSize,
    palette: AskSurfacePalette,
    material: AskChromeMaterial
  ) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: presentation.mode == .floating ? 14 : 0, style: .continuous)
    return VStack(spacing: 0) {
      grip(layout: layout, content: content, palette: palette)
      chrome(layout: layout, content: content, palette: palette)
      transcript()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: max(layout.transcript.height, 0))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pensieve.askSurface.transcript")
      composer()
        .padding(.top, 6)
        .padding(.bottom, presentation.mode == .floating ? 16 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: max(layout.composer.height, 0))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pensieve.askSurface.composer")
    }
    .foregroundStyle(Color(nsColor: palette.text))
    .background { shellBackground(material: material, shape: shape, palette: palette) }
    .clipShape(shape)
    .accessibilityElement(children: .contain)
    .accessibilityAdjustableAction { direction in
      let delta: CGFloat = direction == .increment ? 24 : -24
      update { state in
        state.resizeDock(to: state.preferredDockHeight + delta, in: content)
      }
    }
  }

  @ViewBuilder
  private func grip(
    layout: AskSurfaceAllocation, content: CGSize, palette: AskSurfacePalette
  ) -> some View {
    if presentation.mode == .floating {
      ZStack {
        WindowDragHandle()
        Image(systemName: AskSurfaceSymbol.grip)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color(nsColor: palette.muted))
      }
      .frame(maxWidth: .infinity)
      .frame(height: max(layout.grip.height, 0))
      .accessibilityIdentifier("pensieve.askSurface.grip")
      .accessibilityLabel("Move Ask")
      .help("Drag to move Ask window")
    } else {
      Image(systemName: AskSurfaceSymbol.grip)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color(nsColor: palette.muted))
        .frame(maxWidth: .infinity)
        .frame(height: max(layout.grip.height, 0))
        .contentShape(Rectangle())
        .gesture(dockGripDrag(content: content))
        .accessibilityIdentifier("pensieve.askSurface.grip")
        .accessibilityLabel("Resize Ask")
        .help("Drag to resize Ask")
    }
  }

  private func chrome(
    layout: AskSurfaceAllocation, content: CGSize, palette: AskSurfacePalette
  ) -> some View {
    let compact = AskSurfaceLayout.usesCompactHeader(width: layout.chrome.width)
    return VStack(spacing: 4) {
      HStack(spacing: 8) {
        if presentation.mode == .floating {
          Text("Ask")
            .font(palette.headingFont)
            .foregroundStyle(Color(nsColor: palette.text))
            .fixedSize()
            .background(WindowDragHandle())
        } else {
          Text("Ask")
            .font(palette.headingFont)
            .foregroundStyle(Color(nsColor: palette.text))
            .fixedSize()
        }
        if !compact { headerControls(false) }
        Spacer(minLength: 0)
        chromeButtons(content: content, palette: palette)
          .fixedSize()
      }
      if compact {
        HStack(spacing: 8) {
          headerControls(true)
          Spacer(minLength: 0)
        }
      }
    }
    .padding(.horizontal, 12)
    .frame(height: max(layout.chrome.height, 0))
  }

  private func chromeButtons(content: CGSize, palette: AskSurfacePalette) -> some View {
    HStack(spacing: 4) {
      if presentation.mode == .floating {
        alwaysOnTopButton(palette: palette)
      }
      expandButton(content: content, palette: palette)
      presentationButton(content: content, palette: palette)
      hideButton(palette: palette)
    }
    .buttonStyle(.plain)
  }

  private func alwaysOnTopButton(palette: AskSurfacePalette) -> some View {
    let aot = presentation.isAlwaysOnTop
    return Button {
      update { state in
        state.isAlwaysOnTop.toggle()
      }
    } label: {
      Image(
        systemName: aot ? AskSurfaceSymbol.alwaysOnTopActive : AskSurfaceSymbol.alwaysOnTopInactive
      )
      .frame(width: 25, height: 25)
      .contentShape(Rectangle())
    }
    .foregroundStyle(Color(nsColor: palette.text))
    .accessibilityIdentifier("pensieve.askSurface.alwaysOnTop")
    .accessibilityLabel(aot ? "Disable Always on Top" : "Enable Always on Top")
    .help(
      aot
        ? "Keep Ask on top of other windows (active)"
        : "Keep Ask on top of other windows (inactive)")
  }

  private func expandButton(content: CGSize, palette: AskSurfacePalette) -> some View {
    let expanded = presentation.isExpanded
    return Button {
      update { state in
        _ = state.apply(expanded ? .collapse : .expand, content: content)
      }
    } label: {
      Image(systemName: expanded ? AskSurfaceSymbol.collapse : AskSurfaceSymbol.expand)
        .frame(width: 25, height: 25)
        .contentShape(Rectangle())
    }
    .foregroundStyle(Color(nsColor: palette.text))
    .accessibilityIdentifier("pensieve.askSurface.expand")
    .accessibilityLabel(expanded ? "Collapse transcript" : "Expand transcript")
    .help(expanded ? "Collapse the transcript" : "Expand the transcript")
  }

  private func presentationButton(content: CGSize, palette: AskSurfacePalette) -> some View {
    let floating = presentation.mode == .floating
    return Button {
      update { state in
        _ = state.apply(floating ? .dock : .float, content: content)
      }
    } label: {
      Image(systemName: floating ? AskSurfaceSymbol.dock : AskSurfaceSymbol.float)
        .frame(width: 25, height: 25)
        .contentShape(Rectangle())
    }
    .foregroundStyle(Color(nsColor: palette.text))
    .accessibilityIdentifier("pensieve.askSurface.presentation")
    .accessibilityLabel(floating ? "Dock Ask" : "Float Ask")
    .help(floating ? "Dock Ask in the window" : "Float Ask in a native panel")
  }

  private func hideButton(palette: AskSurfacePalette) -> some View {
    Button {
      update { state in
        _ = state.apply(.hide, content: .zero)
      }
    } label: {
      Image(systemName: AskSurfaceSymbol.hide)
        .frame(width: 25, height: 25)
        .contentShape(Rectangle())
    }
    .foregroundStyle(Color(nsColor: palette.text))
    .accessibilityIdentifier("pensieve.askSurface.hide")
    .accessibilityLabel("Hide Ask")
    .help("Hide Ask. The current reply keeps running.")
  }

  @ViewBuilder
  private func shellBackground(
    material: AskChromeMaterial, shape: RoundedRectangle, palette: AskSurfacePalette
  ) -> some View {
    switch material {
    case .solidTheme, .plain:
      shape.fill(Color(nsColor: palette.background))
    case .systemMaterial:
      shape.fill(.regularMaterial)
    case .liquidGlass:
      glassFill(shape: shape, fallback: Color(nsColor: palette.background))
    }
  }

  @ViewBuilder
  private func glassFill(shape: RoundedRectangle, fallback: Color) -> some View {
    if #available(macOS 26, *) {
      Color.clear.glassEffect(.regular, in: shape)
    } else {
      shape.fill(.regularMaterial)
        .overlay { shape.fill(fallback.opacity(0.01)) }
    }
  }

  private func dockGripDrag(content: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { value in
        let start =
          dockDragStart
          ?? AskSurfaceLayout.displayedDockHeight(
            presentation: presentation, content: content)
        if dockDragStart == nil { dockDragStart = start }
        update { state in
          AskPointerRoute.apply(
            .dockResize,
            to: &state,
            content: content,
            dockStart: start,
            translation: value.translation)
        }
      }
      .onEnded { _ in
        dockDragStart = nil
      }
  }

  private func update(_ body: (inout AskPresentationState) -> Void) {
    var copy = presentation
    body(&copy)
    presentation = copy
  }
}

/// Ink and type taken from `ThemeTokens`. Solid backing is the source token,
/// which is the surface the rest of the chrome already measures contrast on.
struct AskSurfacePalette: Equatable {
  var text: NSColor
  var muted: NSColor
  var background: NSColor
  var headingFamily: String
  var headingSize: CGFloat
  var material: AskChromeMaterial

  var headingFont: Font {
    if headingFamily.isEmpty {
      return .system(size: headingSize, weight: .semibold)
    }
    return .custom(headingFamily, size: headingSize).weight(.semibold)
  }

  static func resolve(tokens: ThemeTokens, material: AskChromeMaterial) -> AskSurfacePalette {
    AskSurfacePalette(
      text: tokens.text.nsColor,
      muted: tokens.muted.nsColor,
      background: tokens.source.nsColor,
      headingFamily: tokens.previewHeadingFamily,
      headingSize: 12,
      material: material)
  }
}

/// Initiates native macOS window dragging on mouse down.
struct WindowDragHandle: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowDragHandleView {
    WindowDragHandleView()
  }

  func updateNSView(_ nsView: WindowDragHandleView, context: Context) {}
}

final class WindowDragHandleView: NSView {
  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
}
