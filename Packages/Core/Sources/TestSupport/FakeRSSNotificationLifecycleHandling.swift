import SyncEngine

/// `RSSNotificationLifecycleHandling`'s fake: records each `disarm(feedID:)` in order. An actor, so
/// a test reads `feedIDs` with `await`, as it would on the real coordinator.
public actor FakeRSSNotificationLifecycleHandling: RSSNotificationLifecycleHandling {
  /// The feed ID of every `disarm` call, in order; `nil` is "every feed".
  public nonisolated let recorder = CallRecorder<Int64?>(
    label: "FakeRSSNotificationLifecycleHandling disarms")

  private nonisolated let disarmHook = Locked<(@Sendable (Int64?) async -> Void)?>(nil)

  public init() {}

  /// The feed IDs disarmed so far, in order.
  public var feedIDs: [Int64?] { recorder.calls }

  /// Runs `hook` inside every `disarm`, after the call is recorded, so a test can act at the
  /// moment the feed is disarmed (delete the feed, say); `nil` removes it.
  public nonisolated func setDisarmHook(_ hook: (@Sendable (Int64?) async -> Void)?) {
    disarmHook.value = hook
  }

  public func disarm(feedID: Int64?) async {
    recorder.record(feedID)
    if let hook = disarmHook.value { await hook(feedID) }
  }
}
