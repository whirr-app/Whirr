import Foundation
import Testing

@testable import WatchPlayback

@Suite("Watch download file vault")
struct WatchDownloadFileVaultTests {
  @Test("destination containment rejects absolute and parent paths")
  func containment() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try WatchDownloadFileVault(rootURL: root)
    for path in ["", "../outside", "/outside", "nested/../../outside"] {
      #expect(throws: WatchDownloadStoreError.invalidSelection) {
        try vault.destinationFile(relativePath: path)
      }
    }
  }

  @Test("symlink sources and destination parents are rejected")
  func symlinks() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try WatchDownloadFileVault(rootURL: root)
    let source = root.appendingPathComponent("source")
    try Data([1, 2]).write(to: source)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: WatchDownloadStoreError.temporaryFileIsSymlink) {
      try vault.measuredTemporaryFile(link, expectedBytes: 2, responseBytes: 2)
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("files/escape"), withDestinationURL: root)
    #expect(throws: WatchDownloadStoreError.storageFailure) {
      try vault.install(source, relativePath: "escape/audio", measured: 2)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("byte mismatch preserves the source and never installs a file")
  func byteMismatch() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try WatchDownloadFileVault(rootURL: root)
    let source = root.appendingPathComponent("source")
    try Data([1, 2]).write(to: source)
    #expect(throws: WatchDownloadStoreError.fileSizeMismatch) {
      try vault.measuredTemporaryFile(source, expectedBytes: 3, responseBytes: nil)
    }
    #expect(throws: WatchDownloadStoreError.fileSizeMismatch) {
      try vault.measuredTemporaryFile(source, expectedBytes: 2, responseBytes: 3)
    }
    #expect(throws: WatchDownloadStoreError.fileSizeMismatch) {
      try vault.install(source, relativePath: "audio", measured: 3)
    }
    #expect(try Data(contentsOf: source) == Data([1, 2]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("files").path).isEmpty)
  }

  @Test("install moves the source rather than copying it")
  func installMoves() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try WatchDownloadFileVault(rootURL: root)
    let source = root.appendingPathComponent("source")
    try Data([1, 2]).write(to: source)
    let before = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
    try vault.install(source, relativePath: "audio", measured: 2)
    let destination = root.appendingPathComponent("files/audio")
    let after = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber
    #expect(before == after)
    #expect(FileManager.default.fileExists(atPath: source.path) == false)
    #expect(try Data(contentsOf: destination) == Data([1, 2]))
  }
}
