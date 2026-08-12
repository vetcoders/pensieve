import ApplicationServices
import CoreGraphics
import Foundation

// Public-API runtime witness for Pensieve's native AppKit tab group.
//
// This probe deliberately observes only the process-wide Accessibility tree and
// WindowServer metadata available through public APIs. It does not import
// Pensieve, consult product-internal trace state, or inspect AppKit's private
// in-process window/tab ownership graph.
// Consequently, "one window" below means one presented AX window and one
// on-screen layer-0 WindowServer surface. Native AppKit tabs may still be backed
// by multiple underlying NSWindow objects; that implementation detail is not
// asserted here.

private enum ExitStatus: Int32 {
  case success = 0
  case failure = 1
  case usage = 2
}

private struct ProbeFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

private struct Arguments {
  let processIdentifier: pid_t
  let fileWitness: String
  let untitledWitness: String
  let timeout: TimeInterval
}

private struct TabSelection {
  let children: [AXUIElement]
  let selectedIndex: Int
}

private enum DocumentKind: String {
  case file
  case untitled
}

private struct PresentedState {
  let tabs: [AXUIElement]
  let selectedIndex: Int
  let editorValue: String
  let documentKind: DocumentKind
}

private enum ActionDispatch {
  case acknowledged
  case completionUncertain
}

private let editorIdentifier = "pensieve.editor"
private let inventoryNodeLimit = 240
private let inventoryDepthLimit = 12
private let inventoryTimeout: TimeInterval = 3
private let pollInterval: TimeInterval = 0.05
private let messagingTimeout: Float = 0.2

@inline(__always)
private func writeStandardError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func failUsage(_ message: String) -> Never {
  writeStandardError(message)
  writeStandardError(
    "usage: native-tab-ax-probe.swift <expected-pid> <file-witness> <untitled-witness> [timeout-seconds]"
  )
  exit(ExitStatus.usage.rawValue)
}

private func parsedArguments() -> Arguments {
  let values = CommandLine.arguments
  guard values.count == 4 || values.count == 5 else {
    failUsage("invalid native-tab AX probe argument count")
  }
  guard let processIdentifier = pid_t(values[1]), processIdentifier > 0 else {
    failUsage("expected-pid must be a positive integer")
  }

  let fileWitness = values[2]
  let untitledWitness = values[3]
  guard !fileWitness.isEmpty, !untitledWitness.isEmpty else {
    failUsage("both document witnesses must be non-empty")
  }
  guard fileWitness != untitledWitness,
    !fileWitness.contains(untitledWitness),
    !untitledWitness.contains(fileWitness)
  else {
    failUsage("document witnesses must be distinct, non-overlapping strings")
  }

  let timeout: TimeInterval
  if values.count == 5 {
    guard let parsedTimeout = TimeInterval(values[4]),
      parsedTimeout >= 0.5,
      parsedTimeout <= 30
    else {
      failUsage("timeout-seconds must be between 0.5 and 30")
    }
    timeout = parsedTimeout
  } else {
    timeout = 8
  }

  return Arguments(
    processIdentifier: processIdentifier,
    fileWitness: fileWitness,
    untitledWitness: untitledWitness,
    timeout: timeout
  )
}

private func copyAttribute(
  _ element: AXUIElement,
  _ attribute: String
) throws -> CFTypeRef {
  var rawValue: CFTypeRef?
  let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
  guard result == .success else {
    throw ProbeFailure(
      "AX attribute \(attribute) failed with AXError(rawValue: \(result.rawValue))"
    )
  }
  guard let rawValue else {
    throw ProbeFailure("AX attribute \(attribute) returned no value")
  }
  return rawValue
}

private func optionalAttribute(
  _ element: AXUIElement,
  _ attribute: String
) -> CFTypeRef? {
  try? copyAttribute(element, attribute)
}

private func stringAttribute(
  _ element: AXUIElement,
  _ attribute: String
) throws -> String {
  let value = try copyAttribute(element, attribute)
  guard let string = value as? String else {
    throw ProbeFailure("AX attribute \(attribute) did not contain a String")
  }
  return string
}

