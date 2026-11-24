import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite("RSS notification delivery")
struct RSSNotificationDeliveryCoordinatorTests {
  @Test("system permission gates delivery")
  func gates() async throws {
    let ledger = NotificationLedgerFake(candidates: [.episode(feed: 1, key: "a")])
    let scheduler = NotificationSchedulerFake(status: .denied)
    let coordinator = RSSNotificationDeliveryCoordinator(
      ledger: ledger, intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: scheduler)

    await coordinator.completeBackgroundRefresh(now: Date(timeIntervalSince1970: 1_000))
    #expect(await scheduler.requests.isEmpty)
    #expect(await ledger.marked.isEmpty)
  }

  @Test("an explicitly enabled feed can override the global default")
  func feedOverride() async throws {
    let inherited = try await makePendingCandidate(feedName: "Inherited", key: "inherited")
    let explicitlyEnabled = try await makePendingCandidate(feedName: "Enabled", key: "enabled")
    let explicitlyDisabled = try await makePendingCandidate(feedName: "Disabled", key: "disabled")
    try await RSSFeedSettingsStore(database: explicitlyEnabled.database).setNotificationOverride(
      feedId: explicitlyEnabled.feedID, override: .enabled)
    try await RSSFeedSettingsStore(database: explicitlyDisabled.database).setNotificationOverride(
      feedId: explicitlyDisabled.feedID, override: .disabled)

    #expect(
      try await inherited.ledger.eligibleCandidates(
        globalEnabled: false, now: inherited.now, limit: 12
      ).isEmpty)
    #expect(
      try await explicitlyEnabled.ledger.eligibleCandidates(
        globalEnabled: false, now: explicitlyEnabled.now, limit: 12
      ).map(\.identityKey) == ["enabled"])
    #expect(
      try await explicitlyDisabled.ledger.eligibleCandidates(
        globalEnabled: true, now: explicitlyDisabled.now, limit: 12
      ).isEmpty)

    // Disabled eligibility is a durable suppression, not a transient filter. Changing the
    // preference after selection must not make that already-suppressed discovery eligible.
    try await RSSFeedSettingsStore(database: explicitlyDisabled.database).setNotificationOverride(
      feedId: explicitlyDisabled.feedID, override: .enabled)
    #expect(
      try await explicitlyDisabled.ledger.eligibleCandidates(
        globalEnabled: true, now: explicitlyDisabled.now, limit: 12
      ).isEmpty)
  }

  @Test("one episode is scheduled once and uses a stable identifier")
  func oneEpisode() async throws {
    let fixture = try await makePendingCandidate(feedName: "Show 7", key: "episode-a")
    let candidate = RSSNotificationCandidate.episode(feed: fixture.feedID, key: "episode-a")
    let scheduler = NotificationSchedulerFake(status: .allowed)
    let coordinator = RSSNotificationDeliveryCoordinator(
      ledger: fixture.ledger, intent: FakeRSSNotificationIntentReading(enabled: true),
      scheduler: scheduler)

    await coordinator.completeBackgroundRefresh(now: fixture.now)
    await coordinator.completeBackgroundRefresh(now: fixture.now.addingTimeInterval(1))

    let requests = await scheduler.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.identifier == RSSNotificationDeliveryCoordinator.request(for: [candidate]).identifier)
    #expect(request.title == "Show 7")
    #expect(request.body == "Episode episode-a")
    #expect(request.route == .episode(feedID: fixture.feedID, identityKey: "episode-a"))
  }

  @Test("episodes from different shows are announced one by one")
  func separateShows() async throws {
    let ledger = NotificationLedgerFake(candidates: [
      .episode(feed: 3, key: "b"), .episode(feed: 2, key: "a"), .episode(feed: 4, key: "c"),
    ])
    let scheduler = NotificationSchedulerFake(status: .allowed)
    await RSSNotificationDeliveryCoordinator(
      ledger: ledger, intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: scheduler
    ).completeBackgroundRefresh(now: .now)

    let requests = await scheduler.requests
    #expect(requests.map(\.title) == ["Show 2", "Show 3", "Show 4"])
    #expect(requests.map(\.body) == ["Episode a", "Episode b", "Episode c"])
    #expect(
      requests.map(\.route) == [
        .episode(feedID: 2, identityKey: "a"), .episode(feedID: 3, identityKey: "b"),
        .episode(feedID: 4, identityKey: "c"),
      ])
    #expect(Set(requests.map(\.identifier)).count == 3)
    // Each request owns exactly its own ledger row, so a later disarm cancels only that episode.
    let marked = await ledger.marked
    #expect(marked.map(\.0) == requests.map(\.identifier))
    #expect(marked.map(\.1) == [1, 1, 1])
  }

  @Test("two episodes of one show stay separate; three or more collapse into a show summary")
  func sameShowThreshold() async throws {
    let pair = NotificationSchedulerFake(status: .allowed)
    await RSSNotificationDeliveryCoordinator(
      ledger: NotificationLedgerFake(candidates: [
        .episode(feed: 2, key: "a"), .episode(feed: 2, key: "b"),
      ]),
      intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: pair
    ).completeBackgroundRefresh(now: .now)
    #expect(
      await pair.requests.map(\.route) == [
        .episode(feedID: 2, identityKey: "a"), .episode(feedID: 2, identityKey: "b"),
      ])

    let ledger = NotificationLedgerFake(candidates: [
      .episode(feed: 2, key: "a"), .episode(feed: 2, key: "b"), .episode(feed: 2, key: "c"),
      .episode(feed: 5, key: "d"),
    ])
    let mixed = NotificationSchedulerFake(status: .allowed)
    await RSSNotificationDeliveryCoordinator(
      ledger: ledger, intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: mixed
    ).completeBackgroundRefresh(now: .now)
    let requests = await mixed.requests
    #expect(requests.map(\.route) == [.show(feedID: 2), .episode(feedID: 5, identityKey: "d")])
    #expect(requests.first?.title == "Show 2")
    #expect(requests.first?.body == "3 new episodes")
    #expect(await ledger.marked.map(\.1) == [3, 1])
  }

  @Test("the newest episode is delivered last so it tops the notification stack")
  func newestDeliveredLast() async {
    let scheduler = NotificationSchedulerFake(status: .allowed)
    await RSSNotificationDeliveryCoordinator(
      ledger: NotificationLedgerFake(candidates: [
        .episode(feed: 1, key: "newest", publishedAt: 300),
        .episode(feed: 2, key: "middle", publishedAt: 200),
        .episode(feed: 3, key: "oldest", publishedAt: 100),
      ]),
      intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: scheduler
    ).completeBackgroundRefresh(now: .now)
    #expect(
      await scheduler.requests.map(\.body) == [
        "Episode oldest", "Episode middle", "Episode newest",
      ])
  }

  @Test("only the first delivered request of a pass plays a sound")
  func oneSoundPerPass() async {
    let candidates: [RSSNotificationCandidate] = [
      .episode(feed: 1, key: "a"), .episode(feed: 2, key: "b"), .episode(feed: 3, key: "c"),
    ]
    let scheduler = NotificationSchedulerFake(status: .allowed)
    await RSSNotificationDeliveryCoordinator(
      ledger: NotificationLedgerFake(candidates: candidates),
      intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: scheduler
    ).completeBackgroundRefresh(now: .now)
    #expect(await scheduler.requests.map(\.playsSound) == [true, false, false])

    // A request the scheduler refused made no sound, so the next one still carries it, and the
    // refusal does not stop the rest of the pass.
    let flaky = NotificationSchedulerFake(status: .allowed, failuresBeforeSuccess: 1)
    let ledger = NotificationLedgerFake(candidates: candidates)
    await RSSNotificationDeliveryCoordinator(
      ledger: ledger, intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: flaky
    ).completeBackgroundRefresh(now: .now)
    #expect(await flaky.requests.map(\.title) == ["Show 2", "Show 3"])
    #expect(await flaky.requests.map(\.playsSound) == [true, false])
    #expect(await ledger.marked.count == 2)
  }

  @Test("scheduling failure leaves candidates retryable")
  func failure() async {
    let ledger = NotificationLedgerFake(candidates: [.episode(feed: 1, key: "a")])
    let scheduler = NotificationSchedulerFake(status: .allowed, shouldFail: true)
    await RSSNotificationDeliveryCoordinator(
      ledger: ledger, intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: scheduler
    ).completeBackgroundRefresh(now: .now)
    #expect(await ledger.marked.isEmpty)
  }

  @Test("a refused ledger transition cancels the request accepted by the scheduler")
  func refusedLedgerTransitionCancelsScheduledRequest() async throws {
    let ledger = NotificationLedgerFake(
      candidates: [.episode(feed: 1, key: "a")], markScheduledResult: 0)
    let scheduler = NotificationSchedulerFake(status: .allowed)
    let coordinator = RSSNotificationDeliveryCoordinator(
      ledger: ledger, intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: scheduler)

    await coordinator.completeBackgroundRefresh(now: .now)

    let requests = await scheduler.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(await scheduler.cancelledRequestIDs == [[request.identifier]])
  }

  /// The store transitions all-or-nothing, but the coordinator must not depend on that to avoid
  /// announcing a silenced feed, so a short count cancels here too.
  @Test("a partial ledger transition cancels the request accepted by the scheduler")
  func partialLedgerTransitionCancelsScheduledRequest() async throws {
    let ledger = NotificationLedgerFake(
      candidates: [
        .episode(feed: 1, key: "a"), .episode(feed: 1, key: "b"), .episode(feed: 1, key: "c"),
      ],
      markScheduledResult: 1)
    let scheduler = NotificationSchedulerFake(status: .allowed)
    let coordinator = RSSNotificationDeliveryCoordinator(
      ledger: ledger, intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: scheduler)

    await coordinator.completeBackgroundRefresh(now: .now)

    let request = try #require(await scheduler.requests.first)
    #expect(await scheduler.cancelledRequestIDs == [[request.identifier]])
  }

  @Test("a successful ledger transition does not cancel the request")
  func successfulLedgerTransitionDoesNotCancelRequest() async {
    let ledger = NotificationLedgerFake(candidates: [.episode(feed: 1, key: "a")])
    let scheduler = NotificationSchedulerFake(status: .allowed)
    let coordinator = RSSNotificationDeliveryCoordinator(
      ledger: ledger, intent: FakeRSSNotificationIntentReading(enabled: true), scheduler: scheduler)

    await coordinator.completeBackgroundRefresh(now: .now)

    #expect(await scheduler.cancelledRequestIDs.isEmpty)
  }

  @Test("feed disarm cancels a shared request and leaves its other feed schedulable")
  func feedDisarmRequeuesSharedRequestSurvivor() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let firstFeedID = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/first.xml")!, title: "First", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let secondFeedID = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/second.xml")!, title: "Second", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodeStore = RSSEpisodeStore(database: database)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let baseline = now.addingTimeInterval(-3_600)
    for (feedID, key) in [(firstFeedID, "first"), (secondFeedID, "second")] {
      _ = try await episodeStore.applyRefresh(
        feedId: feedID, episodes: [],
        notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
      _ = try await episodeStore.applyRefresh(
        feedId: feedID,
        episodes: [
          RSSEpisodeUpsert(
            identityKey: key, title: key,
            enclosureURL: URL(string: "https://example.com/\(key).mp3")!,
            enclosureType: "audio/mpeg", publishedAt: now)
        ],
        notificationContext: .background(globalEnabled: true, discoveredAt: now))
    }
    let ledger = RSSNotificationLedgerStore(database: database)
    let candidates = try await ledger.eligibleCandidates(globalEnabled: true, now: now, limit: 12)
    #expect(try await ledger.markScheduled(candidates, requestID: "shared-request") == 2)
    let scheduler = NotificationSchedulerFake(status: .allowed)

    await RSSNotificationLifecycleCoordinator(ledger: ledger, scheduler: scheduler).disarm(
      feedID: firstFeedID)

    #expect(await scheduler.cancelledRequestIDs == [["shared-request"]])
    let survivors = try await ledger.eligibleCandidates(globalEnabled: true, now: now, limit: 12)
    #expect(survivors.map(\.feedID) == [secondFeedID])
  }

  @Test("hostile notification copy is normalized before it is bounded")
  func hostileCopyIsNormalized() {
    let request = RSSNotificationDeliveryCoordinator.request(for: [
      RSSNotificationCandidate(
        feedID: 1, identityKey: "hostile", showTitle: "  Show\nName\u{0007}\u{202E}\u{00AD}  ",
        episodeTitle: "Episode\r\nTitle\u{001B}\u{2066}\u{2060}",
        publishedAt: Date(timeIntervalSince1970: 900))
    ])

    #expect(request.title == "Show Name")
    #expect(request.body == "Episode Title")
    #expect(request.title.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control })
    #expect(request.body.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control })
    #expect(request.title.contains("\u{202E}") == false)
    #expect(request.title.contains("\u{00AD}") == false)
    #expect(request.body.contains("\u{2066}") == false)
    #expect(request.body.contains("\u{2060}") == false)
    #expect(request.title.count <= "  Show\nName\u{0007}\u{202E}\u{00AD}  ".count)
    #expect(request.body.count <= "Episode\r\nTitle\u{001B}\u{2066}\u{2060}".count)
  }

  @Test("empty normalized copy uses generic fallback text")
  func emptyCopyUsesGenericFallback() {
    let whitespaceShow = RSSNotificationDeliveryCoordinator.request(for: [
      RSSNotificationCandidate(
        feedID: 2, identityKey: "whitespace", showTitle: " \n\t\u{200B} ",
        episodeTitle: "Episode whitespace", publishedAt: Date(timeIntervalSince1970: 900))
    ])
    let emptyCopy = RSSNotificationRequest(
      identifier: "empty-copy", title: "\u{200B}\u{202E} \n", body: "\u{200D}\t",  // joiners alone render as nothing
      route: .episode(feedID: 2, identityKey: "empty-copy"))

    #expect(whitespaceShow.title == "New podcast episodes")
    #expect(emptyCopy.title == "New podcast episodes")
    #expect(emptyCopy.body == "New podcast episodes")
  }

  @Test("ordinary Unicode notification copy is preserved byte-for-byte")
  func ordinaryCopyIsPreserved() {
    let cases = [
      "日本語の番組タイトル",
      "🎙️ The Show",
      "Alice's Stories: Sea & Sky – Season 2",
      String(repeating: "x", count: RSSNotificationRequest.maximumCopyLength),
      // ZWJ and ZWNJ are format characters that ordinary titles depend on: stripping the whole
      // `.format` category splits this family into four separate glyphs and breaks Persian shaping.
      "👨\u{200D}👩\u{200D}👧\u{200D}👦 Family Hour",
      "🏳️\u{200D}🌈 Pride Weekly",
      "می\u{200C}خواهم",
    ]

    for value in cases {
      let request = RSSNotificationRequest(
        identifier: "ordinary-copy", title: value, body: value, route: .show(feedID: 1))
      #expect(Array(request.title.utf8) == Array(value.utf8))
      #expect(Array(request.body.utf8) == Array(value.utf8))
    }
  }

  private struct PendingCandidateFixture {
    let database: AppDatabase
    let feedID: Int64
    let ledger: RSSNotificationLedgerStore
    let now: Date
  }

  private func makePendingCandidate(
    feedName: String, key: String
  ) async throws -> PendingCandidateFixture {
    let database = try AppDatabase.inMemory()
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(key).xml")!, title: feedName, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodeStore = RSSEpisodeStore(database: database)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let baseline = now.addingTimeInterval(-3_600)
    _ = try await episodeStore.applyRefresh(
      feedId: feedID, episodes: [],
      notificationContext: .background(globalEnabled: true, discoveredAt: baseline))
    _ = try await episodeStore.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: key, title: "Episode \(key)",
          enclosureURL: URL(string: "https://example.com/\(key).mp3")!,
          enclosureType: "audio/mpeg", publishedAt: now.addingTimeInterval(-60))
      ],
      notificationContext: .background(globalEnabled: true, discoveredAt: now))
    return PendingCandidateFixture(
      database: database, feedID: feedID, ledger: RSSNotificationLedgerStore(database: database),
      now: now)
  }
}

