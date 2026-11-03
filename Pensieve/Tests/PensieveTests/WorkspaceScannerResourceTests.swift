import Darwin
import XCTest

@testable import Pensieve

@MainActor
final class WorkspaceScannerResourceTests: XCTestCase {
  func testGitIgnoreScanBoundsTemporaryMemoryWithoutDroppingDocuments() async throws {
    try await assertBoundedScan(folderCount: 20, filesPerFolder: 500)
  }

  func testSingleLargeDirectoryBoundsTemporaryMemoryWithoutDroppingDocuments() async throws {
    try await assertBoundedScan(folderCount: 1, filesPerFolder: 10_000)
  }

  private func assertBoundedScan(folderCount: Int, filesPerFolder: Int) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveScannerResources-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try autoreleasepool {
      let rules = (0..<40).map { "unmatched-\($0)-*.tmp" }.joined(separator: "\n")
      try rules.write(
        to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      for folderIndex in 0..<folderCount {
        let folder = root.appendingPathComponent("folder-\(folderIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for fileIndex in 0..<filesPerFolder {
          try "# Note".write(
            to: folder.appendingPathComponent("note-\(fileIndex).md"), atomically: true,
            encoding: .utf8)
        }
      }
    }

    let task = Task<Measurement, Never>.detached { [root] in
      WorkspaceScannerResourceTests.measureScan(at: root)
    }
    let measurement = await task.value

    print(
      "Scanner footprint delta: before drain=\(measurement.live), after drain=\(measurement.drained) bytes"
    )
    XCTAssertEqual(
      measurement.count, 10_000, "Memory must not be saved by truncating the workspace")
    XCTAssertEqual(
      measurement.visibleDocuments, 10_000, "The sidebar must retain every document node")
    XCTAssertLessThan(
      measurement.live, 64 * 1_024 * 1_024,
      "A 10,000-document scan must bound temporary Foundation allocations within the worker")
  }

  private struct Measurement: Sendable {
    let count: Int
    let visibleDocuments: Int
    let live: UInt64
    let drained: UInt64
  }

  nonisolated private static func measureScan(at root: URL) -> Measurement {
    // Warm Foundation before measuring. Keep the scan's complete result alive inside an outer
    // pool: a worker must bound its own temporary objects, not depend on when its executor drains.
    autoreleasepool {
      _ = WorkspaceScanner.build(
        rootURLs: [root.appendingPathComponent("folder-0")], exclusions: [])
    }
    let before = physicalFootprint()
    let result = autoreleasepool {
      let scans = WorkspaceScanner.build(rootURLs: [root], exclusions: [])
      return withExtendedLifetime(scans) {
        let footprint = physicalFootprint()
        let visibleDocuments =
          scans.first?.rootNode.children?.reduce(0) {
            $0 + ($1.children?.count ?? 0)
          } ?? 0
        return (
          count: scans.first?.documents.count ?? 0, footprint: footprint,
          visibleDocuments: visibleDocuments
        )
      }
    }
    let afterDrain = physicalFootprint()
    return Measurement(
      count: result.count, visibleDocuments: result.visibleDocuments,
      live: result.footprint > before ? result.footprint - before : 0,
      drained: afterDrain > before ? afterDrain - before : 0)
  }

  nonisolated private static func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    precondition(status == KERN_SUCCESS, "Cannot measure the test process's physical footprint")
    return info.phys_footprint
  }
}
