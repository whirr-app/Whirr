import Foundation
import Testing

@testable import Whirr

@MainActor
@Suite("Filesystem capacity reporting")
struct FileSystemFreeSpaceReportingTests {
  @Test("an unreadable capacity fails open for scheduling and stays unavailable for Settings")
  func unavailableCapacityKeepsEachBoundaryContract() async {
    let missingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "missing-capacity-root-\(UUID().uuidString)", isDirectory: true)

    #expect(
      FileSystemFreeSpaceReporting(rootURL: missingRoot).availableCapacityBytes() == Int64.max)
    #expect(
      await FileSystemDeviceStorageCapacityReader(rootURL: missingRoot).availableCapacityBytes()
        == nil)
  }
}
