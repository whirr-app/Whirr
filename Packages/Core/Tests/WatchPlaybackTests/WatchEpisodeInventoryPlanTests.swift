import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

@Suite("Watch episode inventory plan")
struct WatchEpisodeInventoryPlanTests {
  private static let installID = "11111111-1111-4111-8111-111111111111"
  private static let observedAt = Date(timeIntervalSinceReferenceDate: 1_000)

  private func selection(_ index: Int, idLength: Int) throws -> WatchNativeSelection {
    func identifier(_ lead: Character, length: Int) -> String {
      let prefix = "\(lead)\(index)-"
      return String((prefix + String(repeating: "a", count: length)).prefix(length))
    }
    return try WatchNativeSelection(
      feedID: identifier("f", length: idLength), episodeID: identifier("e", length: idLength))
  }

  private func audioURL(_ index: Int) -> URL {
    URL(string: "https://cdn.example.test/audio/\(index).mp3")!
  }

  private func received(
    _ index: Int, state: WatchReceivedEpisode.State, idLength: Int = 8,
    committedBytes: Int64 = 100, progress: Double? = nil,
    failureReason: WatchEpisodeInventoryEntry.FailureReason = .network
  ) throws -> WatchReceivedEpisode {
    WatchReceivedEpisode(
      selection: try selection(index, idLength: idLength), revision: 1, state: state,
      declineReason: state == .declined ? .storageFull : nil,
      failureReason: state == .failed ? failureReason : nil,
      progress: state == .downloading ? progress : nil,
      title: "Episode \(index)", showTitle: "Show", duration: 120,
      enclosureURL: audioURL(index), declaredBytes: 1_000, mimeType: "audio/mpeg",
      chapters: [], phonePosition: 0, phoneLastListenedAt: nil,
      committedBytes: state == .ready ? committedBytes : nil, relativePath: "path-\(index)",
      offeredAt: Self.observedAt, updatedAt: Self.observedAt)
  }

  private func make(
    _ entries: [WatchReceivedEpisode], acceptsCopies: Bool = true,
    acknowledgedGeneration: UInt64 = 3, abs: WatchABSInventoryHalf? = nil
  ) throws -> WatchEpisodeInventory {
    try WatchEpisodeInventoryPlan.make(
      installID: Self.installID, sequence: 4, acknowledgedGeneration: acknowledgedGeneration,
      acceptsCopies: acceptsCopies, entries: entries, abs: abs, totalBytes: 2_000_000_000, usedBytes: 123,
      observedAt: Self.observedAt)
  }

  private func absEntry(_ index: Int, state: WatchABSInventoryEntry.State) throws -> WatchABSInventoryEntry {
    try WatchABSInventoryEntry(
      selection: WatchABSSelection(itemID: "book-\(index)", episodeID: nil), revision: 1, origin: .phone,
      state: state, trackCount: 2, completedTracks: state == .ready ? 2 : 0,
      declineReason: state == .declined ? .storageFull : nil, committedBytes: state == .ready ? 500 : nil)
  }

  private func absHalf(_ entries: [WatchABSInventoryEntry]) throws -> WatchABSInventoryHalf {
    WatchABSInventoryHalf(
      accountStamp: try accountStamp(account: "a", server: "s"), acknowledgedGeneration: 6, entries: entries)
  }

  @Test("each entry state maps to the matching inventory state")
  func mapsStates() throws {
    let entries = [
      try received(0, state: .receiving),
      try received(1, state: .ready, committedBytes: 42),
      try received(2, state: .declined),
      try received(3, state: .removed),
      try received(4, state: .downloading, progress: 0.42),
      try received(5, state: .waitingForNetwork),
      try received(6, state: .failed, failureReason: .tooLarge),
    ]
    let inventory = try make(entries)
    #expect(inventory.entries.count == 7)
    let bySelection = Dictionary(uniqueKeysWithValues: inventory.entries.map { ($0.selection, $0) })
    #expect(bySelection[entries[0].selection]?.state == .receiving)
    #expect(bySelection[entries[0].selection]?.committedBytes == nil)
    #expect(bySelection[entries[1].selection]?.state == .ready)
    #expect(bySelection[entries[1].selection]?.committedBytes == 42)
    #expect(bySelection[entries[2].selection]?.state == .declined)
    #expect(bySelection[entries[2].selection]?.declineReason == .storageFull)
    #expect(bySelection[entries[3].selection]?.state == .removed)
    #expect(bySelection[entries[4].selection]?.state == .downloading)
    #expect(bySelection[entries[4].selection]?.progress == 0.42)
    #expect(bySelection[entries[5].selection]?.state == .waitingForNetwork)
    #expect(bySelection[entries[6].selection]?.state == .failed)
    #expect(bySelection[entries[6].selection]?.failureReason == .tooLarge)
    #expect(inventory.acknowledgedGeneration == 3)
    #expect(inventory.budgetTotalBytes == 2_000_000_000)
    #expect(inventory.budgetUsedBytes == 123)
  }

  /// A download whose length the server did not give reports no percentage, not a zero.
  @Test("a downloading entry without a known length maps to a null progress")
  func downloadingWithoutProgress() throws {
    let entry = try received(0, state: .downloading, progress: nil)
    let inventory = try make([entry])
    #expect(inventory.entries.first?.progress == nil)
  }

  /// A hand-built entry that never recorded a reason still produces a valid failure.
  @Test("a failed entry without a reason maps to an invalid response")
  func failedWithoutReason() throws {
    var entry = try received(0, state: .downloading)
    entry.state = .failed
    entry.progress = nil
    entry.failureReason = nil
    let inventory = try make([entry])
    #expect(inventory.entries.first?.failureReason == .invalidResponse)
  }

