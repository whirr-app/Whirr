import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// The ledger outlives a launch too short to plan a book, and is fenced by the account that wrote it.
@Suite("Watch ABS request ledger file")
struct WatchABSRequestLedgerFileTests {
  @Test func aSavedLedgerLoadsForItsAccountOnly() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("ABSRequests", isDirectory: true).appendingPathComponent("ledger.json")
    let stamp = try accountStamp(account: "a", server: "s")
    let file = WatchABSRequestLedgerFile(fileURL: url, accountStamp: stamp)
    #expect(try file.load() == nil)

    var ledger = WatchABSRequestLedger()
    let offer = try WatchABSSendOffer(
      generation: 4, watchInstallID: nil, accountStamp: stamp,
      entries: [
        WatchABSOfferEntry(
          selection: WatchABSSelection(itemID: "book-1", episodeID: nil), revision: 2, title: "Book",
          subtitle: nil, declaredBytes: nil, position: nil)
      ], removals: [], sentAt: Date(timeIntervalSinceReferenceDate: 100), inventorySequence: 7)
    #expect(ledger.accept(offer, installID: "install", accountStamp: stamp) == .accepted)
    ledger.record(.failed(.network), for: try WatchABSSelection(itemID: "book-1", episodeID: nil), revision: 2)
    ledger.markApplied(generation: 4)
    try file.save(ledger)
    #expect(try file.load() == ledger)

    let other = WatchABSRequestLedgerFile(fileURL: url, accountStamp: try accountStamp(account: "b", server: "s"))
    #expect(throws: WatchABSRequestLedgerFile.LoadError.foreignAccount) { try other.load() }

    try Data("not json".utf8).write(to: url)
    #expect(throws: WatchABSRequestLedgerFile.LoadError.corrupt) { try file.load() }
  }
}
