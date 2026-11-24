import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// Test double for `PlaybackControlling`. Lets a test set the `state` the adapter observes,
/// records every intent the adapter sends, and drives `progressEvents` via `emit(_:)`. No real
/// `PlayerReducer` or `AudioEngine` sits underneath. Not `@MainActor`, to match the protocol's
/// nonisolated requirements. Safe as `@unchecked Sendable` because each test drives it from one
/// synchronous flow.
final class FakeAdapterPlaybackControlling: PlaybackControlling, @unchecked Sendable {
  var state: PlayerState = .idle
  /// Optional overrides let forwarding tests make these values disagree with `state`. When unset,
  /// the fake derives them from `state`, as the protocol defaults do.
  var quickActionsOverride: PlayerQuickActionsState?
  var quickActionsSleepTimerOverride: SleepTimerState?

  var quickActions: PlayerQuickActionsState {
    if let quickActionsOverride { return quickActionsOverride }
    let sleepTimerMode: PlayerQuickActionsSleepTimerMode =
      switch state.sleepTimer.mode {
      case .off: .off
      case .countdown: .countdown(configuredSeconds: state.sleepTimer.configuredSeconds)
      case .endOfChapter: .endOfChapter
      }
    return PlayerQuickActionsState(
      rate: state.rate,
      sleepTimerMode: sleepTimerMode,
      item: state.item.map {
        PlayerQuickActionsItem(
          id: $0.id,
          episodeID: $0.episodeID,
          totalDuration: $0.timeline.totalDuration,
          hasChapters: $0.chapters.chapters.isEmpty == false)
      })
  }

  var quickActionsSleepTimer: SleepTimerState {
    quickActionsSleepTimerOverride ?? state.sleepTimer
  }

  let progressEvents: AsyncStream<PlaybackProgressEvent>
  private let progressContinuation: AsyncStream<PlaybackProgressEvent>.Continuation
  private(set) var sentIntents: [PlayerIntent] = []

  init() {
    var continuation: AsyncStream<PlaybackProgressEvent>.Continuation!
    progressEvents = AsyncStream { continuation = $0 }
    progressContinuation = continuation
  }

  func send(_ intent: PlayerIntent) {
    sentIntents.append(intent)
  }

  /// Pushes a progress event to whatever is iterating `progressEvents`, such as
  /// `NowPlayingMetadataAdapter`'s listener task. The fake never emits these on its own, as it has
  /// no real `PlayerReducer` underneath.
  func emit(_ event: PlaybackProgressEvent) {
    progressContinuation.yield(event)
  }
}
