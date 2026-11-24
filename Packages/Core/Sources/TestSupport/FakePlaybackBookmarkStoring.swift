import Persistence

/// `PlaybackBookmarkStoring`'s fake: `observeBookmark()` is push-driven, like `FakeHomeReading`'s
/// streams. `setBookmark` re-derives no projection, matching the real store
/// (`DefaultPlaybackBookmarkStoring` joins position/finished from `mediaProgress` at read time);
/// a test wanting `displayedItem` to reflect a write pushes the projection. The one-shot read is
/// independently stubbable so cold-entry actions don't depend on observation scheduling.
public final class FakePlaybackBookmarkStoring: PlaybackBookmarkStoring, @unchecked Sendable {
  public struct SetBookmarkCall: Sendable, Equatable {
    public let itemID: String
    public let episodeID: String?

    public init(itemID: String, episodeID: String?) {
      self.itemID = itemID
      self.episodeID = episodeID
    }
  }

  public init() {}

  /// One entry per `observeBookmark()` call, so a test can wait until the code under test has
  /// subscribed before it pushes (`await fake.observationRecorder.waitUntil(count: 1)`): a push
  /// that arrives before the subscription is dropped.
  public let observationRecorder = CallRecorder<Void>(label: "FakePlaybackBookmarkStoring.observeBookmark")

  private let subs = Locked<[AsyncStream<PlaybackBookmark?>.Continuation]>([])
  private let fetchBookmarkResultBox = Locked<PlaybackBookmark?>(nil)
  private let fetchBookmarkCallCountBox = Locked(0)
  public var fetchBookmarkCallCount: Int { fetchBookmarkCallCountBox.value }
  private let setBookmarkCallsBox = Locked<[SetBookmarkCall]>([])
  public var setBookmarkCalls: [String] { setBookmarkCallsBox.value.map(\.itemID) }
  public var setBookmarkIdentityCalls: [SetBookmarkCall] { setBookmarkCallsBox.value }
  private let setBookmarkErrorBox = Locked<Error?>(nil)

  public func stubSetBookmark(throwing error: Error?) {
    setBookmarkErrorBox.value = error
  }

  public func observeBookmark() -> AsyncStream<PlaybackBookmark?> {
    observationRecorder.record(())
    return AsyncStream { continuation in
      subs.withValue { $0.append(continuation) }
    }
  }

  public func stubFetchBookmark(_ bookmark: PlaybackBookmark?) {
    fetchBookmarkResultBox.value = bookmark
  }

  public func fetchBookmark() async -> PlaybackBookmark? {
    fetchBookmarkCallCountBox.withValue { $0 += 1 }
    return fetchBookmarkResultBox.value
  }

  public func setBookmark(itemID: String) async throws {
    try await setBookmark(itemID: itemID, episodeID: nil)
  }

  public func setBookmark(itemID: String, episodeID: String?) async throws {
    setBookmarkCallsBox.withValue { $0.append(SetBookmarkCall(itemID: itemID, episodeID: episodeID)) }
    if let error = setBookmarkErrorBox.value { throw error }
  }

  /// Test-only: simulates the subscription at `index` (creation order; defaults to the most
  /// recent one) emitting a new projection, including `nil` for a missing or soft-deleted target.
  public func push(_ bookmark: PlaybackBookmark?, at index: Int? = nil) {
    subs.withValue { continuations in
      let target = index ?? continuations.count - 1
      guard continuations.indices.contains(target) else { return }
      continuations[target].yield(bookmark)
    }
  }

  /// Test-only: ends every opened stream, so a consumer's `for await` loop returns. Streams opened
  /// later are unaffected.
  public func finishObservations() {
    for continuation in subs.value { continuation.finish() }
  }
}
