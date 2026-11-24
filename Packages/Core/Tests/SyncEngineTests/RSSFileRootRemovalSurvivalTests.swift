import Foundation
import Persistence
import Testing

@testable import SyncEngine

/// RSS enclosure files occupy a device-owned sibling of each account's downloads directory.
@Suite struct RSSFileRootRemovalSurvivalTests {

  @Test func accountRemovalLeavesTheRSSFileRootIntact() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database, withDownloadFile: true)
    let rssRoot = harness.downloadsRootURL.appendingPathComponent(
      RSSFileRoot.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: rssRoot, withIntermediateDirectories: true)
    let enclosure = rssRoot.appendingPathComponent("episode.mp3")
    try Data([0x52, 0x53, 0x53]).write(to: enclosure)

    let coordinator = harness.makeCoordinator(database: database)
    try await coordinator.confirmRemoval()

    #expect(
      FileManager.default.fileExists(
        atPath: harness.downloadsRootURL.appendingPathComponent("\(accountId)").path) == false)
    #expect(FileManager.default.fileExists(atPath: rssRoot.path))
    #expect(FileManager.default.fileExists(atPath: enclosure.path))
  }
}
