import SwiftUI

/// Settings ▸ MCP — wizard v1. Detect, point, status. Not a supermarket, and
/// not inside the Autocomplete / provider tab.
struct MCPSettingsWizard: View {
  static let paneIdentifier = "pensieve.settings.mcp"
  static let statusIdentifier = "pensieve.settings.mcp.status"
  static let detectIdentifier = "pensieve.settings.mcp.detect"
  static let pointFieldIdentifier = "pensieve.settings.mcp.point"
  static let pointApplyIdentifier = "pensieve.settings.mcp.point.apply"

  let client: VibecraftedMCPClient
  @State private var pointedPath: String
  @State private var status: VibecraftedMCPConnectionStatus
  @State private var detectedPaths: [String]

  init(client: VibecraftedMCPClient = .shared) {
    self.client = client
    _pointedPath = State(initialValue: client.pointedCommandPath() ?? "")
    _status = State(initialValue: client.status())
    _detectedPaths = State(initialValue: [])
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("MCP")
          .font(.title2.weight(.semibold))
        Text("Pensieve talks to one vibecrafted-mcp server. Detect it, or point at it.")
          .foregroundStyle(.secondary)
      }

      Form {
        LabeledContent("Status") {
          Text(status.shortLabel)
            .fontWeight(.semibold)
            .foregroundStyle(statusColor)
            .accessibilityIdentifier(Self.statusIdentifier)
        }

        TextField("Command path", text: $pointedPath)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12, design: .monospaced))
          .accessibilityIdentifier(Self.pointFieldIdentifier)

        HStack {
          Button("Detect") { detect() }
            .accessibilityIdentifier(Self.detectIdentifier)
          Button("Point") { applyPoint() }
            .accessibilityIdentifier(Self.pointApplyIdentifier)
        }
      }
      .formStyle(.grouped)

      VStack(alignment: .leading, spacing: 5) {
        Text(status.refusalExplanation)
        if !detectedPaths.isEmpty {
          Text("Detected: \(detectedPaths.joined(separator: ", "))")
            .lineLimit(2)
            .truncationMode(.middle)
        }
        Text("Agent dispatch runs only while this status is Connected. There is no CLI fallback.")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(width: 560, height: 540, alignment: .topLeading)
    .accessibilityIdentifier(Self.paneIdentifier)
    .onAppear { refresh() }
  }

  private var statusColor: Color {
    switch status {
    case .connected: return .green
    case .unreachable: return .orange
    case .notConfigured: return .secondary
    }
  }

  private func detect() {
    detectedPaths = client.detect()
    if let first = detectedPaths.first {
      client.point(to: first)
      pointedPath = first
    }
    status = client.refreshStatus()
  }

  private func applyPoint() {
    client.point(to: pointedPath)
    status = client.refreshStatus()
    detectedPaths = client.detect()
  }

  private func refresh() {
    pointedPath = client.pointedCommandPath() ?? pointedPath
    detectedPaths = client.detect()
    status = client.refreshStatus()
  }
}
