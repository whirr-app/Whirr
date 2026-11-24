import PlayerCore

/// Inert stand-in for `AppDependencies.player` in tests that only need a satisfiable
/// `PlaybackControlling` (e.g. `AppModelWiringTests`/`RootModelTests` composing the whole
/// dependency graph) rather than real playback behaviour. The real conformance is
/// `PlayerController` (`Sources/PlayerCore/PlayerController.swift`).
public final class FakePlaybackControlling: PlaybackControlling, @unchecked Sendable {
  private let stateBox = Locked(PlayerState.idle)
  private let intentBox = Locked<Bool?>(nil)
  private let sentIntents = Locked<[PlayerIntent]>([])
  private let continuation: AsyncStream<PlaybackProgressEvent>.Continuation
  public let progressEvents: AsyncStream<PlaybackProgressEvent>

  public var state: PlayerState {
    get { stateBox.value }
    set { stateBox.value = newValue }
  }

  /// Defaults to `state`'s own flag, so tests that only care about intent can keep setting
  /// `state.isPlaybackIntended`. Setting this explicitly lets the fake disagree with itself, so a
  /// test can pin which of the two a reader used. The real controller publishes them separately,
  /// and reading intent out of `state` rebuilds play/pause surfaces on every position tick.
  public var isPlaybackIntended: Bool {
    get { intentBox.value ?? stateBox.value.isPlaybackIntended }
    set { intentBox.value = newValue }
  }

  public var intents: [PlayerIntent] { sentIntents.value }

  public init() {
    var continuation: AsyncStream<PlaybackProgressEvent>.Continuation!
    progressEvents = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  /// Records the intent. A `.setRate` also lands in `state.rate`, as the reducer's does, so a
  /// caller that sends only real rate changes sees the engine it would see in the app.
  public func send(_ intent: PlayerIntent) {
    sentIntents.withValue { $0.append(intent) }
    if case .setRate(let rate) = intent {
      stateBox.withValue { $0.rate = rate }
    }
  }

  /// Test-only: simulates a progress tick PlayerCore would have emitted.
  public func pushProgress(_ event: PlaybackProgressEvent) {
    continuation.yield(event)
  }
}
