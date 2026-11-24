import ABSApi
import AppModel
import Foundation
import Observation
import Persistence

/// One episode in the phone's desired Watch set, with the titles the On Apple Watch screen draws
/// and what the Watch's latest inventory said about its download. Titles and the download status
/// are resolved by the model, never by a view body.
struct WatchEpisodeCopyRow: Identifiable, Equatable, Sendable {
  let episodeId: Int64
  let feedId: Int64
  let identityKey: String
  let title: String
  let showTitle: String
  /// The episode's own image under the show's identity, else the show's cover. Resolved once with
  /// the row's titles, so the view never reaches into artwork identities.
  let artworkSource: ArtworkSource?
  /// The show's cover, drawn when an episode's own image cannot be had. Nil when the feed declares
  /// no artwork.
  let artworkFallbackSource: ArtworkSource?
  let state: RSSWatchCopyState
  let removedBy: RSSWatchCopyRemovalInitiator?
  let declineReason: RSSWatchDeclineReason?
  /// From the latest inventory, when it reported on this row's current revision. Held in memory and
  /// restored from `WatchDownloadStatusRecord` at launch.
  let downloadStatus: WatchEpisodeDownloadStatus?
  let requestedAt: Date

  var id: Int64 { episodeId }
}

/// The App's read of the phone's desired Watch set: the rows `rssWatchCopy` holds, the Watch's
/// reported budget, and whether the Watch app is installed at all.
///
/// Process-lifetime and device-owned, like `WatchEpisodeSendPublisher`: it observes through
/// `RSSWatchCopyStore.observe()` rather than the account graph, so it survives a logout the way the
/// copies do. Every write goes back through the store and then asks the sender to plan, so the offer
/// never waits for an unrelated trigger.
///
/// `WatchCompanionRuntime` owns one and connects the Watch transport through `Host`, so the model
/// itself names no runtime.
@MainActor
@Observable
final class WatchEpisodeCopiesModel {
  /// Newest request first, the offer's order.
  private(set) var rows: [WatchEpisodeCopyRow] = []
  private(set) var setState = RSSWatchCopySetState()
  /// From the connected host (`WatchCompanionRuntime`, which owns the one `WCSession`). Refreshed
  /// when the store emits and whenever a screen that offers a Watch action appears.
  private(set) var isWatchAppInstalled = false
  /// What the Watch app's last status report said it can do. `.unknown` until one arrives; the
  /// On Apple Watch screen reads it for the statuses a copy earns before the Watch acknowledges it.
  private(set) var watchAppReadiness: WatchAppReadiness = .unknown
  /// The feeds with a device-held credential. ADR 0006's save-path rule says such a feed is
  /// private, and ADR 0020 Decision 2 never offers one to the Watch, so both Watch actions hide.
  private var privateFeedIDs: Set<Int64> = []
  /// The Watch's own download state and progress from its latest inventory, keyed by episode id.
  /// The runtime restores it at launch from `WatchDownloadStatusRecord`; the persisted row is the
  /// durable state.
  private var downloadStatuses: [Int64: WatchEpisodeDownloadStatus] = [:]

  @ObservationIgnored private var database: AppDatabase?
  @ObservationIgnored private var store: RSSWatchCopyStore?
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var feedObservationTask: Task<Void, Never>?
  @ObservationIgnored private var availabilityTask: Task<Void, Never>?
  @ObservationIgnored private var credentialStore: (any FeedCredentialStoring)?
  @ObservationIgnored private var host: Host?
  /// Titles are stable enough to keep between emissions: only a new row needs a read.
  @ObservationIgnored private var factsByEpisodeID: [Int64: Fact] = [:]

  /// The runtime's own work this model asks for. Holding closures rather than the runtime keeps the
  /// model free of one, and a model built without a host reads the Watch as absent and asks nothing.
  struct Host {
    let isWatchAppInstalled: @MainActor () -> Bool
    let refreshAvailability: @MainActor () -> Void
    let refreshSend: @MainActor () -> Void
  }

  private struct Fact: Sendable {
    let feedId: Int64
    let identityKey: String
    let title: String
    let showTitle: String
    let artworkSource: ArtworkSource?
    let artworkFallbackSource: ArtworkSource?
  }

