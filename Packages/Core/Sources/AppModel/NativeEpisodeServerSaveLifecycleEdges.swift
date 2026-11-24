import Persistence

/// The two lifecycle sources a server-save presentation watches, each reduced to the edges that
/// matter. The show and the card feed their own observation loops through these, so both clear and
/// re-enable on exactly the same values.
enum NativeEpisodeServerSaveLifecycleEdges {
  /// The native-subscriptions switch. Every `false` clears, so a repeated `false` clears again;
  /// only a `false → true` turn re-enables, because the clear left capability and status empty.
  struct SubscriptionsEdge: Sendable {
    enum Event: Sendable, Equatable {
      case clear(NativeEpisodeServerSaveLifecycleTrigger)
      case reenabled
    }

    private var previous: Bool?

    mutating func next(_ enabled: Bool) -> Event? {
      defer { previous = enabled }
      if enabled == false { return .clear(.nativeSubscriptionsDisabled) }
      return previous == false ? .reenabled : nil
    }
  }

  /// The account identity. The first value is the baseline the presentation was built under and
  /// clears nothing. After it, `nil` is a sign-out, every time it arrives, and any other change is
  /// a replacement, including a `nil → X` sign-in.
  struct AccountEdge: Sendable {
    private var hasBaseline = false
    private var previous: AccountIdentity?

    mutating func next(_ identity: AccountIdentity?) -> NativeEpisodeServerSaveLifecycleTrigger? {
      defer {
        hasBaseline = true
        previous = identity
      }
      guard hasBaseline else { return nil }
      if identity == nil { return .accountUnavailable }
      return identity != previous ? .accountReplaced : nil
    }
  }
}