private func optionalStringAttribute(
  _ element: AXUIElement,
  _ attribute: String
) -> String? {
  optionalAttribute(element, attribute) as? String
}

private func boolAttribute(
  _ element: AXUIElement,
  _ attribute: String
) throws -> Bool {
  let value = try copyAttribute(element, attribute)
  if let boolean = value as? Bool {
    return boolean
  }
  if let number = value as? NSNumber {
    return number.boolValue
  }
  throw ProbeFailure("AX attribute \(attribute) did not contain a Boolean")
}

private func elementArrayAttribute(
  _ element: AXUIElement,
  _ attribute: String
) throws -> [AXUIElement] {
  let value = try copyAttribute(element, attribute)
  guard let elements = value as? [AXUIElement] else {
    throw ProbeFailure("AX attribute \(attribute) did not contain AX elements")
  }
  return elements
}

private func elementsAreEqual(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
  CFEqual(lhs, rhs)
}

private func descendants(
  of root: AXUIElement,
  maximumNodes: Int = inventoryNodeLimit,
  maximumDepth: Int = inventoryDepthLimit,
  deadline: Date
) -> [AXUIElement] {
  var result: [AXUIElement] = []
  var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
  var cursor = 0

  while cursor < queue.count, result.count < maximumNodes, Date() < deadline {
    let current = queue[cursor]
    cursor += 1
    result.append(current.element)
    guard current.depth < maximumDepth,
      let children = try? elementArrayAttribute(current.element, kAXChildrenAttribute)
    else {
      continue
    }
    for child in children where result.count + queue.count - cursor < maximumNodes {
      queue.append((child, current.depth + 1))
    }
  }
  return result
}

private func applicationWindows(_ application: AXUIElement) throws -> [AXUIElement] {
  try elementArrayAttribute(application, kAXWindowsAttribute)
}

private func candidateTabGroups(
  in window: AXUIElement,
  deadline: Date
) throws -> [(AXUIElement, [AXUIElement])] {
  var candidates: [(AXUIElement, [AXUIElement])] = []
  for element in descendants(of: window, deadline: deadline) {
    guard Date() < deadline else { break }
    guard optionalStringAttribute(element, kAXRoleAttribute) == kAXTabGroupRole as String,
      let children = try? elementArrayAttribute(element, kAXChildrenAttribute),
      children.count == 2,
      children.allSatisfy({
        optionalStringAttribute($0, kAXRoleAttribute) == kAXRadioButtonRole as String
      })
    else {
      continue
    }
    candidates.append((element, children))
  }
  return candidates
}

private func tabSelection(
  group: AXUIElement,
  children: [AXUIElement]
) throws -> TabSelection {
  let selectedChildren = try elementArrayAttribute(group, kAXSelectedChildrenAttribute)
  guard selectedChildren.count == 1, let selectedChild = selectedChildren.first else {
    throw ProbeFailure(
      "native AXTabGroup has \(selectedChildren.count) AXSelectedChildren; expected exactly one"
    )
  }

  let selectedByMembership = children.indices.filter {
    elementsAreEqual(children[$0], selectedChild)
  }
  guard selectedByMembership.count == 1, let membershipIndex = selectedByMembership.first else {
    throw ProbeFailure(
      "AXSelectedChildren does not identify exactly one of the two AXChildren"
    )
  }

  let selectedByAttribute = try children.enumerated().compactMap { index, child -> Int? in
    try boolAttribute(child, kAXSelectedAttribute) ? index : nil
  }
  guard selectedByAttribute == [membershipIndex] else {
    throw ProbeFailure(
      "AXSelectedChildren and per-tab AXSelected disagree: "
        + "membership=\(membershipIndex) selectedFlags=\(selectedByAttribute)"
    )
  }

  return TabSelection(children: children, selectedIndex: membershipIndex)
}

