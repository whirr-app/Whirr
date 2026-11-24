import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

@Suite("Watch episode install identity")
struct WatchEpisodeInstallStoreTests {
  @Test("the install identity is a lowercase UUID and survives a new instance")
  func identityIsStable() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("WatchEpisodeInstall.json")
    let store = try WatchEpisodeInstallStore(fileURL: fileURL)
    let id = try await store.installID()
    #expect(UUID(uuidString: id) != nil)
    #expect(id == id.lowercased())

    let restarted = try WatchEpisodeInstallStore(fileURL: fileURL)
    #expect(try await restarted.installID() == id)
  }

  @Test("sequences strictly increase across instances and stay independent")
  func sequencesIncreaseAcrossInstances() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("WatchEpisodeInstall.json")
    let store = try WatchEpisodeInstallStore(fileURL: fileURL)
    #expect(try await store.nextInventorySequence() == 1)
    #expect(try await store.nextInventorySequence() == 2)
    #expect(try await store.nextProgressSequence() == 1)

    let restarted = try WatchEpisodeInstallStore(fileURL: fileURL)
    #expect(try await restarted.nextInventorySequence() == 3)
    #expect(try await restarted.nextProgressSequence() == 2)
  }

  @Test("a corrupt file yields a new identity with sequences starting at one")
  func corruptFileStartsFresh() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("WatchEpisodeInstall.json")
    try Data("broken".utf8).write(to: fileURL)

    let store = try WatchEpisodeInstallStore(fileURL: fileURL)
    let id = try await store.installID()
    #expect(UUID(uuidString: id) != nil)
    #expect(id == id.lowercased())
    #expect(try await store.nextInventorySequence() == 1)
    #expect(try await store.nextProgressSequence() == 1)
  }

  @Test("an identity that is not a canonical lowercase UUID is replaced")
  func invalidIdentityIsReplaced() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("WatchEpisodeInstall.json")
    let payload = WatchEpisodeInstallStore.Payload(
      installID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", inventorySequence: 9,
      progressSequence: 9)
    try JSONEncoder().encode(payload).write(to: fileURL)

    let store = try WatchEpisodeInstallStore(fileURL: fileURL)
    let id = try await store.installID()
    #expect(id != payload.installID)
    #expect(id == id.lowercased())
    #expect(try await store.nextInventorySequence() == 1)
  }
}
