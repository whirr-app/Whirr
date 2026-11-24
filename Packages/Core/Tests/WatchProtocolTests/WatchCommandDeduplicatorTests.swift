import Foundation
import Testing

@testable import WatchProtocol

@Suite("WatchProtocol safety")
struct WatchCommandDeduplicatorTests {
  private let account = WatchProtocolFixtures.accountStamp()

  @Test func duplicateInFlightDoesNotExecuteTwiceAndReplaysReply() async throws {
    let command = try WatchCommand(accountStamp: account, selection: .audiobookshelf(itemID: "book", episodeID: nil))
    let deduplicator = WatchCommandDeduplicator(capacity: 2)
    #expect(try await deduplicator.begin(command) == .execute)
    #expect(try await deduplicator.begin(command) == .inFlight)
    let reply = WatchReply.accepted(commandID: command.id)
    #expect(try await deduplicator.complete(command, with: reply))
    #expect(try await deduplicator.begin(command) == .replay(reply))
  }

  @Test func conflictingReuseIsRejectedAndInFlightSaturationFailsClosed() async throws {
    let first = try WatchCommand(accountStamp: account, selection: .audiobookshelf(itemID: "one", episodeID: nil))
    let conflicting = try WatchCommand(
      id: first.id, accountStamp: account, selection: .audiobookshelf(itemID: "two", episodeID: nil))
    let second = try WatchCommand(accountStamp: account, selection: .audiobookshelf(itemID: "two", episodeID: nil))
    let deduplicator = WatchCommandDeduplicator(capacity: 2)
    #expect(try await deduplicator.begin(first) == .execute)
    #expect(try await deduplicator.begin(conflicting) == .conflict)
    #expect(try await deduplicator.begin(second) == .execute)
    let third = try WatchCommand(accountStamp: account, selection: .audiobookshelf(itemID: "three", episodeID: nil))
    #expect(try await deduplicator.begin(third) == .saturated)
  }

  @Test func completedIDsRemainRetainedUntilAdmissionWindowExpires() async throws {
    let origin = Date(timeIntervalSinceReferenceDate: 1_000)
    let first = try WatchCommand(
      accountStamp: account, selection: .audiobookshelf(itemID: "one", episodeID: nil), issuedAt: origin)
    let second = try WatchCommand(
      accountStamp: account, selection: .audiobookshelf(itemID: "two", episodeID: nil), issuedAt: origin)
    let third = try WatchCommand(
      accountStamp: account, selection: .audiobookshelf(itemID: "three", episodeID: nil),
      issuedAt: origin.addingTimeInterval(121))
    let deduplicator = WatchCommandDeduplicator(capacity: 1)
    #expect(try await deduplicator.begin(first, now: origin) == .execute)
    try await deduplicator.complete(first, with: .accepted(commandID: first.id))
    #expect(try await deduplicator.begin(first, now: origin.addingTimeInterval(10)) != .execute)
    // A full cache evicts the oldest completed entry rather than refusing a fresh command.
    #expect(try await deduplicator.begin(second, now: origin.addingTimeInterval(10)) == .execute)
    try await deduplicator.complete(second, with: .accepted(commandID: second.id))
    #expect(try await deduplicator.begin(third, now: origin.addingTimeInterval(121)) == .execute)
    #expect(try await deduplicator.begin(first, now: origin.addingTimeInterval(122)) == .expired)
  }

  @Test func burstAboveCapacityEvictsOldestAndNeverRejectsFreshCommands() async throws {
    let origin = Date(timeIntervalSinceReferenceDate: 3_000)
    let deduplicator = WatchCommandDeduplicator(capacity: 4)
    var commands: [WatchCommand] = []
    for index in 0..<10 {
      let issued = origin.addingTimeInterval(Double(index) * 0.1)
      let command = try WatchCommand(
        accountStamp: account, selection: .audiobookshelf(itemID: "book", episodeID: nil),
        action: .skip, value: Double(index + 1), issuedAt: issued)
      commands.append(command)
      #expect(try await deduplicator.begin(command, now: issued) == .execute)
      try await deduplicator.complete(command, with: .accepted(commandID: command.id))
    }
    let now = origin.addingTimeInterval(2)
    #expect(await deduplicator.count() == 4)
    // The newest ids are still replays; the evicted oldest are not retained.
    #expect(try await deduplicator.begin(commands[9], now: now) == .replay(.accepted(commandID: commands[9].id)))
    #expect(try await deduplicator.begin(commands[6], now: now) != .execute)
    #expect(await deduplicator.contains(commands[0].id) == false)
  }