  init() {
    // The store's initialiser only records its Keychain namespace; no read happens here.
    credentialStore = try? KeychainFeedCredentialStore()
  }

  /// Called by the owning runtime once, from its initialiser, with closures that hold it weakly.
  func connect(_ host: Host) {
    self.host = host
  }

  /// Idempotent: the first caller composes the observation, later ones do nothing. A store that
  /// cannot open yet (before first unlock) leaves `database` nil so a later call retries.
  func start() {
    guard observationTask == nil, let database = DatabaseHardware.sharedIfAvailable() else {
      return
    }
    let store = RSSWatchCopyStore(database: database)
    self.database = database
    self.store = store
    refreshWatchAvailability()
    startAvailabilityWatch()
    startFeedCredentialWatch(database: database)
    observationTask = Task { @MainActor [weak self] in
      for await observation in store.observe() {
        guard !Task.isCancelled, let self else { return }
        await self.apply(observation)
      }
    }
  }

  /// `WCSession.activate()` finishes after launch, so the first install-state read is usually
  /// `.unknown`. A bounded poll covers the launch window; after it, a screen that offers a Watch
  /// action refreshes on appear rather than leaving a process-lifetime timer running.
  private func startAvailabilityWatch() {
    guard availabilityTask == nil else { return }
    availabilityTask = Task { @MainActor [weak self] in
      for _ in 0..<30 {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        self.refreshWatchAvailability()
        if self.isWatchAppInstalled { return }
      }
    }
  }

  /// Re-reads the bridge's install state. The session activates on its own schedule, so a screen
  /// that raises the menu asks again as it appears rather than assuming the launch answer.
  func refreshWatchAvailability() {
    let installed = host?.isWatchAppInstalled() ?? false
    if installed != isWatchAppInstalled { isWatchAppInstalled = installed }
    host?.refreshAvailability()
  }

  /// Replaces the capability state read from the Watch's last status report. The runtime calls
  /// this when a report is accepted and when the bound account changes.
  func applyReadiness(_ readiness: WatchAppReadiness) {
    if readiness != watchAppReadiness { watchAppReadiness = readiness }
  }

  // MARK: - Menu projection

  /// The canonical menu's answer for one native-RSS episode. `nil` hides both Watch entries: there
  /// is no Watch app, the identity cannot cross the wire, the feed is private, or the episode is
  /// not a native-RSS row.
  ///
  /// A copy that is offered, downloading or delivered reads as on the Watch, so the menu offers
  /// Remove. A copy the Watch removed, declined or failed reads as not on the Watch, so Send is
  /// offered again and retries it (a request bumps the revision).
  func watchCopy(
    episodeId: Int64? = nil, feedId: Int64, identityKey: String
  ) -> PodcastEpisodeWatchCopy? {
    guard
      isWatchAppInstalled,
      WatchEpisodeSendEligibility.selection(feedId: feedId, identityKey: identityKey) != nil,
      privateFeedIDs.contains(feedId) == false
    else { return nil }
    guard let row = copy(episodeId: episodeId, feedId: feedId, identityKey: identityKey) else {
      return .notOnWatch
    }
    switch row.state {
    case .wanted, .waitingForWatch, .sending, .delivered:
      return .onWatch
    case .removed, .declined, .failed:
      return .notOnWatch
    }
  }

