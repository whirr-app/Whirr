import Foundation
import Testing

@testable import WatchPlayback

@Suite("Watch received episode inbox")
struct WatchReceivedEpisodeInboxTests {
  @Test("the inbox lives under the application support directory")
  func directoryIsInsideApplicationSupport() {
    let root = URL(fileURLWithPath: "/tmp/application-support")
    let directory = WatchReceivedEpisodeInbox.directory(applicationSupport: root)

    #expect(directory.deletingLastPathComponent().path == root.path)
    #expect(directory.lastPathComponent == "WatchEpisodeInbox")
    #expect(directory.hasDirectoryPath)
  }

  @Test("purge removes old leftovers of either kind and keeps recent ones")
  func purgeRemovesOldLeftovers() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = WatchReceivedEpisodeInbox.directory(applicationSupport: root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let old = directory.appendingPathComponent("old").appendingPathExtension("audio")
    let recent = directory.appendingPathComponent("recent").appendingPathExtension("audio")
    let oldSidecar = directory.appendingPathComponent("old-sidecar").appendingPathExtension("json")
    let recentSidecar = directory.appendingPathComponent("recent-sidecar").appendingPathExtension("json")
    for url in [old, recent, oldSidecar, recentSidecar] { try Data([1, 2, 3]).write(to: url) }
    for url in [old, oldSidecar] {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceReferenceDate: 100)], ofItemAtPath: url.path)
    }

    WatchReceivedEpisodeInbox.purge(
      olderThan: Date(timeIntervalSinceNow: -60), directory: directory)

    #expect(FileManager.default.fileExists(atPath: old.path) == false)
    #expect(FileManager.default.fileExists(atPath: oldSidecar.path) == false)
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(FileManager.default.fileExists(atPath: recentSidecar.path))
  }

  @Test("removeAll deletes the inbox directory")
  func removeAllDeletesTheDirectory() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = WatchReceivedEpisodeInbox.directory(applicationSupport: root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([1]).write(to: directory.appendingPathComponent("left-behind.audio"))

    WatchReceivedEpisodeInbox.removeAll(directory: directory)

    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
  }
}
