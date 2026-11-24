import Foundation
import Persistence

/// `LibraryReading`'s fake: every `observe*` method hands the test a live continuation it can
/// push new values through (`pushBrowseList`/`pushSyncStatus`/`pushItemDetail`), so a model under
/// test reacts as it would to a real GRDB `ValueObservation` firing again, with no database.
/// `observeItems` resolves from a plain in-memory snapshot instead, since `SearchModel`'s tests
/// need one resolved value per query, not a live subscription.
public final class FakeLibraryReading: LibraryReading, @unchecked Sendable {
  private let count = Locked(0)
  public var itemCount: Int {
    get { count.value }
    set { count.value = newValue }
  }
  public init() {}

  private struct StreamSubscription<Value>: @unchecked Sendable {
    let id: UUID
    let continuation: AsyncStream<Value>.Continuation
  }

  private let browseContinuations = Locked<[StreamSubscription<[ItemSummary]>]>([])
  private let requestedBrowseCategories = Locked<[ItemMediaCategory?]>([])
  private let crossLibraryContinuations =
    Locked<[ItemMediaCategory?: [StreamSubscription<[ItemSummary]>]]>([:])
  private let filteredContinuations =
    Locked<[BrowseFilters: [StreamSubscription<LibraryBrowseSnapshot>]]>([:])
  private let requestedBrowseFilters = Locked<[BrowseFilters]>([])
  private let stubbedBrowseItems = Locked<[ItemSummary]?>(nil)
  private let stubbedAggregateSyncStatus = Locked<LibrarySyncStatus?>(nil)
  private let syncStatusContinuations = Locked<[StreamSubscription<LibrarySyncStatus>]>([])
  private let itemDetailContinuations = Locked<[StreamSubscription<ItemSummary?>]>([])
  private let itemsByServerId = Locked<[String: ItemSummary]>([:])
  private let currentItemDetailReadCountBox = Locked(0)
  private let itemPlaybackStatusContinuations =
    Locked<[AsyncStream<[String: ItemPlaybackStatus]>.Continuation]>([])
  private let episodePlaybackStatusContinuations =
    Locked<[AsyncStream<[ListeningIdentity: ItemPlaybackStatus]>.Continuation]>([])
  private let continueListeningHiddenContinuations =
    Locked<[AsyncStream<Set<ListeningIdentity>>.Continuation]>([])
  private struct ItemPlaybackProgressSubscription: @unchecked Sendable {
    let itemIDs: Set<String>
    let continuation: AsyncStream<[String: ItemPlaybackProgress]>.Continuation
  }
  private let itemPlaybackProgressSubscriptions =
    Locked<[ItemPlaybackProgressSubscription]>([])