private func editorValue(in window: AXUIElement, deadline: Date) throws -> String {
  var editors: [AXUIElement] = []
  for element in descendants(of: window, deadline: deadline) {
    guard Date() < deadline else { break }
    if optionalStringAttribute(element, kAXIdentifierAttribute) == editorIdentifier {
      editors.append(element)
    }
  }
  guard editors.count == 1, let editor = editors.first else {
    throw ProbeFailure(
      "presented AXWindow contains \(editors.count) elements identified as \(editorIdentifier); expected one"
    )
  }
  return try stringAttribute(editor, kAXValueAttribute)
}

private func classifyDocument(
  editorValue: String,
  fileWitness: String,
  untitledWitness: String
) throws -> DocumentKind {
  let containsFile = editorValue.contains(fileWitness)
  let containsUntitled = editorValue.contains(untitledWitness)
  switch (containsFile, containsUntitled) {
  case (true, false):
    return .file
  case (false, true):
    return .untitled
  case (false, false):
    throw ProbeFailure("editor contains neither expected document witness")
  case (true, true):
    throw ProbeFailure("editor contains both expected document witnesses")
  }
}

private func windowInfo(for processIdentifier: pid_t) -> [[String: Any]] {
  let rows =
    CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
    as? [[String: Any]] ?? []
  return rows.filter {
    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier
  }
}

private func onScreenLayerZeroWindows(for processIdentifier: pid_t) -> [[String: Any]] {
  windowInfo(for: processIdentifier).filter {
    ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
      && ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
  }
}

private func currentPresentedState(
  application: AXUIElement,
  arguments: Arguments,
  deadline: Date
) throws -> PresentedState {
  var observedPID: pid_t = 0
  let pidResult = AXUIElementGetPid(application, &observedPID)
  guard pidResult == .success, observedPID == arguments.processIdentifier else {
    throw ProbeFailure(
      "AX application identity mismatch: expected pid=\(arguments.processIdentifier) "
        + "observed=\(observedPID) error=\(pidResult.rawValue)"
    )
  }

  let windows = try applicationWindows(application)
  guard windows.count == 1, let window = windows.first else {
    throw ProbeFailure(
      "process has \(windows.count) presented AXWindows; expected exactly one"
    )
  }

  let onScreenLayerZero = onScreenLayerZeroWindows(for: arguments.processIdentifier)
  guard onScreenLayerZero.count == 1 else {
    throw ProbeFailure(
      "process has \(onScreenLayerZero.count) on-screen layer-0 WindowServer surfaces; expected exactly one"
    )
  }

  let candidates = try candidateTabGroups(in: window, deadline: deadline)
  guard candidates.count == 1, let candidate = candidates.first else {
    throw ProbeFailure(
      "presented AXWindow contains \(candidates.count) AXTabGroups with exactly two "
        + "AXRadioButton children; expected one"
    )
  }

  let selection = try tabSelection(group: candidate.0, children: candidate.1)
  let value = try editorValue(in: window, deadline: deadline)
  let documentKind = try classifyDocument(
    editorValue: value,
    fileWitness: arguments.fileWitness,
    untitledWitness: arguments.untitledWitness
  )
  return PresentedState(
    tabs: selection.children,
    selectedIndex: selection.selectedIndex,
    editorValue: value,
    documentKind: documentKind
  )
}

private func waitForState(
  label: String,
  timeout: TimeInterval,
  read: (Date) throws -> PresentedState,
  accept: (PresentedState) -> Bool
) throws -> PresentedState {
  let deadline = Date().addingTimeInterval(timeout)
  var lastFailure: Error?
  repeat {
    do {
      let state = try read(deadline)
      if accept(state) {
        return state
      }
      lastFailure = ProbeFailure(
        "state predicate was not satisfied: selected=\(state.selectedIndex) document=\(state.documentKind.rawValue)"
      )
    } catch {
      lastFailure = error
    }
    if Date() >= deadline {
      break
    }
    Thread.sleep(forTimeInterval: pollInterval)
  } while true

  throw ProbeFailure(
    "timed out after \(timeout)s waiting for \(label); last observation: "
      + (lastFailure.map(String.init(describing:)) ?? "none")
  )
}