  @Test func defaultCapacityCoversACrownBurstWithinTheAdmissionWindow() async throws {
    let origin = Date(timeIntervalSinceReferenceDate: 4_000)
    let deduplicator = WatchCommandDeduplicator()
    var first: WatchCommand?
    // Ten commands a second for a full admission window is far above a Digital Crown burst.
    for index in 0..<100 {
      let issued = origin.addingTimeInterval(Double(index) * 0.1)
      let command = try WatchCommand(
        accountStamp: account, selection: .audiobookshelf(itemID: "book", episodeID: nil),
        action: .skip, value: Double(index + 1), issuedAt: issued)
      if first == nil { first = command }
      #expect(try await deduplicator.begin(command, now: issued) == .execute)
      try await deduplicator.complete(command, with: .accepted(commandID: command.id))
    }
    let replay = try await deduplicator.begin(try #require(first), now: origin.addingTimeInterval(11))
    #expect(replay != .execute)
  }

  @Test func exactAdmissionBoundaryExpiresAndCannotBeReexecuted() async throws {
    let origin = Date(timeIntervalSinceReferenceDate: 2_000)
    let command = try WatchCommand(
      accountStamp: account, selection: .audiobookshelf(itemID: "boundary", episodeID: nil), issuedAt: origin)
    let deduplicator = WatchCommandDeduplicator(capacity: 1)
    #expect(try await deduplicator.begin(command, now: origin) == .execute)
    try await deduplicator.complete(command, with: .accepted(commandID: command.id))
    #expect(
      try await deduplicator.begin(
        command, now: origin.addingTimeInterval(WatchProtocolVersion.commandAdmissionWindow)) == .expired)
  }

  @Test func admissionWindowIsHalfOpenAroundItsBoundary() async throws {
    let origin = Date(timeIntervalSinceReferenceDate: 3_000)
    for (age, expected) in [
      (119.0, WatchDeduplicationDecision.execute), (120.0, .expired), (121.0, .expired),
    ] {
      let command = try WatchCommand(
        accountStamp: account, selection: .audiobookshelf(itemID: "edge", episodeID: nil), issuedAt: origin)
      let deduplicator = WatchCommandDeduplicator()
      #expect(try await deduplicator.begin(command, now: origin.addingTimeInterval(age)) == expected)
    }
  }

  @Test func destinationSupportKeepsUnsentNativeFeedsPhoneOnly() throws {
    let native = WatchSelection.nativeFeed(feedID: "feed", episodeID: "episode")
    let capabilities = WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true)
    #expect(WatchDestinationPreference.supports(.phone, selection: native, capabilities: capabilities))
    #expect(!WatchDestinationPreference.supports(.watch, selection: native, capabilities: capabilities))
  }

  /// ADR 0019: the wire never claims Watch playability for a native feed, so a Watch-local copy is
  /// the only thing that makes it watch-playable, and it does so whatever the capabilities say.
  @Test func destinationSupportForANativeFeedFollowsTheWatchCopy() throws {
    let native = WatchSelection.nativeFeed(feedID: "feed", episodeID: "episode")
    let wire = WatchSelectionCapabilities(phonePlayable: true, watchPlayable: false)
    #expect(!WatchDestinationPreference.supports(.watch, selection: native, capabilities: wire))
    #expect(
      WatchDestinationPreference.supports(.watch, selection: native, capabilities: wire, hasLocalCopy: true))
    #expect(WatchDestinationPreference.supports(.phone, selection: native, capabilities: wire))

    let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    #expect(
      WatchDestinationPreference.supports(
        .watch, selection: book, capabilities: .init(phonePlayable: true, watchPlayable: true)))
    #expect(
      !WatchDestinationPreference.supports(
        .watch, selection: book, capabilities: .init(phonePlayable: true, watchPlayable: false)))
    #expect(
      WatchDestinationPreference.supports(
        .watch, selection: book, capabilities: .init(phonePlayable: true, watchPlayable: false),
        hasLocalCopy: true) == false)
  }
}
