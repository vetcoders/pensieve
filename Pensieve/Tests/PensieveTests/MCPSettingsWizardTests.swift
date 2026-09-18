import XCTest

@testable import Pensieve

@MainActor
final class MCPSettingsWizardTests: XCTestCase {
  func testTheSettingsWindowHasADedicatedMCPSection() {
    XCTAssertNotEqual(PensieveSettingsSection.mcp, .general)
    XCTAssertNotEqual(PensieveSettingsSection.mcp, .ai)
    XCTAssertNotEqual(PensieveSettingsSection.mcp, .appearance)

    let selection = PensieveSettingsSelection(selectedSection: .mcp)
    XCTAssertEqual(selection.selectedSection, .mcp)
  }

  func testTheTabViewHostsTheWizardOutsideTheAutocompleteProviderTab() throws {
    let view = try Self.source(of: "App/PensieveSettingsView.swift")
    XCTAssertTrue(
      view.contains("MCPSettingsWizard()"),
      "Settings must host the MCP wizard as its own pane")
    XCTAssertTrue(
      view.contains(".tag(PensieveSettingsSection.mcp)"),
      "an untagged tab cannot be selected as the MCP pane")
    XCTAssertTrue(
      view.contains("ProviderSettingsView(settings: providerSettings)"),
      "the AI tab stays the provider form")
    XCTAssertTrue(
      view.contains("MCPSettingsWizard()"),
      "the MCP wizard is a sibling tab, not a section of Autocomplete")

    let provider = try Self.source(of: "App/ProviderSettingsView.swift")
    XCTAssertFalse(
      provider.contains("MCPSettingsWizard"),
      "Autocomplete / provider settings must not grow the MCP wizard")
    XCTAssertFalse(provider.contains("VibecraftedMCPClient"))
  }

  func testWizardAccessibilityContractIsStable() {
    XCTAssertEqual(MCPSettingsWizard.paneIdentifier, "pensieve.settings.mcp")
    XCTAssertEqual(MCPSettingsWizard.statusIdentifier, "pensieve.settings.mcp.status")
    XCTAssertEqual(MCPSettingsWizard.detectIdentifier, "pensieve.settings.mcp.detect")
    XCTAssertEqual(MCPSettingsWizard.pointFieldIdentifier, "pensieve.settings.mcp.point")
    XCTAssertEqual(MCPSettingsWizard.pointApplyIdentifier, "pensieve.settings.mcp.point.apply")
  }

  func testWizardSourceIsDetectPointStatusOnly() throws {
    let wizard = try Self.source(of: "App/MCPSettingsWizard.swift")
    XCTAssertTrue(wizard.contains("Detect"))
    XCTAssertTrue(wizard.contains("Point"))
    XCTAssertTrue(wizard.contains("Status"))
    XCTAssertFalse(wizard.contains("addServer"))
    XCTAssertFalse(wizard.contains("listServers"))
    XCTAssertFalse(wizard.contains("CsMcpServer"))
  }

  func testDetectPointsAtTheFirstExecutableCandidate() {
    let pointing = MemoryVibecraftedMCPPointing()
    let transport = FakeVibecraftedMCPTransport(probeStatus: .connected)
    let client = VibecraftedMCPClient(
      pointing: pointing,
      transport: transport,
      isExecutable: { $0.hasSuffix("vibecrafted-mcp") },
      home: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
      environment: [:])

    let detected = client.detect()
    XCTAssertEqual(detected.first, "/Users/tester/.local/bin/vibecrafted-mcp")
    if let first = detected.first {
      client.point(to: first)
    }
    XCTAssertEqual(client.pointedCommandPath(), detected.first)
    XCTAssertEqual(client.status(refresh: true), .connected)
  }

  private static func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func source(of relativePath: String) throws -> String {
    try String(
      contentsOf: packageRoot().appendingPathComponent("Sources/Pensieve/\(relativePath)"),
      encoding: .utf8)
  }
}