@discardableResult
private func pressTab(_ tab: AXUIElement, label: String) throws -> ActionDispatch {
  let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
  switch result {
  case .success:
    return .acknowledged
  case .cannotComplete:
    // Apple's AX contract explicitly says a timed-out action callback may have
    // completed even when the caller receives kAXErrorCannotComplete. Do not
    // press a second time or claim success here. The immediately following
    // bounded state poll must prove the requested selected tab and content.
    writeStandardError(
      "AXPress completion was uncertain for \(label); verifying selected state"
    )
    return .completionUncertain
  default:
    throw ProbeFailure(
      "AXPress failed for \(label) with AXError(rawValue: \(result.rawValue))"
    )
  }
}

private func abbreviated(_ value: String?, limit: Int = 120) -> String {
  guard let value else { return "<nil>" }
  let singleLine = value.replacingOccurrences(of: "\n", with: "\\n")
  if singleLine.count <= limit { return singleLine }
  return String(singleLine.prefix(limit)) + "…"
}

private func inventoryLine(_ element: AXUIElement, index: Int) -> String {
  let role = optionalStringAttribute(element, kAXRoleAttribute) ?? "<no-role>"
  let subrole = optionalStringAttribute(element, kAXSubroleAttribute) ?? "-"
  let identifier = optionalStringAttribute(element, kAXIdentifierAttribute) ?? "-"
  let title = optionalStringAttribute(element, kAXTitleAttribute)
  let description = optionalStringAttribute(element, kAXDescriptionAttribute)
  let rawValue = optionalAttribute(element, kAXValueAttribute)
  let valueSummary: String
  if let string = rawValue as? String {
    valueSummary = "<string length=\(string.count)>"
  } else if let number = rawValue as? NSNumber {
    valueSummary = number.stringValue
  } else if let elements = rawValue as? [AXUIElement] {
    valueSummary = "<AX elements count=\(elements.count)>"
  } else if rawValue != nil {
    valueSummary = "<\(String(describing: type(of: rawValue!)))>"
  } else {
    valueSummary = "<nil>"
  }
  let selected = (try? boolAttribute(element, kAXSelectedAttribute)).map(String.init) ?? "-"
  return
    "AX[\(index)] role=\(role) subrole=\(subrole) id=\(identifier) selected=\(selected)"
    + " title=\(abbreviated(title)) description=\(abbreviated(description))"
    + " value=\(valueSummary)"
}

