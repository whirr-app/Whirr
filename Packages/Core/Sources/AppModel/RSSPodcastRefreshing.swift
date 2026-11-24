import Foundation
import Persistence
import PodcastFeeds
import SyncEngine

/// Durable validators for the feed transport, backed by the device-owned subscription row.
public struct RSSFeedValidatorStore: FeedValidatorStoring, Sendable {
  private let store: RSSFeedStore

  public init(store: RSSFeedStore) {
    self.store = store
  }

  public func validators(for url: URL) async -> FeedValidators? {
    guard let values = try? await store.validators(feedURL: url) else { return nil }
    return FeedValidators(etag: values.etag, lastModified: values.lastModified)
  }

  public func store(_ validators: FeedValidators?, for url: URL) async {
    // The subscription may have been removed while the bounded request was in flight.
    _ = try? await store.storeValidators(
      etag: validators?.etag, lastModified: validators?.lastModified, feedURL: url)
  }
}

public actor RSSPodcastRefreshing: PodcastRefreshing {
  private struct Waiter {
    let notificationContext: RSSNotificationDiscoveryContext?
  }

  private struct Flight {
    let task: Task<PodcastRefreshOutcome, Error>
    var waiters: [UUID: Waiter]
  }

  private let feedStore: RSSFeedStore
  private let episodeStore: RSSEpisodeStore
  private let fetchClient: FeedFetchClient
  private let recoveryReading: any NativeFeedRecoveryReading
  private let cloudRefreshObserver: (any PodcastRefreshCommitObserving)?
  private let now: @Sendable () -> Date
  private var inFlight: [Int64: Flight] = [:]
  private(set) var joinedFlightCount = 0

  /// `credentialStore` has no default: a composition root that omits it silently refreshes every
  /// private feed unauthenticated, which is how the background refresh path went credential-less
  /// unnoticed. Pass `nil` only to mean "this caller genuinely has no credential storage".
  public init(
    feedStore: RSSFeedStore,
    episodeStore: RSSEpisodeStore,
    credentialStore: (any PodcastFeedCredentialStoring)?,
    recoveryReading: any NativeFeedRecoveryReading = NoOpNativeFeedRecoveryReading(),
    cloudRefreshObserver: (any PodcastRefreshCommitObserving)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.init(
      feedStore: feedStore, episodeStore: episodeStore,
      fetchClient: FeedFetchClient(
        validatorStore: RSSFeedValidatorStore(store: feedStore),
        credentialStore: credentialStore),
      recoveryReading: recoveryReading,
      cloudRefreshObserver: cloudRefreshObserver,
      now: now)
  }

  init(
    feedStore: RSSFeedStore,
    episodeStore: RSSEpisodeStore,
    fetchClient: FeedFetchClient,
    recoveryReading: any NativeFeedRecoveryReading = NoOpNativeFeedRecoveryReading(),
    cloudRefreshObserver: (any PodcastRefreshCommitObserving)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.feedStore = feedStore
    self.episodeStore = episodeStore
    self.fetchClient = fetchClient
    self.recoveryReading = recoveryReading
    self.cloudRefreshObserver = cloudRefreshObserver
    self.now = now
  }

  public func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return .complete }
    guard try await recoveryReading.recoveryRequired(feedID: feedID) == false else {
      return .complete
    }

    let waiterID = UUID()
    let waiter = Waiter(notificationContext: RSSNotificationDiscoveryScope.context)
    let task: Task<PodcastRefreshOutcome, Error>
    if var existing = inFlight[feedID] {
      joinedFlightCount += 1
      existing.waiters[waiterID] = waiter
      inFlight[feedID] = existing
      task = existing.task
    } else {
      let started = Task { [self] in try await refreshFeed(feedID: feedID) }
      inFlight[feedID] = Flight(task: started, waiters: [waiterID: waiter])
      task = started
    }

    return try await withTaskCancellationHandler {
      do {
        let result = try await task.value
        let cancelled = Task.isCancelled
        finish(feedID: feedID, waiterID: waiterID, cancelling: cancelled)
        if cancelled { throw CancellationError() }
        return result
      } catch {
        let cancelled = Task.isCancelled || error is CancellationError
        finish(feedID: feedID, waiterID: waiterID, cancelling: cancelled)
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: {
      Task { await self.finish(feedID: feedID, waiterID: waiterID, cancelling: true) }
    }
  }

  /// A show opened again within `maximumAge` of its last completed refresh answers from the
  /// cache. Radiolab's feed is 4.9 MB and 668 items; refetching, reparsing, and rewriting every
  /// row on each visit is what made the show screen open on a loading placeholder. A feed that
  /// has never refreshed, or whose recorded time is in the future, refreshes as before.
  public func refreshIfStale(itemID: String, maximumAge: TimeInterval) async throws
    -> PodcastRefreshOutcome
  {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return .complete }
    if let lastRefreshedAt = try await feedStore.fetchFeed(feedId: feedID)?.lastRefreshedAt {
      let age = now().timeIntervalSince(lastRefreshedAt)
      if age >= 0, age < maximumAge { return .complete }
    }
    return try await refresh(itemID: itemID)
  }

  private func refreshFeed(feedID: Int64) async throws -> PodcastRefreshOutcome {
    guard let feed = try await feedStore.fetchFeed(feedId: feedID) else { return .complete }
    let credentialReference = FeedEndpoint.CredentialReference(id: String(feedID))
    guard
      let endpoint = FeedEndpoint(
        string: feed.feedURL, credentialReference: credentialReference)
    else { throw URLError(.badURL) }

    switch try await fetchClient.fetch(endpoint) {
    case .notModified:
      try await feedStore.applyChannelMetadata(
        feedId: feedID, title: feed.title, author: feed.author, synopsis: feed.synopsis,
        language: feed.language, artworkURL: feed.artworkURL.flatMap(URL.init(string:)), refreshedAt: now())
      return .complete

    case .fetched(let response):
      let parsed = try FeedParser.parse(response.body)
      await fetchClient.acceptValidators(from: response)
      let identities = EpisodeIdentityPolicy.identities(for: parsed.items)
      let episodes = parsed.items.indices.compactMap { index -> RSSEpisodeUpsert? in
        let item = parsed.items[index]
        guard let identity = identities[index], let enclosure = item.enclosure else { return nil }
        return RSSEpisodeUpsert(
          identityKey: identity.key,
          alternateIdentityKey: identity.alternateKey,
          guid: item.guid,
          title: item.title,
          // The card renders the fullest notes; the row line keeps the short `description`,
          // since `content:encoded` often opens with an image or heading.
          synopsis: item.content ?? item.synopsis,
          synopsisLine: FeedHTML.line(item.synopsis ?? item.content),
          enclosureURL: enclosure.url,
          enclosureType: enclosure.type,
          declaredBytes: enclosure.lengthBytes,
          publishedAt: item.pubDate.flatMap(FeedValueParsing.pubDate),
          durationSeconds: item.durationText.flatMap(FeedValueParsing.duration),
          seasonNumber: item.seasonNumber,
          episodeNumber: item.episodeNumber,
          artworkURL: FeedValueParsing.episodeArtworkURL(
            item.artworkURL, channel: parsed.artworkURL, feedID: feedID))
      }

      _ = try await episodeStore.applyRefresh(
        feedId: feedID, episodes: episodes,
        notificationContext: currentNotificationContext(feedID: feedID)
          ?? .foreground(discoveredAt: now()))
      _ = try await episodeStore.sweepDroppedEpisodes(feedId: feedID)
      try await feedStore.applyChannelMetadata(
        feedId: feedID, title: parsed.title, author: parsed.author, synopsis: parsed.synopsis,
        language: parsed.language, artworkURL: parsed.artworkURL, refreshedAt: now())
      // Held cloud state can only match episodes that exist, so it resolves after they commit.
      await cloudRefreshObserver?.feedRefreshCommitted(feedId: feedID)

      return episodes.count == parsed.items.count ? .complete : .partial
    }
  }

  private func finish(feedID: Int64, waiterID: UUID, cancelling: Bool) {
    guard var flight = inFlight[feedID], flight.waiters.removeValue(forKey: waiterID) != nil else {
      return
    }
    guard flight.waiters.isEmpty else {
      inFlight[feedID] = flight
      return
    }
    if cancelling { flight.task.cancel() }
    inFlight[feedID] = nil
  }

  private func currentNotificationContext(feedID: Int64) -> RSSNotificationDiscoveryContext? {
    guard let flight = inFlight[feedID] else { return nil }
    let contexts = flight.waiters.values.compactMap(\.notificationContext)
    // A real background waiter keeps the discovery eligible even when a foreground view joins the
    // same transport flight. Once that waiter cancels, `finish` removes its context before commit.
    let background = contexts.filter { $0.source == .background }
    return (background.isEmpty ? contexts : background).max {
      $0.discoveredAt < $1.discoveredAt
    }
  }
}
