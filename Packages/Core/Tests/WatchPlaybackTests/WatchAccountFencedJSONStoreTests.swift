import Foundation
import Testing

@testable import WatchPlayback

@Suite("Watch account-fenced JSON")
struct WatchAccountFencedJSONStoreTests {
  private struct Payload: Codable, Sendable, Equatable {
    let date: Date
    let count: Int
  }

  @Test("settings and file envelopes round trip with millisecond dates", arguments: [false, true])
  func roundTrip(file: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let memory = LockedMemorySettings()
    let url = root.appendingPathComponent("value.json")
    let store = WatchAccountFencedJSONStore<Payload>(
      location: file ? .file(url) : .settings(memory), accountStamp: try accountStamp(account: "a", server: "s"))
    #expect(try store.load() == nil)
    let value = Payload(date: Date(timeIntervalSince1970: 1234.5), count: 2)
    try store.save(value)
    #expect(try store.load() == value)
    let data = try file ? Data(contentsOf: url) : #require(try memory.load())
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["version", "accountStamp", "date", "count"])
    #expect(json["date"] as? Double == 1_234_500)
    try store.save(value)
    #expect(try store.load() == value)
  }

  @Test("corrupt, version, account and I/O failures stay distinct")
  func failures() throws {
    let memory = LockedMemorySettings()
    let store = WatchAccountFencedJSONStore<Payload>(
      location: .settings(memory), accountStamp: try accountStamp(account: "a", server: "s"))
    try memory.save(Data("broken".utf8))
    #expect(throws: WatchFencedStoreError.self) { try store.load() }
    do { _ = try store.load() } catch WatchFencedStoreError.corrupt {} catch { Issue.record("wrong error: \(error)") }
    var newer = store
    newer.version = 2
    try newer.save(Payload(date: Date(timeIntervalSince1970: 100), count: 1))
    do {
      _ = try store.load()
      Issue.record("accepted version")
    } catch WatchFencedStoreError.versionMismatch {} catch { Issue.record("wrong error: \(error)") }
    let foreign = WatchAccountFencedJSONStore<Payload>(
      location: .settings(memory), accountStamp: try accountStamp(account: "other", server: "s"))
    try foreign.save(Payload(date: Date(timeIntervalSince1970: 100), count: 1))
    do {
      _ = try store.load()
      Issue.record("accepted account")
    } catch WatchFencedStoreError.foreignAccount {} catch { Issue.record("wrong error: \(error)") }
    memory.failNextSave()
    do {
      try store.save(Payload(date: Date(timeIntervalSince1970: 100), count: 1))
      Issue.record("ignored write failure")
    } catch WatchFencedStoreError.io(let error) { #expect(error as? WatchLibraryError == .storageFailure) } catch {
      Issue.record("wrong error: \(error)")
    }
  }
}
