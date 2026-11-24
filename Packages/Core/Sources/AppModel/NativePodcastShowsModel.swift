import Observation
import Persistence

public enum NativePodcastShowsCopy {
  public static let sortFailed = "Couldn't change how your shows are sorted. Try again."
  public static let reorderFailed = ShowOrderingPolicy.reorderFailed
  public static let resetFailed = ShowOrderingPolicy.resetFailed
}

@MainActor
@Observable
public final class NativePodcastShowsModel {
  public enum State: Sendable, Equatable {
    case loading
    case empty
    case loaded(NativePodcastShowsSnapshot)
  }

  public private(set) var state: State = .loading
  public private(set) var actionErrorMessage: String?
  public private(set) var unfollowingItemID: String?
  public var isUnfollowing: Bool { unfollowingItemID != nil }
  public var shows: [ItemSummary] {
    if case .loaded(let snapshot) = state { return snapshot.shows }
    return []
  }
  public var sortMode: NativePodcastShowSortMode {
    if case .loaded(let snapshot) = state { return snapshot.mode }
    return .alphabetical
  }
  public func needsAttention(itemID: String) -> Bool {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return false }
    return recoveryFeedIDs.contains(feedID)
  }

  private let reading: any NativePodcastShowsReading
  private let ordering: any NativePodcastShowOrdering
  private let subscriptions: any NativePodcastSubscriptionsReading
  private let recoveryReading: any NativeFeedRecoveryReading
  private let unfollowing: any NativePodcastUnfollowing
  private var latestSnapshot: NativePodcastShowsSnapshot?
  private var latestEnabled: Bool?
  private var recoveryFeedIDs: Set<Int64> = []
  @ObservationIgnored private var observations = FilterObservationCoordinator()

  public init(
    reading: any NativePodcastShowsReading,
    ordering: any NativePodcastShowOrdering = NoOpNativePodcastShowOrdering(),
    subscriptions: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    recoveryReading: any NativeFeedRecoveryReading = NoOpNativeFeedRecoveryReading(),
    unfollowing: any NativePodcastUnfollowing = NoOpNativePodcastUnfollowing()
  ) {
    self.reading = reading
    self.ordering = ordering
    self.subscriptions = subscriptions
    self.recoveryReading = recoveryReading
    self.unfollowing = unfollowing
    subscribe()
  }

  public func preview(limit: Int) -> [ItemSummary] {
    ShowOrderingPolicy.preview(shows, limit: limit)
  }

  public func setSortMode(_ mode: NativePodcastShowSortMode) async {
    do {
      try await ordering.setSortMode(mode)
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = NativePodcastShowsCopy.sortFailed
    }
  }

  public func move(showID: String, to destination: Int) async {
    await apply(
      order: ShowOrderingPolicy.reorder(shows.map(\.serverItemId), moving: showID, to: destination))
  }

  public func apply(order showIDs: [String]) async {
    guard isUnfollowing == false, showIDs != shows.map(\.serverItemId) else { return }
    do {
      try await ordering.replaceCustomOrder(showIDs: showIDs)
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = NativePodcastShowsCopy.reorderFailed
    }
  }

  public func resetToAlphabetical() async {
    do {
      try await ordering.resetToAlphabetical()
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = NativePodcastShowsCopy.resetFailed
    }
  }

  /// Single-flight because a feed deletion also compacts the native custom order. A second
  /// simultaneous removal or reorder must not race that compaction with a stale visible sequence.
  @discardableResult
  public func unfollow(itemID: String) async -> Bool {
    guard unfollowingItemID == nil,
      shows.contains(where: { $0.serverItemId == itemID })
    else { return false }

    actionErrorMessage = nil
    unfollowingItemID = itemID
    defer { unfollowingItemID = nil }

    do {
      try await unfollowing.unfollow(itemID: itemID)
      return true
    } catch is CancellationError {
      return false
    } catch NativePodcastUnfollowError.playbackStopFailed {
      actionErrorMessage = PodcastCopy.unsubscribePlaybackStopFailed
      return false
    } catch {
      actionErrorMessage = PodcastCopy.unsubscribeFailed
      return false
    }
  }

  public func dismissActionError() {
    actionErrorMessage = nil
  }

  /// Shows and the preference form one readiness barrier so a disabled launch cannot briefly
  /// render retained device-owned rows.
  func subscribe() {
    let generation = observations.begin(sourceCount: 3)
    let stream = reading.observeShows()
    let enabledStream = subscriptions.observeEnabled()
    let recoveryStream = recoveryReading.observeRecoveryFeedIDs()
    observations.observe(stream, sourceID: 0, in: generation) { [weak self] snapshot, ready in
      guard let self else { return }
      self.latestSnapshot = snapshot
      if ready { self.recomputeState() }
    }
    observations.observe(enabledStream, sourceID: 1, in: generation) { [weak self] enabled, ready in
      guard let self else { return }
      self.latestEnabled = enabled
      if ready { self.recomputeState() }
    }
    observations.observe(recoveryStream, sourceID: 2, in: generation) { [weak self] feedIDs, ready in
      guard let self else { return }
      self.recoveryFeedIDs = feedIDs
      if ready { self.recomputeState() }
    }
  }

  private func recomputeState() {
    guard let snapshot = latestSnapshot, let enabled = latestEnabled else { return }
    guard enabled else {
      if state != .empty { state = .empty }
      return
    }

    let next: State = snapshot.shows.isEmpty ? .empty : .loaded(snapshot)
    if next != state { state = next }
  }
}
