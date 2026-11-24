import Persistence

/// `DownloadReading`'s fake: every `observe*` method hands the test a live continuation it can
/// push new values through, in the same shape as `FakeLibraryReading`.
public final class FakeDownloadReading: DownloadReading, @unchecked Sendable {
  public init() {}

  /// One entry per `currentItemDownloadStatus…` call: the synchronous read, and the async read at
  /// the moment it starts and again when it returns (after any hold on `asyncStatusGate`).
  public enum StatusRead: Sendable, Equatable {
    case synchronous, asyncStarted, asyncCompleted
  }
  public let statusReads = CallRecorder<StatusRead>(label: "FakeDownloadReading status reads")

  /// Hold it (`hold()`) to park the async status read until the test releases it with the status
  /// to return. Open by default, so the read returns the stubbed current status at once.
  public let asyncStatusGate = TestGate<ItemDownloadStatus>(
    label: "FakeDownloadReading.currentItemDownloadStatusAsync")

  private let currentStatusBox = Locked(ItemDownloadStatus.notDownloaded)
  /// What both `currentItemDownloadStatus…` reads return (default `.notDownloaded`).
  public func stubCurrentStatus(_ status: ItemDownloadStatus) {
    currentStatusBox.value = status
  }

  public func currentItemDownloadStatus(itemId: String) -> ItemDownloadStatus {
    statusReads.record(.synchronous)
    return currentStatusBox.value
  }

  public func currentItemDownloadStatusAsync(itemId: String) async -> ItemDownloadStatus {
    statusReads.record(.asyncStarted)
    let currentStatusBox = currentStatusBox
    let status = await asyncStatusGate.pass { currentStatusBox.value }
    statusReads.record(.asyncCompleted)
    return status
  }

  private let aggregateContinuations = Locked<[String: [AsyncStream<DownloadAggregate>.Continuation]]>([:])
  private let statusContinuations = Locked<[String: [AsyncStream<ItemDownloadStatus>.Continuation]]>([:])
  private let formatStatusContinuations =
    Locked<[String: [AsyncStream<ItemFormatDownloadStatus>.Continuation]]>([:])
  private let presenceContinuations = Locked<[AsyncStream<[String: ItemDownloadPresence]>.Continuation]>([])
  /// How many times `observeItemDownloadPresence()` has been called. A list test asserts on this
  /// ("one observation per screen, not one per row").
  private let presenceSubscriptionCountBox = Locked(0)

  public func observeItemDownloadAggregate(itemId: String) -> AsyncStream<DownloadAggregate> {
    AsyncStream { continuation in
      aggregateContinuations.withValue { $0[itemId, default: []].append(continuation) }
    }
  }

  private let statusObservationCountBox = Locked(0)
  /// How many times `observeItemDownloadStatus(itemId:)` has been called, whether or not the
  /// stream was consumed. A test of deferred construction asserts it stays 0.
  public var statusObservationCount: Int { statusObservationCountBox.value }

  public func observeItemDownloadStatus(itemId: String) -> AsyncStream<ItemDownloadStatus> {
    statusObservationCountBox.withValue { $0 += 1 }
    return AsyncStream { continuation in
      statusContinuations.withValue { $0[itemId, default: []].append(continuation) }
    }
  }

  public func currentItemFormatDownloadStatus(itemId: String) -> ItemFormatDownloadStatus {
    ItemFormatDownloadStatus()
  }

  public func currentItemFormatDownloadStatusAsync(itemId: String) async -> ItemFormatDownloadStatus {
    ItemFormatDownloadStatus()
  }

  public func observeItemFormatDownloadStatus(itemId: String)
    -> AsyncStream<ItemFormatDownloadStatus>
  {
    AsyncStream { continuation in
      formatStatusContinuations.withValue { $0[itemId, default: []].append(continuation) }
    }
  }

  /// Test-only: simulates `observeItemDownloadAggregate(itemId:)` firing again for `itemId`.
  public func pushAggregate(_ aggregate: DownloadAggregate, itemId: String) {
    for continuation in aggregateContinuations.value[itemId] ?? [] { continuation.yield(aggregate) }
  }

  /// Test-only: simulates `observeItemDownloadStatus(itemId:)` firing again for `itemId`.
  public func pushStatus(_ status: ItemDownloadStatus, itemId: String) {
    for continuation in statusContinuations.value[itemId] ?? [] { continuation.yield(status) }
  }

  /// Test-only: simulates `observeItemFormatDownloadStatus(itemId:)` firing again.
  public func pushFormatStatus(_ status: ItemFormatDownloadStatus, itemId: String) {
    for continuation in formatStatusContinuations.value[itemId] ?? [] { continuation.yield(status) }
  }

  public func observeItemDownloadPresence() -> AsyncStream<[String: ItemDownloadPresence]> {
    presenceSubscriptionCountBox.withValue { $0 += 1 }
    return AsyncStream { continuation in
      presenceContinuations.withValue { $0.append(continuation) }
    }
  }

  /// Test-only: simulates `observeItemDownloadPresence()` firing again.
  public func pushPresence(_ presence: [String: ItemDownloadPresence]) {
    for continuation in presenceContinuations.value { continuation.yield(presence) }
  }

  /// Test-only: how many `observeItemDownloadPresence()` subscriptions have been opened.
  public var presenceSubscriptionCount: Int { presenceSubscriptionCountBox.value }

  private let episodePresenceContinuations =
    Locked<[AsyncStream<[EpisodeDownloadKey: ItemDownloadPresence]>.Continuation]>([])
  private let episodePresenceSubscriptionCountBox = Locked(0)

  public func observeEpisodeDownloadPresence()
    -> AsyncStream<[EpisodeDownloadKey: ItemDownloadPresence]>
  {
    episodePresenceSubscriptionCountBox.withValue { $0 += 1 }
    return AsyncStream { continuation in
      episodePresenceContinuations.withValue { $0.append(continuation) }
    }
  }

  /// Test-only: simulates `observeEpisodeDownloadPresence()` firing again.
  public func pushEpisodePresence(_ presence: [EpisodeDownloadKey: ItemDownloadPresence]) {
    for continuation in episodePresenceContinuations.value { continuation.yield(presence) }
  }

  /// Test-only: how many `observeEpisodeDownloadPresence()` subscriptions have been opened.
  public var episodePresenceSubscriptionCount: Int { episodePresenceSubscriptionCountBox.value }
}