  public func observeBrowseList(libraryId: String) -> AsyncStream<[ItemSummary]> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      browseContinuations.withValue {
        $0.append(StreamSubscription(id: id, continuation: continuation))
      }
      continuation.onTermination = { [weak self] _ in
        self?.removeBrowseSubscriber(id)
      }
    }
  }

  /// The cross-library overload keeps its continuations keyed by the category they subscribed
  /// under, so a test can push to one filter's stream alone. That is what makes a superseded
  /// filter's late emission expressible.
  public func observeBrowseList(category: ItemMediaCategory?) -> AsyncStream<[ItemSummary]> {
    requestedBrowseCategories.withValue { $0.append(category) }
    let initial = stubbedBrowseItems.value
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      crossLibraryContinuations.withValue {
        $0[category, default: []].append(StreamSubscription(id: id, continuation: continuation))
      }
      continuation.onTermination = { [weak self] _ in
        self?.removeCrossLibrarySubscriber(id, category: category)
      }
      if let initial { continuation.yield(initial) }
    }
  }

  /// Keyed by the whole `BrowseFilters`, so a test can push to one filter generation alone and
  /// express a superseded generation's late emission.
  public func observeBrowseList(filters: BrowseFilters) -> AsyncStream<LibraryBrowseSnapshot> {
    requestedBrowseFilters.withValue { $0.append(filters) }
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      filteredContinuations.withValue {
        $0[filters, default: []].append(StreamSubscription(id: id, continuation: continuation))
      }
      continuation.onTermination = { [weak self] _ in
        self?.removeFilteredSubscriber(id, filters: filters)
      }
    }
  }

  public func observeSyncStatus(libraryId: String) -> AsyncStream<LibrarySyncStatus> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      syncStatusContinuations.withValue {
        $0.append(StreamSubscription(id: id, continuation: continuation))
      }
      continuation.onTermination = { [weak self] _ in
        self?.removeSyncStatusSubscriber(id)
      }
    }
  }

  /// Shares `pushSyncStatus`'s continuations. A model uses either the library-scoped stream or
  /// this one, never both, so one push channel covers each.
  public func observeAggregateSyncStatus() -> AsyncStream<LibrarySyncStatus> {
    let initial = stubbedAggregateSyncStatus.value
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      syncStatusContinuations.withValue {
        $0.append(StreamSubscription(id: id, continuation: continuation))
      }
      continuation.onTermination = { [weak self] _ in
        self?.removeSyncStatusSubscriber(id)
      }
      if let initial { continuation.yield(initial) }
    }
  }

  public func observeItemDetail(itemId: String) -> AsyncStream<ItemSummary?> {
    itemDetailObservationCountBox.withValue { $0 += 1 }
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      itemDetailContinuations.withValue {
        $0.append(StreamSubscription(id: id, continuation: continuation))
      }
      continuation.onTermination = { [weak self] _ in
        self?.removeItemDetailSubscriber(id)
      }
    }
  }

  public func currentItemDetail(itemId: String) -> ItemSummary? {
    currentItemDetailReadCountBox.withValue { $0 += 1 }
    return itemsByServerId.value[itemId]
  }

  /// Test-only: counts callers of the retained synchronous detail API. Presentation models should
  /// use their display seed and observation stream instead.
  public var currentItemDetailReadCount: Int {
    currentItemDetailReadCountBox.value
  }

  /// Test-only live subscriber counts. A stream's `onTermination` removes its UUID, so these
  /// probes let teardown assert that cancelled observation tasks really released their fakes.
  public var browseSubscriberCount: Int { browseContinuations.value.count }
  public var crossLibrarySubscriberCount: Int {
    crossLibraryContinuations.value.values.reduce(0) { $0 + $1.count }
  }
  public var filteredSubscriberCount: Int {
    filteredContinuations.value.values.reduce(0) { $0 + $1.count }
  }
  public var syncStatusSubscriberCount: Int { syncStatusContinuations.value.count }
  public var itemDetailSubscriberCount: Int { itemDetailContinuations.value.count }

  private let itemDetailObservationCountBox = Locked(0)
  /// Every `observeItemDetail(itemId:)` call, consumed or not. Unlike `itemDetailSubscriberCount`
  /// it never drops back, so a test of deferred construction can assert it stays 0.
  public var itemDetailObservationCount: Int { itemDetailObservationCountBox.value }

  public func observeItems(ids: [String]) -> AsyncStream<[ItemSummary]> {
    let resolved = itemsByServerId.withValue { map in ids.compactMap { map[$0] } }
    return AsyncStream { continuation in
      continuation.yield(resolved)
    }
  }

  public func observeItemPlaybackStatuses() -> AsyncStream<[String: ItemPlaybackStatus]> {
    AsyncStream { continuation in
      itemPlaybackStatusContinuations.withValue { $0.append(continuation) }
    }
  }

  public func observeEpisodePlaybackStatuses() -> AsyncStream<[ListeningIdentity: ItemPlaybackStatus]> {
    AsyncStream { continuation in
      episodePlaybackStatusContinuations.withValue { $0.append(continuation) }
    }
  }

  /// Test-only: how many episode playback-status subscriptions have been opened.
  public var episodePlaybackStatusSubscriptionCount: Int {
    episodePlaybackStatusContinuations.value.count
  }

  public func observeContinueListeningHidden() -> AsyncStream<Set<ListeningIdentity>> {
    AsyncStream { continuation in
      continueListeningHiddenContinuations.withValue { $0.append(continuation) }
    }
  }

  /// Test-only: how many Continue Listening visibility subscriptions have been opened.
  public var continueListeningHiddenSubscriptionCount: Int {
    continueListeningHiddenContinuations.value.count
  }

  public func observeItemPlaybackProgress(itemIDs: Set<String>)
    -> AsyncStream<[String: ItemPlaybackProgress]>
  {
    AsyncStream { continuation in
      itemPlaybackProgressSubscriptions.withValue {
        $0.append(ItemPlaybackProgressSubscription(itemIDs: itemIDs, continuation: continuation))
      }
    }
  }

  /// Test-only: how many playback-status subscriptions have been opened. Backs the assertion
  /// "one per screen, never one per row".
  public var itemPlaybackStatusSubscriptionCount: Int {
    itemPlaybackStatusContinuations.value.count
  }

  public var observedItemPlaybackProgressIDs: [Set<String>] {
    itemPlaybackProgressSubscriptions.value.map(\.itemIDs)
  }

  /// Test-only: simulates the browse-list observation firing again (as a real insert/update/
  /// soft-delete would).
  /// Reaches every browse subscription, library-scoped and cross-library alike, so a test that
  /// does not care about filtering keeps working unchanged.
  public func pushBrowseList(_ items: [ItemSummary]) {
    for subscription in browseContinuations.value { subscription.continuation.yield(items) }
    for subscription in crossLibraryContinuations.value.values.flatMap({ $0 }) {
      subscription.continuation.yield(items)
    }
    // Filtered subscribers get a bare item push as these rows and nothing else in the library.
    // A test that needs rows hidden behind a filter (the point of `unfilteredItemCount`) pushes
    // a snapshot explicitly instead.
    pushBrowseSnapshot(LibraryBrowseSnapshot(items: items, unfilteredItemCount: items.count))
  }

  /// Test-only: pushes one snapshot to every filtered subscription, whatever it subscribed under.
  public func pushBrowseSnapshot(_ snapshot: LibraryBrowseSnapshot) {
    for subscription in filteredContinuations.value.values.flatMap({ $0 }) {
      subscription.continuation.yield(snapshot)
    }
  }

  /// Test-only: pushes to the filtered subscriptions made under `filters` alone, to emit from a
  /// filter generation the model has already moved off.
  public func pushBrowseSnapshot(filters: BrowseFilters, _ snapshot: LibraryBrowseSnapshot) {
    for subscription in filteredContinuations.value[filters] ?? [] {
      subscription.continuation.yield(snapshot)
    }
  }

  /// Test-only: every filter the browse list has been subscribed under, oldest first. One entry
  /// per subscribe, so a filter change appends rather than replaces.
  public var observedBrowseFilters: [BrowseFilters] { requestedBrowseFilters.value }

  /// Test-only: pushes to the cross-library subscriptions made under `category` alone, to emit
  /// from a filter the model has already moved off.
  public func pushBrowseList(category: ItemMediaCategory?, _ items: [ItemSummary]) {
    for subscription in crossLibraryContinuations.value[category] ?? [] {
      subscription.continuation.yield(items)
    }
  }

  /// Test-only: every category the cross-library browse list has been subscribed under, oldest
  /// first. One entry per subscribe, so a filter change appends rather than replaces.
  public var observedBrowseCategories: [ItemMediaCategory?] { requestedBrowseCategories.value }

  /// Test-only: simulates the sync-status observation firing again.
  public func pushSyncStatus(_ status: LibrarySyncStatus) {
    for subscription in syncStatusContinuations.value { subscription.continuation.yield(status) }
  }

  /// Test-only: simulates the item-detail observation firing again.
  public func pushItemDetail(_ summary: ItemSummary?) {
    for subscription in itemDetailContinuations.value { subscription.continuation.yield(summary) }
  }

  /// Test-only: simulates the item-playback-status observation firing again.
  public func pushItemPlaybackStatuses(_ statuses: [String: ItemPlaybackStatus]) {
    for continuation in itemPlaybackStatusContinuations.value { continuation.yield(statuses) }
  }

  /// Test-only: simulates the episode-playback-status observation firing again.
  public func pushEpisodePlaybackStatuses(_ statuses: [ListeningIdentity: ItemPlaybackStatus]) {
    for continuation in episodePlaybackStatusContinuations.value { continuation.yield(statuses) }
  }

  /// Test-only: simulates the Continue Listening visibility observation firing again.
  public func pushContinueListeningHidden(_ identities: Set<ListeningIdentity>) {
    for continuation in continueListeningHiddenContinuations.value { continuation.yield(identities) }
  }

  public func pushItemPlaybackProgress(_ progress: [String: ItemPlaybackProgress]) {
    for subscription in itemPlaybackProgressSubscriptions.value {
      subscription.continuation.yield(
        progress.filter { subscription.itemIDs.contains($0.key) })
    }
  }

  /// Test-only: the items every cross-library browse subscription (`observeBrowseList(category:)`)
  /// starts with, as a database observation yields its current value on subscribe. Without it a
  /// subscription is silent until a test pushes. Later pushes still reach it; the stream never
  /// finishes.
  public func stubBrowseList(_ items: [ItemSummary]) {
    stubbedBrowseItems.value = items
  }

  /// Test-only: the status every `observeAggregateSyncStatus()` subscription starts with. Without
  /// it a subscription is silent until `pushSyncStatus`.
  public func stubAggregateSyncStatus(_ status: LibrarySyncStatus) {
    stubbedAggregateSyncStatus.value = status
  }

  /// Test-only: seeds the snapshot `observeItems` resolves against.
  public func setKnownItems(_ items: [ItemSummary]) {
    itemsByServerId.value = Dictionary(uniqueKeysWithValues: items.map { ($0.serverItemId, $0) })
  }

  private func removeBrowseSubscriber(_ id: UUID) {
    browseContinuations.withValue { subscriptions in
      subscriptions.removeAll { $0.id == id }
    }
  }

  private func removeCrossLibrarySubscriber(_ id: UUID, category: ItemMediaCategory?) {
    crossLibraryContinuations.withValue { subscriptions in
      guard var categorySubscriptions = subscriptions[category] else { return }
      categorySubscriptions.removeAll { $0.id == id }
      subscriptions[category] = categorySubscriptions.isEmpty ? nil : categorySubscriptions
    }
  }

  private func removeFilteredSubscriber(_ id: UUID, filters: BrowseFilters) {
    filteredContinuations.withValue { subscriptions in
      guard var filterSubscriptions = subscriptions[filters] else { return }
      filterSubscriptions.removeAll { $0.id == id }
      subscriptions[filters] = filterSubscriptions.isEmpty ? nil : filterSubscriptions
    }
  }

  private func removeSyncStatusSubscriber(_ id: UUID) {
    syncStatusContinuations.withValue { subscriptions in
      subscriptions.removeAll { $0.id == id }
    }
  }

  private func removeItemDetailSubscriber(_ id: UUID) {
    itemDetailContinuations.withValue { subscriptions in
      subscriptions.removeAll { $0.id == id }
    }
  }
}
