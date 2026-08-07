import AppKit
import ObjectiveC.runtime

/// Gives the native tab bar's "+" one answer across BOTH window classes this
/// app puts documents in.
///
/// `DocumentWindow` — the AppKit factory's tabs — overrides
/// `newWindowForTab(_:)` and routes it to the registry itself. The other class
/// is SwiftUI's own window (`AppKitWindow`, verified at runtime by
/// `ConsciousCloseHook`): the launcher scene every cold start auto-presents,
/// which is also where a recovered draft lands. That window is not ours to
/// subclass, and `newWindowForTab:` is not a delegate method — so the delegate
/// proxy trick `ConsciousCloseHook` uses cannot reach it. What CAN reach it is
/// the class itself: the bridge patches `newWindowForTab:` on the window's own
/// (most-derived) class, so its implementation wins over anything AppKit or
/// SwiftUI installed further up the chain.
///
/// Scoped to Pensieve's tabbing identifier, exactly as the cut requires: a
/// window of a patched class that does NOT carry
/// `WindowChromeRecipe.documentTabbingIdentifier` is handed straight back to
/// the implementation the patch replaced (and to nothing at all when the class
/// had none, which is `NSWindow`'s documented default). Nothing outside
/// Pensieve's own document windows changes behaviour.
///
/// `DocumentWindow` is deliberately NEVER patched. Its override already calls
/// the registry once; adding a second implementation on its class is precisely
/// how a single "+" click ends up creating two documents.
@MainActor
enum DocumentWindowTabBridge {
  /// The identifier the bridge claims. Every Pensieve document window carries
  /// it — the factory sets it in `WindowChromeRecipe.apply`, and
  /// `DocumentWindowRegistry.attach` normalizes every other window onto it.
  static var claimedTabbingIdentifier = WindowChromeRecipe.documentTabbingIdentifier

  /// What a claimed "+" does. A seam, not a policy: the placement decision
  /// itself lives in the registry (`newDocumentForTab(from:)`), and this exists
  /// so the patch can be proven without the shared singleton.
  static var handleNewWindowForTab: @MainActor (NSWindow) -> Void = { window in
    DocumentWindowRegistry.shared.newDocumentForTab(from: window)
  }

  private static let newWindowForTabSelector = #selector(NSWindow.newWindowForTab(_:))
  /// Classes already patched. The patch is per CLASS, so a second window of the
  /// same class must not install a second implementation over the first — that
  /// would strand the first patch's captured original and leak an IMP.
  private static var bridgedClasses: Set<ObjectIdentifier> = []

  /// Installs the bridge for `window`'s class, once per class.
  ///
  /// Idempotent and safe to call on every registry attach: the window's class
  /// is only learned from a real window, so the bridge never has to guess which
  /// class SwiftUI is using this OS release.
  @discardableResult
  static func install(for window: NSWindow) -> Bool {
    guard !(window is DocumentWindow) else { return false }
    return installBridge(on: bridgeableClass(of: window))
  }

  /// The class to patch: the window's own, minus any KVO isa-swizzle.
  ///
  /// `NSKVONotifying_X` is a runtime-private subclass that exists only while
  /// something observes this instance; patching it would cover the observed
  /// window and miss every un-observed sibling of the same real class.
  private static func bridgeableClass(of window: NSWindow) -> AnyClass? {
    var cls: AnyClass? = object_getClass(window)
    while let current = cls, NSStringFromClass(current).hasPrefix("NSKVONotifying_") {
      cls = class_getSuperclass(current)
    }
    return cls
  }

  private static func installBridge(on cls: AnyClass?) -> Bool {
    guard let cls, bridgedClasses.insert(ObjectIdentifier(cls)).inserted else { return false }

    // Whatever answers "+" for this class TODAY — an implementation it declares
    // itself, one it inherits, or none at all. Captured BEFORE the patch so a
    // window that is not Pensieve's keeps exactly the behaviour it had.
    let inherited = class_getInstanceMethod(cls, newWindowForTabSelector)
      .map(method_getImplementation)
    // A box because the replacement has to exist before the call that tells us
    // what it replaced.
    let original = OriginalImplementation()

    let block: @convention(block) (NSWindow, Any?) -> Void = { window, sender in
      MainActor.assumeIsolated {
        guard window.tabbingIdentifier != claimedTabbingIdentifier else {
          handleNewWindowForTab(window)
          return
        }
        guard let imp = original.imp else { return }
        let callable = unsafeBitCast(
          imp, to: (@convention(c) (NSWindow, Selector, Any?) -> Void).self)
        callable(window, newWindowForTabSelector, sender)
      }
    }
    let replacement = imp_implementationWithBlock(block)

    if class_addMethod(cls, newWindowForTabSelector, replacement, "v@:@") {
      // The class did not declare it: our implementation now shadows whatever
      // it used to inherit, which is what `inherited` holds (nil when nothing
      // in the chain implemented it — `NSWindow`'s default is to do nothing).
      original.imp = inherited
    } else if let method = class_getInstanceMethod(cls, newWindowForTabSelector) {
      // The class declares its own. Swap the implementation out and keep the
      // one we displaced as the non-Pensieve fallback.
      original.imp = method_setImplementation(method, replacement)
    }
    return true
  }
}

/// Mutable holder for the implementation a patch displaced.
private final class OriginalImplementation {
  var imp: IMP?
}
