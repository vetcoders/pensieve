import SwiftUI

/// The window's passive error line — the surface `AppState.lastError` never had.
///
/// Sits between the document pane and the status bar and, unlike the status bar,
/// is NOT gated on there being an open buffer: the failures that most need
/// saying (a workspace that will not open, a file that has moved) happen in a
/// window showing nothing at all.
///
/// Deliberately passive, and the ONLY error surface in the app: it appears when
/// the window records an error, stays until the user dismisses it or a durable
/// write resolves it, takes no focus, and blocks nothing. Nothing here is ever
/// modal — not even the data-loss class, which is louder in dress only.
///
/// Dismissing a data-loss banner hides this view and nothing else. The window
/// keeps its `unresolvedDataLoss` latch, so the app still knows the work is not
/// safe and an identical failure repeating on the next autosave tick has
/// nothing new to say.
///
/// Dressed from `tokens.warning` — the same semantic token the status bar's
/// "Edited" marker uses — so it reads as chrome of the active skin rather than
/// as a system alert box. A data-loss error fills that colour instead of hinting
/// at it, which is the whole visual difference between the two classes; there is
/// no `danger` token in the palette yet, and this cut does not add one.
struct WindowErrorBanner: View {
  @EnvironmentObject private var themeManager: ThemeManager

  let error: WindowError
  let onDismiss: () -> Void

  private var accent: Color { Color(themeManager.skin.tokens.warning.nsColor) }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: error.isDataLoss ? "exclamationmark.triangle.fill" : "info.circle")
        .foregroundStyle(error.isDataLoss ? Color.white : accent)
        .accessibilityHidden(true)

      Text(error.message)
        .foregroundStyle(error.isDataLoss ? Color.white : Color.primary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)

      Spacer(minLength: 8)

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .foregroundStyle(error.isDataLoss ? Color.white : Color.secondary)
      }
      .buttonStyle(.plain)
      .help("Dismiss this message")
      .accessibilityLabel("Dismiss message")
      .accessibilityIdentifier("pensieve.errorbanner.dismiss")
    }
    .font(.system(size: 11))
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    // The passive line rides the SAME material as the status bar it sits on, so
    // it reads as one continuous strip of chrome. It was an accent wash at 12%
    // over the editor background first, and a screenshot on the dark skins
    // settled it: a translucent tint over a near-black pane leaves `.primary`
    // text visibly dimmer than the status bar two pixels below it — an error
    // line that is harder to read than the word count is not a surface. The
    // accent stays where it costs no legibility, on the icon.
    .background(error.isDataLoss ? AnyShapeStyle(accent) : AnyShapeStyle(.bar))
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      error.isDataLoss
        ? "Unsaved work warning: \(error.message)" : "Message: \(error.message)"
    )
    .accessibilityIdentifier(
      error.isDataLoss ? "pensieve.errorbanner.dataloss" : "pensieve.errorbanner.status")
  }
}
