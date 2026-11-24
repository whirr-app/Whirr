import Foundation
import Testing

@testable import WatchPlayback

@Suite("Watch protected file store")
struct WatchProtectedFileStoreTests {
  @Test("a key round-trips, reads absent as nil, and clears")
  func roundTrip() throws {
    let parent = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let store = WatchProtectedFileStore(rootURL: parent.appendingPathComponent("WatchProtected"))
    let settings = try store.settings(forKey: "watch.account.record.v1")

    #expect(try settings.load() == nil)
    try settings.save(Data("one".utf8))
    #expect(try settings.load() == Data("one".utf8))
    try settings.save(Data("two".utf8))
    #expect(try store.load(key: "watch.account.record.v1") == Data("two".utf8))
    try settings.clear()
    #expect(try settings.load() == nil)
    try settings.clear()
  }

  @Test("the initialiser does not touch the disk")
  func initialiserIsLazy() throws {
    let parent = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("WatchProtected")
    let store = WatchProtectedFileStore(rootURL: root)
    #expect(try store.load(key: "watch.resume.bookmark") == nil)
    #expect(FileManager.default.fileExists(atPath: root.path) == false)
  }

  @Test("an unreadable file throws instead of reading as absent")
  func unreadableIsNotAbsent() throws {
    let parent = try temporaryDirectory()
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: parent.appendingPathComponent("WatchProtected/k").path)
      try? FileManager.default.removeItem(at: parent)
    }
    let store = WatchProtectedFileStore(rootURL: parent.appendingPathComponent("WatchProtected"))
    try store.save(Data("x".utf8), key: "k")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: store.rootURL.appendingPathComponent("k").path)

    #expect(throws: WatchProtectedFileStoreError.unreadable) { try store.load(key: "k") }
    #expect(FileManager.default.fileExists(atPath: store.rootURL.appendingPathComponent("k").path))
  }

  @Test(
    "keys that could name another path are refused",
    arguments: ["", "/etc", "../x", "a/b", "..", ".hidden", "Upper", "a b", String(repeating: "a", count: 129)])
  func invalidKeys(key: String) throws {
    let parent = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let store = WatchProtectedFileStore(rootURL: parent.appendingPathComponent("WatchProtected"))
    #expect(throws: WatchProtectedFileStoreError.invalidKey) { try store.settings(forKey: key) }
    #expect(throws: WatchProtectedFileStoreError.invalidKey) { try store.save(Data(), key: key) }
    #expect(throws: WatchProtectedFileStoreError.invalidKey) { try store.load(key: key) }
    #expect(throws: WatchProtectedFileStoreError.invalidKey) { try store.clear(key: key) }
  }

  @Test("a prefix clear removes only matching keys")
  func prefixClear() throws {
    let parent = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let store = WatchProtectedFileStore(rootURL: parent.appendingPathComponent("WatchProtected"))
    try store.save(Data("a".utf8), key: "watch.download.labels.aaa")
    try store.save(Data("b".utf8), key: "watch.download.labels.bbb")
    try store.save(Data("c".utf8), key: "watch.resume.bookmark")

    try store.clear(keysWithPrefix: "watch.download.labels.")

    #expect(try store.load(key: "watch.download.labels.aaa") == nil)
    #expect(try store.load(key: "watch.download.labels.bbb") == nil)
    #expect(try store.load(key: "watch.resume.bookmark") == Data("c".utf8))
    #expect(throws: WatchProtectedFileStoreError.invalidKey) { try store.clear(keysWithPrefix: "../") }
    // A prefix clear on a store that never wrote is a no-op.
    let empty = WatchProtectedFileStore(rootURL: parent.appendingPathComponent("Never"))
    try empty.clear(keysWithPrefix: "watch.")
  }

  @Test("a symlinked root or file is refused, a symlinked ancestor is not")
  func symlinks() throws {
    let parent = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let elsewhere = parent.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

    let linkedRoot = parent.appendingPathComponent("LinkedRoot")
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: elsewhere)
    let rootStore = WatchProtectedFileStore(rootURL: linkedRoot)
    #expect(throws: WatchProtectedFileStoreError.symlink) { try rootStore.save(Data("x".utf8), key: "k") }
    #expect(throws: WatchProtectedFileStoreError.symlink) { try rootStore.load(key: "k") }

    let store = WatchProtectedFileStore(rootURL: parent.appendingPathComponent("WatchProtected"))
    try store.save(Data("x".utf8), key: "real")
    let target = elsewhere.appendingPathComponent("secret")
    try Data("secret".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: store.rootURL.appendingPathComponent("linked"), withDestinationURL: target)
    #expect(throws: WatchProtectedFileStoreError.symlink) { try store.load(key: "linked") }
    #expect(throws: WatchProtectedFileStoreError.symlink) { try store.save(Data("y".utf8), key: "linked") }
    #expect(try Data(contentsOf: target) == Data("secret".utf8))

    // Only the root and the file are checked: macOS temp paths sit under `/var -> /private/var`.
    let alias = parent.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
    let ancestorStore = WatchProtectedFileStore(rootURL: alias.appendingPathComponent("WatchProtected"))
    #expect(try ancestorStore.load(key: "real") == Data("x".utf8))
  }

  @Test("a read tells absent, unreadable, undecodable and a value apart")
  func readOutcomes() throws {
    struct Failure: Error {}
    let decode: (Data) throws -> String = { data in
      guard let text = String(data: data, encoding: .utf8), text != "bad" else { throw Failure() }
      return text
    }
    let absent = WatchProtectedRead<String>({ nil }, decode: decode)
    let unreadable = WatchProtectedRead<String>({ throw WatchProtectedFileStoreError.unreadable }, decode: decode)
    let undecodable = WatchProtectedRead<String>({ Data("bad".utf8) }, decode: decode)
    let value = WatchProtectedRead<String>({ Data("ok".utf8) }, decode: decode)

    guard case .absent = absent, case .unreadable = unreadable, case .undecodable = undecodable,
      case .value("ok") = value
    else {
      Issue.record("wrong outcomes: \(absent) \(unreadable) \(undecodable) \(value)")
      return
    }
    #expect(absent.isSettled && undecodable.isSettled && value.isSettled)
    #expect(unreadable.isSettled == false)
    #expect(value.value == "ok" && absent.value == nil && unreadable.value == nil)
  }

  @Test("the file and its directory are excluded from backup")
  func backupExclusion() throws {
    let parent = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let store = WatchProtectedFileStore(rootURL: parent.appendingPathComponent("WatchProtected"))
    try store.save(Data("x".utf8), key: "k")
    let file = store.rootURL.appendingPathComponent("k")
    #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(try store.rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  }
}