private func emitInventory(application: AXUIElement, processIdentifier: pid_t) {
  writeStandardError("NATIVE_TAB_AX_INVENTORY_BEGIN pid=\(processIdentifier)")
  do {
    let windows = try applicationWindows(application)
    writeStandardError("AX_WINDOWS count=\(windows.count)")
    let inventoryDeadline = Date().addingTimeInterval(inventoryTimeout)
    for (windowIndex, window) in windows.enumerated() {
      guard Date() < inventoryDeadline else {
        writeStandardError("AX_INVENTORY_TRUNCATED deadline=\(inventoryTimeout)s")
        break
      }
      let nodes = descendants(
        of: window,
        maximumNodes: inventoryNodeLimit,
        maximumDepth: inventoryDepthLimit,
        deadline: inventoryDeadline
      )
      writeStandardError(
        "AX_WINDOW[\(windowIndex)] nodes=\(nodes.count) cappedAt=\(inventoryNodeLimit) depthCap=\(inventoryDepthLimit)"
      )
      for (nodeIndex, node) in nodes.enumerated() {
        guard Date() < inventoryDeadline else {
          writeStandardError("AX_INVENTORY_TRUNCATED deadline=\(inventoryTimeout)s")
          break
        }
        writeStandardError(inventoryLine(node, index: nodeIndex))
      }
    }
  } catch {
    writeStandardError("AX_INVENTORY_ERROR \(error)")
  }

  let cgRows = windowInfo(for: processIdentifier)
  writeStandardError("CG_WINDOWS count=\(cgRows.count)")
  for (index, row) in cgRows.enumerated() {
    let number = (row[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1
    let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
    let onScreen = (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    let name = abbreviated(row[kCGWindowName as String] as? String)
    let bounds = row[kCGWindowBounds as String].map(String.init(describing:)) ?? "<nil>"
    writeStandardError(
      "CG[\(index)] number=\(number) layer=\(layer) onscreen=\(onScreen) name=\(name) bounds=\(bounds)"
    )
  }
  writeStandardError("NATIVE_TAB_AX_INVENTORY_END")
}

private func runProbe(arguments: Arguments, application: AXUIElement) throws {
  let readState = { deadline in
    try currentPresentedState(
      application: application,
      arguments: arguments,
      deadline: deadline
    )
  }

  let initial = try waitForState(
    label: "initial two-tab presentation",
    timeout: arguments.timeout,
    read: readState,
    accept: { _ in true }
  )
  let originalIndex = initial.selectedIndex
  let otherIndex = originalIndex == 0 ? 1 : 0

  try pressTab(initial.tabs[otherIndex], label: "non-selected document tab")
  let other = try waitForState(
    label: "selection of the other document tab",
    timeout: arguments.timeout,
    read: readState,
    accept: { state in
      state.selectedIndex == otherIndex
        && state.documentKind != initial.documentKind
    }
  )

  try pressTab(other.tabs[originalIndex], label: "original document tab")
  let returned = try waitForState(
    label: "round-trip selection of the original document tab",
    timeout: arguments.timeout,
    read: readState,
    accept: { state in
      state.selectedIndex == originalIndex
        && state.documentKind == initial.documentKind
    }
  )

  guard initial.editorValue != other.editorValue else {
    throw ProbeFailure("both selected tabs exposed identical editor content")
  }
  guard returned.editorValue == initial.editorValue else {
    throw ProbeFailure("returning to the original tab did not restore its original editor content")
  }
  guard
    Set([initial.documentKind.rawValue, other.documentKind.rawValue])
      == Set([DocumentKind.file.rawValue, DocumentKind.untitled.rawValue])
  else {
    throw ProbeFailure("round-trip did not expose one file buffer and one untitled buffer")
  }

  print(
    "NATIVE_TAB_GROUP_AX=PASS presentedAXWindows=1 tabGroups=1 tabs=2 selected=1"
  )
  print(
    "NATIVE_TAB_ROUNDTRIP=PASS initial=\(initial.documentKind.rawValue) "
      + "other=\(other.documentKind.rawValue) returned=\(returned.documentKind.rawValue)"
  )
  print(
    "PRESENTED_WINDOW_SURFACES=PASS axWindows=1 cgOnscreenLayer0=1 underlyingNSWindowObjects=not-asserted"
  )
}

private func execute(arguments: Arguments) -> ExitStatus {
  // AX timeout state is per calling process. Apple requires the system-wide
  // element to bound every AX object reached by this probe; setting it on the
  // application object alone would leave windows, tab children and inventory
  // reads on the unbounded default timeout.
  let systemWide = AXUIElementCreateSystemWide()
  let messagingResult = AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
  guard messagingResult == .success else {
    writeStandardError(
      "NATIVE_TAB_AX_PROBE_FAIL: could not set global AX messaging timeout: "
        + "AXError(rawValue: \(messagingResult.rawValue))"
    )
    return .failure
  }
  defer {
    let resetResult = AXUIElementSetMessagingTimeout(systemWide, 0)
    if resetResult != .success {
      writeStandardError(
        "NATIVE_TAB_AX_TIMEOUT_RESET_FAIL: AXError(rawValue: \(resetResult.rawValue))"
      )
    }
  }

  let application = AXUIElementCreateApplication(arguments.processIdentifier)
  do {
    try runProbe(arguments: arguments, application: application)
    return .success
  } catch {
    writeStandardError("NATIVE_TAB_AX_PROBE_FAIL: \(error)")
    emitInventory(application: application, processIdentifier: arguments.processIdentifier)
    return .failure
  }
}

private let arguments = parsedArguments()
exit(execute(arguments: arguments).rawValue)
