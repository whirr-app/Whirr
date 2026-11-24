import Persistence

/// `SavedShelfReading`'s fake. Both observations are live: tests push a new whole projection
/// through `observeSavedIdentities()` (what the status store consumes) or through a specific
/// `observeSaved` subscription, in creation order, like `FakeHomeReading`.
public final class FakeSavedShelfReading: SavedShelfReading, @unchecked Sendable {
  public init() {}

  public struct SavedCall: Equatable, Sendable {
    public let filter: ItemMediaCategory?
    public let limit: Int?

    public init(filter: ItemMediaCategory?, limit: Int?) {
      self.filter = filter
      self.limit = limit
    }
  }

  private let savedIdentityContinuations =
    Locked<[AsyncStream<Set<SavedShelfIdentity>>.Continuation]>([])
  private let savedIdentitySubscriptionCountBox = Locked(0)

  /// Every `observeSaved` call, in order.
  public let savedRecorder = CallRecorder<SavedCall>(label: "FakeSavedShelfReading.observeSaved")
  public var savedCalls: [SavedCall] { savedRecorder.calls }
  private let savedContinuations = Locked<[AsyncStream<[SavedShelfItem]>.Continuation]>([])

  public func observeSaved(
    filter: ItemMediaCategory?, limit: Int?
  ) -> AsyncStream<[SavedShelfItem]> {
    savedRecorder.record(SavedCall(filter: filter, limit: limit))
    return AsyncStream { continuation in
      savedContinuations.withValue { $0.append(continuation) }
    }
  }

  /// Test-only: simulates the `observeSaved` subscription at `index` (creation order; defaults to
  /// the newest, which is what production observes) firing again.
  public func pushSaved(_ entries: [SavedShelfItem], at index: Int? = nil) {
    savedContinuations.withValue { continuations in
      let target = index ?? continuations.count - 1
      guard continuations.indices.contains(target) else { return }
      continuations[target].yield(entries)
    }
  }

  public func observeSavedIdentities() -> AsyncStream<Set<SavedShelfIdentity>> {
    savedIdentitySubscriptionCountBox.withValue { $0 += 1 }
    return AsyncStream { continuation in
      savedIdentityContinuations.withValue { $0.append(continuation) }
    }
  }

  /// Test-only: simulates `observeSavedIdentities()` firing again.
  public func pushSavedIdentities(_ identities: Set<SavedShelfIdentity>) {
    for continuation in savedIdentityContinuations.value { continuation.yield(identities) }
  }

  /// Test-only: how many `observeSavedIdentities()` subscriptions have been opened.
  public var savedIdentitySubscriptionCount: Int {
    savedIdentitySubscriptionCountBox.value
  }
}