extension RSSNotificationCandidate {
  fileprivate static func episode(
    feed: Int64, key: String, publishedAt: TimeInterval = 900
  ) -> Self {
    Self(
      feedID: feed, identityKey: key, showTitle: "Show \(feed)",
      episodeTitle: "Episode \(key)", publishedAt: Date(timeIntervalSince1970: publishedAt))
  }
}

private actor NotificationLedgerFake: RSSNotificationLedgerAccess {
  let candidates: [RSSNotificationCandidate]
  let markScheduledResult: Int?
  var marked: [(String, Int)] = []
  var seenGlobalValues: [Bool] = []
  init(candidates: [RSSNotificationCandidate], markScheduledResult: Int? = nil) {
    self.candidates = candidates
    self.markScheduledResult = markScheduledResult
  }
  func eligibleCandidates(globalEnabled: Bool, now: Date, limit: Int) async throws
    -> [RSSNotificationCandidate]
  {
    seenGlobalValues.append(globalEnabled)
    return Array(candidates.prefix(limit))
  }
  func markScheduled(_ candidates: [RSSNotificationCandidate], requestID: String) async throws -> Int {
    marked.append((requestID, candidates.count))
    return markScheduledResult ?? candidates.count
  }
}

private actor NotificationSchedulerFake: RSSLocalNotificationScheduling {
  let status: RSSLocalNotificationAuthorizationStatus
  let shouldFail: Bool
  var failuresBeforeSuccess: Int
  var requests: [RSSNotificationRequest] = []
  var cancelledRequestIDs: [[String]] = []
  init(
    status: RSSLocalNotificationAuthorizationStatus, shouldFail: Bool = false,
    failuresBeforeSuccess: Int = 0
  ) {
    self.status = status
    self.shouldFail = shouldFail
    self.failuresBeforeSuccess = failuresBeforeSuccess
  }
  func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus { status }
  func schedule(_ request: RSSNotificationRequest) async throws {
    if shouldFail { throw NotificationTestError.failed }
    if failuresBeforeSuccess > 0 {
      failuresBeforeSuccess -= 1
      throw NotificationTestError.failed
    }
    requests.append(request)
  }
  func cancel(requestIDs: [String]) async {
    cancelledRequestIDs.append(requestIDs)
  }
}

private enum NotificationTestError: Error { case failed }
