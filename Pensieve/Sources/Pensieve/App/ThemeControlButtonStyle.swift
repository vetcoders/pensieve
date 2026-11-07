import SwiftUI

/// Flat controls use the sidebar's selection wash and leading accent marker.
/// Secondary actions stay in the surface until hovered or pressed.
struct ThemeControlButtonStyle: ButtonStyle {
  let tokens: ThemeTokens
  var isSelected = false
  var isPrimary = false

  func makeBody(configuration: Configuration) -> some View {
    ThemeControlButtonBody(
      label: configuration.label, tokens: tokens, isSelected: isSelected,
      isPrimary: isPrimary, isPressed: configuration.isPressed)
  }
}

private struct ThemeControlButtonBody<Label: View>: View {
  let label: Label
  let tokens: ThemeTokens
  let isSelected: Bool
  let isPrimary: Bool
  let isPressed: Bool
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    let accent = Color(nsColor: tokens.legibleAccent)
    let text = Color(nsColor: tokens.text.nsColor)
    let highlighted = isSelected || (isPrimary && isEnabled)
    label
      .font(.caption.weight(highlighted ? .semibold : .regular))
      .foregroundStyle(highlighted ? accent : text)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(
            highlighted
              ? accent.opacity(isPressed ? 0.24 : 0.16)
              : text.opacity(isEnabled && (isHovered || isPressed) ? 0.06 : 0))
      }
      .overlay(alignment: .leading) {
        if isSelected {
          RoundedRectangle(cornerRadius: 1).fill(accent).frame(width: 2)
        }
      }
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .onHover { isHovered = $0 }
  }
}