  /// The same projection for a row that names its source the way every episode surface does.
  func watchCopy(itemID: String, episodeID: String) -> PodcastEpisodeWatchCopy? {
    guard let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return nil }
    return watchCopy(feedId: feedId, identityKey: episodeID)
  }

  /// The row mark's finer answer: the copy's raw state, so the row can draw pending and delivered
  /// differently even though the menu's two-state projection treats both as on the Watch.
  func watchCopyState(itemID: String, episodeID: String) -> WatchCopyState? {
    guard
      isWatchAppInstalled,
      let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId,
      WatchEpisodeSendEligibility.selection(feedId: feedId, identityKey: episodeID) != nil,
      privateFeedIDs.contains(feedId) == false,
      let row = copy(episodeId: nil, feedId: feedId, identityKey: episodeID)
    else { return nil }
    return WatchCopyState(state: row.state, removedBy: row.removedBy, declineReason: row.declineReason)
  }

  // MARK: - Actions

  /// Sends one episode: the store records the request, then the sender plans the offer. A private
  /// feed is refused here as well as hidden from the menu, because the menu's answer can predate a
  /// password the listener has just added (ADR 0020 Decision 2).
  func send(episodeId: Int64) async {
    guard let store, let database,
      let episode = try? await RSSEpisodeStore(database: database).fetchEpisode(episodeId: episodeId),
      WatchEpisodeSendEligibility.isPrivateFeed(
        feedId: episode.feedId, credentialStore: credentialStore) == false
    else { return }
    _ = try? await store.request(episodeId: episodeId, now: Date())
    host?.refreshSend()
  }

  /// Sends an episode named by its source identity, resolving the row id the store keys on.
  func send(itemID: String, episodeID: String) async {
    guard let episodeId = await resolveEpisodeID(itemID: itemID, episodeID: episodeID) else {
      return
    }
    await send(episodeId: episodeId)
  }

  /// Removes one episode from the Watch. A row the Watch already removed is a no-op.
  func remove(episodeId: Int64) async {
    guard let store else { return }
    _ = try? await store.removeFromWatch(episodeId: episodeId, now: Date())
    host?.refreshSend()
  }

  func remove(itemID: String, episodeID: String) async {
    guard let episodeId = await resolveEpisodeID(itemID: itemID, episodeID: episodeID) else {
      return
    }
    await remove(episodeId: episodeId)
  }

  // MARK: - Watch download status

  /// Replaces the download projection with the Watch's latest inventory, or with the projection the
  /// runtime restored at launch. The On Apple Watch screen reads it through the rows; only a record
  /// saved for the copy set's current Watch install is restored, and the persisted row remains the
  /// durable state.
  func applyDownloadStatuses(_ statuses: [Int64: WatchEpisodeDownloadStatus]) {
    guard statuses != downloadStatuses else { return }
    downloadStatuses = statuses
    rows = rows.map { row in
      row.withDownloadStatus(statuses[row.episodeId])
    }
  }

  // MARK: - Observation

  private func apply(_ observation: RSSWatchCopyObservation) async {
    var loaded = rows
    var facts = factsByEpisodeID
    for copy in observation.copies {
      let fact: Fact?
      if let cached = facts[copy.episodeId] {
        fact = cached
      } else {
        fact = await loadFact(episodeId: copy.episodeId)
        if let fact { facts[copy.episodeId] = fact }
      }
      guard let fact else { continue }
      let row = WatchEpisodeCopyRow(
        episodeId: copy.episodeId,
        feedId: fact.feedId,
        identityKey: fact.identityKey,
        title: fact.title,
        showTitle: fact.showTitle,
        artworkSource: fact.artworkSource,
        artworkFallbackSource: fact.artworkFallbackSource,
        state: copy.state,
        removedBy: copy.removedBy,
        declineReason: copy.declineReason,
        downloadStatus: downloadStatuses[copy.episodeId].flatMap {
          $0.revision == copy.revision ? $0 : nil
        },
        requestedAt: copy.requestedAt)
      if let index = loaded.firstIndex(where: { $0.episodeId == copy.episodeId }) {
        loaded[index] = row
      } else {
        loaded.append(row)
      }
    }
    // Drop rows the store no longer has (a deleted episode, or a new Watch install replacing the
    // set), keeping the store's newest-request-first order.
    let present = Set(observation.copies.map(\.episodeId))
    loaded = loaded.filter { present.contains($0.episodeId) }
    loaded.sort {
      if $0.requestedAt != $1.requestedAt { return $0.requestedAt > $1.requestedAt }
      return $0.episodeId > $1.episodeId
    }
    if downloadStatuses.keys.contains(where: { present.contains($0) == false }) {
      downloadStatuses = downloadStatuses.filter { present.contains($0.key) }
    }

    factsByEpisodeID = facts
    rows = loaded
    if setState != observation.set { setState = observation.set }
    refreshWatchAvailability()
  }

  private func copy(
    episodeId: Int64?, feedId: Int64, identityKey: String
  ) -> WatchEpisodeCopyRow? {
    if let episodeId, let row = rows.first(where: { $0.episodeId == episodeId }) {
      return row
    }
    return rows.first { $0.feedId == feedId && $0.identityKey == identityKey }
  }

  private func loadFact(episodeId: Int64) async -> Fact? {
    guard let database else { return nil }
    let episodes = RSSEpisodeStore(database: database)
    let feeds = RSSFeedStore(database: database)
    guard let episode = try? await episodes.fetchEpisode(episodeId: episodeId) else { return nil }
    let feed = try? await feeds.fetchFeed(feedId: episode.feedId)
    let episodeTitle = (episode.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let feedTitle = (feed?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let artwork = Self.artwork(
      feedId: episode.feedId, episodeArtworkURL: episode.artworkURL, feed: feed)
    return Fact(
      feedId: episode.feedId,
      identityKey: episode.identityKey,
      title: episodeTitle.isEmpty ? "Episode" : episodeTitle,
      showTitle: feedTitle.isEmpty ? (episodeTitle.isEmpty ? "Podcast" : episodeTitle) : feedTitle,
      artworkSource: artwork.episode,
      artworkFallbackSource: artwork.show)
  }

  /// The same pair the native episode rows draw: the episode's own cover under the show's RSS
  /// identity, falling back to the show's. Nil where the feed declares no artwork, so the shared
  /// loader draws its placeholder.
  private static func artwork(
    feedId: Int64, episodeArtworkURL: String?, feed: RSSFeedRecord?
  ) -> (episode: ArtworkSource?, show: ArtworkSource?) {
    guard let itemID = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else {
      return (nil, nil)
    }
    let feedURL = feed.flatMap { URL(string: $0.feedURL) }
    let showSource = makeProviderArtworkSource(
      itemID: itemID, artworkURL: feed.flatMap { $0.artworkURL.flatMap(URL.init(string:)) },
      artworkFeedURL: feedURL)
    let episodeSource = makeEpisodeArtworkSource(
      itemID: itemID, episodeArtworkURL: episodeArtworkURL.flatMap(URL.init(string:)),
      artworkFeedURL: feedURL)
    return (episodeSource ?? showSource, showSource)
  }

  /// ADR 0006's private-feed rule, read once per feed on each feed-table change. `observeFeeds`
  /// covers a feed being added, removed or refreshed, which is what follows a password being set in
  /// a show's settings, so the cached answer cannot outlive the credential it describes.
  private func startFeedCredentialWatch(database: AppDatabase) {
    guard feedObservationTask == nil else { return }
    feedObservationTask = Task { @MainActor [weak self] in
      for await feeds in RSSFeedStore(database: database).observeFeeds() {
        guard !Task.isCancelled, let self else { return }
        await self.applyPrivateFeeds(feeds)
      }
    }
  }

  /// The Keychain reads happen off the main actor: a background refresh write can emit a feed table
  /// of any size, and none of these reads may stall a frame.
  private func applyPrivateFeeds(_ feeds: [RSSFeedRecord]) async {
    let feedIDs = feeds.compactMap(\.id)
    guard feedIDs.isEmpty == false else {
      if privateFeedIDs.isEmpty == false { privateFeedIDs = [] }
      return
    }
    let credentialStore = credentialStore
    let privateIDs = await Task.detached(priority: .utility) {
      var privateIDs: Set<Int64> = []
      for feedId in feedIDs
      where WatchEpisodeSendEligibility.isPrivateFeed(
        feedId: feedId, credentialStore: credentialStore)
      {
        privateIDs.insert(feedId)
      }
      return privateIDs
    }.value
    if privateIDs != privateFeedIDs { privateFeedIDs = privateIDs }
  }

  private func resolveEpisodeID(itemID: String, episodeID: String) async -> Int64? {
    guard let database,
      let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId
    else { return nil }
    guard
      let ids = try? await RSSEpisodeStore(database: database).fetchEpisodeIDs(
        feedId: feedId, identityKeys: [episodeID])
    else { return nil }
    return ids[episodeID]
  }
}

extension WatchEpisodeCopyRow {
  fileprivate func withDownloadStatus(
    _ status: WatchEpisodeDownloadStatus?
  ) -> WatchEpisodeCopyRow {
    WatchEpisodeCopyRow(
      episodeId: episodeId, feedId: feedId, identityKey: identityKey, title: title,
      showTitle: showTitle, artworkSource: artworkSource,
      artworkFallbackSource: artworkFallbackSource, state: state, removedBy: removedBy,
      declineReason: declineReason, downloadStatus: status, requestedAt: requestedAt)
  }
}
