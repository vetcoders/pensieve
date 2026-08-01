import AppKit
import SwiftUI

/// One operator-visible toolbar control in the form the clipped-items ("»")
/// menu needs: a name to show, live state to reflect, and the SAME action the
/// bridged control performs.
///
/// The action is a closure over the same `AppState`/`AppController` the control
/// binds to — not a poke at the bridged `NSSegmentedControl`. That is not a
/// style preference: a clipped toolbar item is REMOVED from the window's view
/// tree (measured — `picker.window == nil` at every width below the clipping
/// threshold), so there is no live control left to click by the time the
/// overflow menu is the only way to reach the action.
struct ToolbarOverflowCommand {
  let id: String
  let title: String
  let systemImage: String
  let isEnabled: @MainActor () -> Bool
  /// `nil` for a momentary action; the live on/off value for a toggle, so the
  /// menu shows the same check state the chip shows as a lit segment.
  let isOn: (@MainActor () -> Bool)?
  let perform: (@MainActor () -> Void)?
  /// A nested menu (the rewrite intents), for a control that is itself a menu.
  let children: [ToolbarOverflowCommand]

  init(
    id: String,
    title: String,
    systemImage: String,
    isEnabled: @escaping @MainActor () -> Bool = { true },
    isOn: (@MainActor () -> Bool)? = nil,
    perform: (@MainActor () -> Void)? = nil,
    children: [ToolbarOverflowCommand] = []
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.isEnabled = isEnabled
    self.isOn = isOn
    self.perform = perform
    self.children = children
  }
}

/// One labeled toolbar family and everything the operator loses when the window
/// clips it. An EMPTY command list means "leave AppKit's own menu form alone" —
/// the family's controls already carry working menu forms of their own.
struct ToolbarOverflowFamily {
  let identifier: EditorToolbelt.ToolbarFamilyIdentifier
  let title: String
  let commands: [ToolbarOverflowCommand]
}

/// Authors the clipped-items ("»") menu for the toolbar families macOS cannot
/// describe on its own.
///
/// Measured contract this is built on (probed against the live bridge, both
/// before and after this pass exists):
///
///   * The clipped-items menu is assembled from the `menuFormRepresentation` of
///     each CLIPPED `NSToolbarItem` — the group's own, never its subitems'. A
///     group whose form is empty contributes NOTHING and the family vanishes
///     silently.
///   * SwiftUI derives that group form from the subitems that have one. A
///     `ControlGroup` has none (it is bridged into a single segmented control),
///     so a toggle-only family — auto reload, scroll sync, dictation, AI
///     autocomplete — is unreachable the moment it clips.
///   * When exactly one subitem carries a form, SwiftUI still wraps it in a
///     submenu of the SAME name, which is what put "Reload Preview" and
///     "Rewrite with AI" in the menu twice, once as a button and once as a
///     chevroned parent of itself.
///   * A group form we assign ourselves sticks and is honoured (measured: the
///     authored titles come back out of AppKit's clipped-items menu).
///
/// Re-asserted, not pinned once, for the same reason `assertToolbarChipTint` is:
/// SwiftUI rebuilds the toolbar items whenever the toolbar's content changes —
/// a skin switch always does, since the appearance menu's label carries the skin
/// name — and a rebuilt group comes back with SwiftUI's derived form again.
enum ToolbarOverflowRecipe {
  /// Marks a menu form as this recipe's work, so a pass can tell "already
  /// authored" from "SwiftUI handed the group a fresh derived form".
  static func formIdentifier(
    for family: EditorToolbelt.ToolbarFamilyIdentifier
  ) -> NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier("pensieve.toolbar.overflow.\(family.rawValue)")
  }

  /// Strong per-window holder for the menu targets. `NSMenuItem.target` is weak,
  /// so an action object dropped here would leave every overflow entry dead.
  private static let controllers =
    NSMapTable<NSWindow, ToolbarOverflowController>.weakToStrongObjects()

  /// Gives every family that needs one an authored overflow entry. Returns
  /// `true` when something had to be corrected.
  ///
  /// Fail-closed on a shape it does not recognise: if the window's toolbar does
  /// not carry exactly one group per declared family, nothing is written. A
  /// wrong family would be worse than AppKit's own incomplete menu, and
  /// `EditorToolbarOverflowTests` pins the shapes against each other.
  @MainActor
  @discardableResult
  static func assertOverflowMenus(on window: NSWindow, families: [ToolbarOverflowFamily]) -> Bool {
    guard let toolbar = window.toolbar else { return false }
    let groups = toolbar.items.compactMap { $0 as? NSToolbarItemGroup }
    guard groups.count == families.count, !groups.isEmpty else { return false }

    let controller: ToolbarOverflowController
    if let existing = controllers.object(forKey: window) {
      controller = existing
    } else {
      controller = ToolbarOverflowController()
      controllers.setObject(controller, forKey: window)
    }

    var corrected = false
    for (group, family) in zip(groups, families) where !family.commands.isEmpty {
      if controller.apply(family, to: group) { corrected = true }
    }
    return corrected
  }

  /// Names each mode segment on hover.
  ///
  /// The mode picker shows icons, not titles, because titled segments cost the
  /// toolbar 150pt it does not have. That trade is only honest while the name is
  /// still one hover away — and `.help()` on a `Picker`'s content does NOT reach
  /// the bridged segment (measured: every `toolTip(forSegment:)` comes back
  /// empty), because picker content is folded into segment titles and images and
  /// nothing else survives. So the tooltips are written on the AppKit side, the
  /// same place the chip tint has to be written for the same kind of reason.
  ///
  /// Matched by tracking mode and segment count, the same discriminator
  /// `WindowChromeRecipe.isToggleChipGroup` uses: the mode picker is this
  /// toolbar's only `.selectOne` control.
  @MainActor
  @discardableResult
  static func assertModeSegmentTooltips(on window: NSWindow, titles: [String]) -> Bool {
    var corrected = false
    for control in WindowChromeRecipe.toolbarSegmentedControls(in: window)
    where control.trackingMode == .selectOne && control.segmentCount == titles.count {
      for (index, title) in titles.enumerated()
      where control.toolTip(forSegment: index) != title {
        control.setToolTip(title, forSegment: index)
        corrected = true
      }
    }
    return corrected
  }
}