  @Test("a signed-out Watch reports no copies and generation zero")
  func signedOutShape() throws {
    let entries = [try received(0, state: .ready), try received(1, state: .removed)]
    let inventory = try make(entries, acceptsCopies: false, acknowledgedGeneration: 7)
    #expect(inventory.entries.isEmpty)
    #expect(inventory.acknowledgedGeneration == 0)
    #expect(inventory.acceptsCopies == false)
    #expect(inventory.budgetTotalBytes == 2_000_000_000)
    #expect(inventory.budgetUsedBytes == 123)
  }

  @Test("one hundred ordinary entries fit the inventory cap without dropping any")
  func oneHundredOrdinaryEntriesFit() throws {
    let entries = try (0..<100).map { try received($0, state: .ready, idLength: 8) }
    let inventory = try make(entries)
    #expect(inventory.entries.count == 100)
    #expect(try WatchWireCodec.encode(inventory).count <= WatchEpisodeSendLimits.maxInventoryWireBytes)
  }

  /// A finding, not a cap to raise: 100 entries whose feed and episode identifiers are each the
  /// 512-byte maximum cannot fit 64 KiB, because each selection alone is about a kilobyte. The
  /// offer's own byte cap keeps such a set from being offered, and this is the planner's defensive
  /// bound for a set that arrived anyway.
  @Test("maximum-length identifiers exceed the cap, so ready copies are trimmed as a last resort")
  func maximumLengthIdentifiersAreTrimmed() throws {
    let entries = try (0..<100).map { try received($0, state: .ready, idLength: 512) }
    let inventory = try make(entries)
    #expect(inventory.entries.count < 100)
    #expect(inventory.entries.isEmpty == false)
    #expect(inventory.entries.allSatisfy { $0.state == .ready })
    #expect(try WatchWireCodec.encode(inventory).count <= WatchEpisodeSendLimits.maxInventoryWireBytes)
  }

  @Test("queued, failed and in-flight entries are dropped before removed and ready ones")
  func trimsInOrder() throws {
    var entries: [WatchReceivedEpisode] = []
    for index in 0..<10 { entries.append(try received(index, state: .receiving, idLength: 512)) }
    for index in 10..<20 { entries.append(try received(index, state: .declined, idLength: 512)) }
    for index in 20..<30 { entries.append(try received(index, state: .failed, idLength: 512)) }
    for index in 30..<40 { entries.append(try received(index, state: .downloading, idLength: 512)) }
    for index in 40..<50 { entries.append(try received(index, state: .removed, idLength: 512)) }
    for index in 50..<120 { entries.append(try received(index, state: .ready, idLength: 512)) }

    let inventory = try make(entries)
    #expect(inventory.entries.isEmpty == false)
    // Every queued, failed and in-flight entry goes first; the tombstones go next; only then may a
    // ready copy be dropped, because an omitted ready copy makes the phone offer a whole download
    // again.
    #expect(inventory.entries.allSatisfy { $0.state == .ready })
    #expect(inventory.entries.count < 70)
    #expect(try WatchWireCodec.encode(inventory).count <= WatchEpisodeSendLimits.maxInventoryWireBytes)
  }

  // MARK: Audiobookshelf half

  @Test("the Audiobookshelf half carries its own generation and account")
  func carriesTheAudiobookshelfHalf() throws {
    let half = try absHalf([absEntry(0, state: .ready), absEntry(1, state: .declined)])
    let inventory = try make([try received(0, state: .ready)], abs: half)
    #expect(inventory.absEntries == half.entries)
    #expect(inventory.absAcknowledgedGeneration == 6)
    #expect(inventory.absAccountStamp == half.accountStamp)
    #expect(inventory.acknowledgedGeneration == 3)

    let older = try make([try received(0, state: .ready)])
    #expect(older.absEntries == nil)
    #expect(older.absAccountStamp == nil)

    let signedOut = try make([try received(0, state: .ready)], acceptsCopies: false, abs: half)
    #expect(signedOut.absEntries == nil)
    #expect(signedOut.absAcknowledgedGeneration == nil)
    #expect(signedOut.absAccountStamp == nil)
  }

  /// One tier table over both lists: a declined row of either kind goes before a ready row of
  /// either kind, because an omitted ready row makes the phone send a whole download again.
  @Test("the combined trim drops declined first and ready last across both lists")
  func trimsAcrossBothLists() throws {
    let rssReady = try (0..<60).map { try received($0, state: .ready) }
    let absReady = try (0..<30).map { try absEntry($0, state: .ready) }
    let absDeclined = try (30..<45).map { try absEntry($0, state: .declined) }
    let inventory = try make(rssReady, abs: try absHalf(absReady + absDeclined))
    let abs = try #require(inventory.absEntries)
    #expect(inventory.entries.count + abs.count == WatchEpisodeSendLimits.maxInventoryEntries)
    #expect(inventory.entries.count == 60)
    #expect(abs.filter { $0.state == .ready }.count == 30)
    #expect(abs.filter { $0.state == .declined }.count == 10)

    let rssMixed =
      try (0..<95).map { try received($0, state: .ready) }
      + (95..<98).map { try received($0, state: .declined) }
    let kept = try make(rssMixed, abs: try absHalf((0..<5).map { try absEntry($0, state: .ready) }))
    #expect(kept.absEntries?.count == 5)
    #expect(kept.entries.count == 95)
    #expect(kept.entries.allSatisfy { $0.state == .ready })
  }

  @Test("more entries than the wire allows are bounded before encoding")
  func boundsTheEntryCount() throws {
    let entries = try (0..<110).map { try received($0, state: .ready, idLength: 8) }
    let inventory = try make(entries)
    #expect(inventory.entries.count == WatchEpisodeSendLimits.maxInventoryEntries)
  }
}
