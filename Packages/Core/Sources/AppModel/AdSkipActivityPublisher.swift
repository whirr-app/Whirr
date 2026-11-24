import Foundation
import Persistence

/// What the status and the glyph are derived from, published only once it has held for `settle`.
/// A unit that defers at once, as every activation does while the speech model is missing, changes
/// it and changes it back inside that time, so nothing flashes.
struct AdSkipSettledState: Equatable, Sendable {
  var activity: AdSkipAnalysisActivity?
  var isEnabled: Bool
  var hasAllowedSignal: Bool
  var isAllowed: Bool
  var isDeferred: Bool
  var priority: AdSkipEpisodeIdentity?
  var isGrantActive: Bool

  /// A coordinator before any input: nothing to show.
  static let initial = AdSkipSettledState(
    activity: nil, isEnabled: false, hasAllowedSignal: false, isAllowed: false, isDeferred: false,
    priority: nil, isGrantActive: false)
}

extension AdSkipSettledState {
  /// Whether the settled state says anything about an episode analysis would cover.
  func speaks(about isSchedulable: Bool) -> Bool {
    isEnabled && hasAllowedSignal && isSchedulable
  }

  /// What the settled state says about one episode, once it has spoken for it. The card and the
  /// player answer differently only where the card says `queued` and the player says nothing.
  enum Standing: Equatable {
    /// The episode is being analysed, or is next.
    case checking
    /// Analysis may run, and other episodes are ahead of this one.
    case queued
    /// Analysis is held, and the episode is not analysed yet.
    case waiting(PlaybackAdAnalysisStatus.Hold)
  }

  /// The ladder from "analysis is on this episode" to "analysis waits for the conditions": the one
  /// rule behind both `episodeStatus(of:)` and `analysisStatus(for:)`.
  func standing(of identity: AdSkipEpisodeIdentity) -> Standing {
    let isPriority = priority == identity
    if activity?.identities.contains(identity) == true { return .checking }
    if isDeferred { return .waiting(.speechModel) }
    if isAllowed || (isGrantActive && isPriority) {
      return isPriority ? .checking : .queued
    }
    return .waiting(.conditions)
  }
}

/// The one-second settle between the coordinator's live state and what the glyph and the status
/// read, and the two broadcasters that publish it.
///
/// One object per coordinator, created in its `init` and touched only from the actor, so it is not
/// `Sendable`: one worker's state, never shared. Its task holds the coordinator weakly and asks it
/// for the live state again once the settle has passed, because an input may have changed it
/// without a note.
final class AdSkipActivityPublisher {
  /// The last state that held for `settle`: what the glyph and the status read.
  private(set) var settled = AdSkipSettledState.initial
  /// How long a change must hold before it is published.
  var settle: Duration
  private var settleTask: Task<Void, Never>?
  private let activityChanges: LatestValueBroadcaster<AdSkipAnalysisActivity>
  private let statusChanges: SkipRangeChangeBroadcaster

  init(
    activityChanges: LatestValueBroadcaster<AdSkipAnalysisActivity>,
    statusChanges: SkipRangeChangeBroadcaster,
    settle: Duration = AdSkipCoordinator.defaultActivitySettle
  ) {
    self.activityChanges = activityChanges
    self.statusChanges = statusChanges
    self.settle = settle
  }

  /// Whether a publish is waiting out the settle. For tests.
  var hasPendingSettle: Bool { settleTask != nil }

  /// Called by every input the status or glyph reads. Schedules a publish once the state has held,
  /// and cancels one whose change was undone in the meantime.
  func note(_ live: AdSkipSettledState, on coordinator: isolated AdSkipCoordinator) {
    settleTask?.cancel()
    settleTask = nil
    guard live != settled else { return }
    let delay = settle
    settleTask = Task { [weak coordinator] in
      if delay > .zero {
        try? await Task.sleep(for: delay)
      }
      guard Task.isCancelled == false else { return }
      await coordinator?.publishSettledState()
    }
  }

  /// Publishes the state the coordinator reads now, which may have changed again since the note.
  func publish(_ live: AdSkipSettledState) {
    settleTask = nil
    guard live != settled else { return }
    settled = live
    activityChanges.publish(live.activity)
    statusChanges.signal()
  }
}