/// Owns the authored menus and is the target every authored entry fires at.
@MainActor
final class ToolbarOverflowController: NSObject, NSMenuItemValidation {
  /// The command shape a menu was built for. Rebuilding on every pass would
  /// throw away the menu AppKit may be showing; comparing shape (not live
  /// state, which the validation pass refreshes) keeps a steady state silent.
  private var signatures: [EditorToolbelt.ToolbarFamilyIdentifier: [String]] = [:]

  @discardableResult
  func apply(_ family: ToolbarOverflowFamily, to group: NSToolbarItemGroup) -> Bool {
    let wanted = ToolbarOverflowRecipe.formIdentifier(for: family.identifier)
    let signature = Self.signature(of: family.commands)
    let current = group.menuFormRepresentation
    if current?.identifier == wanted, signatures[family.identifier] == signature {
      // Same authored menu, same shape — the live state is refreshed by
      // `validateMenuItem` when the menu actually opens.
      Self.rebind(menuItem: current, to: family.commands)
      return false
    }

    let form = NSMenuItem(title: family.title, action: nil, keyEquivalent: "")
    form.identifier = wanted
    let submenu = NSMenu(title: family.title)
    submenu.autoenablesItems = true
    for command in family.commands {
      submenu.addItem(item(for: command))
    }
    form.submenu = submenu
    group.menuFormRepresentation = form
    signatures[family.identifier] = signature
    return true
  }

  private func item(for command: ToolbarOverflowCommand) -> NSMenuItem {
    let item = ToolbarOverflowMenuItem(
      title: command.title, action: command.perform == nil ? nil : #selector(fire(_:)),
      keyEquivalent: "")
    item.command = command
    item.image = NSImage(
      systemSymbolName: command.systemImage, accessibilityDescription: command.title)
    item.state = (command.isOn?() ?? false) ? .on : .off
    if command.perform != nil { item.target = self }
    if !command.children.isEmpty {
      let submenu = NSMenu(title: command.title)
      submenu.autoenablesItems = true
      for child in command.children { submenu.addItem(self.item(for: child)) }
      item.submenu = submenu
    }
    return item
  }

  /// Re-points an already-built menu at freshly captured closures. The SHAPE is
  /// unchanged (that is what the signature checked), but the closures a previous
  /// pass captured may hold a stale binding, so the live ones replace them.
  private static func rebind(menuItem: NSMenuItem?, to commands: [ToolbarOverflowCommand]) {
    guard let items = menuItem?.submenu?.items, items.count == commands.count else { return }
    for (item, command) in zip(items, commands) {
      guard let authored = item as? ToolbarOverflowMenuItem else { continue }
      authored.command = command
      rebind(menuItem: item, to: command.children)
    }
  }

  private static func signature(of commands: [ToolbarOverflowCommand]) -> [String] {
    commands.flatMap { [$0.id] + signature(of: $0.children).map { "\($0)" } }
  }

  @objc private func fire(_ sender: Any?) {
    (sender as? ToolbarOverflowMenuItem)?.command?.perform?()
  }

  /// The one place the menu meets live state: AppKit validates every item right
  /// before the menu is drawn, so enablement and the toggle check mark are read
  /// then instead of being frozen at build time.
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let authored = menuItem as? ToolbarOverflowMenuItem, let command = authored.command
    else { return true }
    menuItem.state = (command.isOn?() ?? false) ? .on : .off
    return command.isEnabled()
  }
}

/// Carries its command so the shared target can answer both the click and the
/// validation without a side table keyed on menu identity.
final class ToolbarOverflowMenuItem: NSMenuItem {
  var command: ToolbarOverflowCommand?
}

/// Runs the overflow pass for the window that hosts the editor.
///
/// A hidden zero-size view rather than a lifecycle hook because the pass needs a
/// window AND has to run again after every SwiftUI toolbar rebuild — which is
/// exactly when the enclosing body is re-evaluated. The follow-up async pass
/// covers the first update, when the view is already in a window but the bridge
/// has not built the toolbar items yet.
struct ToolbarOverflowSink: NSViewRepresentable {
  let families: [ToolbarOverflowFamily]
  let modeSegmentTitles: [String]

  init(
    families: [ToolbarOverflowFamily],
    modeSegmentTitles: [String] = EditorMode.allCases.map(\.label)
  ) {
    self.families = families
    self.modeSegmentTitles = modeSegmentTitles
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.isHidden = true
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let families = self.families
    let titles = self.modeSegmentTitles
    func assert() {
      guard let window = nsView.window else { return }
      ToolbarOverflowRecipe.assertOverflowMenus(on: window, families: families)
      ToolbarOverflowRecipe.assertModeSegmentTooltips(on: window, titles: titles)
    }
    assert()
    // The first update lands before the bridge has built the toolbar items, and
    // a rebuild lands after this body ran; one turn later both are settled.
    DispatchQueue.main.async { assert() }
  }
}
