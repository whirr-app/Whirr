import ABSApi
import Foundation
import Persistence

/// One account-scoped serialized save flight. Re-entrant actor calls are coalesced in the flight
/// registry; the durable attempt store is the crash/relaunch boundary between network operations.
///
/// Members live beside this declaration by seam: `+Flights` (coalescing), `+Pipeline` (the save
/// state machine), `+Preflight` (the read that decides whether to enqueue).
public actor NativeEpisodeServerSaveCoordinator: NativeEpisodeServerSaving {
  let accountReader: any NativeEpisodeServerSaveAccountReading
  let capabilityReader: any ServerPodcastMutationCapabilityReading
  let commandReader: any NativeEpisodeServerSaveCommandReading
  let destinationResolver: any NativeEpisodeServerSaveDestinationResolving
  let podcastWriter: any NativeEpisodeServerSavePodcastWriting
  let itemDetailReader: any NativeEpisodeServerSaveItemDetailReading
  let attemptStore: any NativeEpisodeServerSaveAttemptStoring
  let nativeSubscriptions: any NativePodcastSubscriptionsReading
  /// The shared fence and durable-write layer. Immutable and built from the same dependencies, so
  /// a second instance cannot exist for one account graph.
  let fencer: NativeEpisodeServerSaveFencer
  /// The destructive state machine. Reached only through `remove`, `reconcileRemoval` and
  /// `recoverRemoval`, which keep flight serialization on the coordinator.
  let removalPipeline: NativeEpisodeServerSaveRemovalPipeline

  /// The per-key flight table and its id counter. Internal because `startSerializedFlight` installs
  /// flights from another file.
  var flightRegistry = NativeEpisodeServerSaveFlightRegistry()

  /// Pauses between the foreground reconciliations after an accepted enqueue. The server
  /// downloads the episode after it answers, so the first look almost always misses it; later
  /// looks let Requested become Saved while the listener is on screen. A convenience only:
  /// relaunch recovery and the show projection's recovery pass converge anything it missed.
  public static let foregroundConvergenceDelays: [Duration] = [
    .seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(80),
  ]
  let foregroundConvergenceDelays: [Duration]
  /// The most recent single save's detached convergence, so a test can await its end. Set from
  /// `+Preflight`, which admits the accepted result.
  var lastConvergence: Task<Void, Never>?
  /// The most recent batch's detached convergence, so a test can await its end.
  var lastBatchConvergence: Task<Void, Never>?

  public init(
    accountReader: any NativeEpisodeServerSaveAccountReading,
    capabilityReader: any ServerPodcastMutationCapabilityReading,
    commandReader: any NativeEpisodeServerSaveCommandReading,
    destinationResolver: any NativeEpisodeServerSaveDestinationResolving,
    podcastWriter: any NativeEpisodeServerSavePodcastWriting,
    itemDetailReader: any NativeEpisodeServerSaveItemDetailReading,
    attemptStore: any NativeEpisodeServerSaveAttemptStoring,
    nativeSubscriptions: any NativePodcastSubscriptionsReading,
    foregroundConvergenceDelays: [Duration] = NativeEpisodeServerSaveCoordinator.foregroundConvergenceDelays
  ) {
    self.accountReader = accountReader
    self.capabilityReader = capabilityReader
    self.commandReader = commandReader
    self.destinationResolver = destinationResolver
    self.podcastWriter = podcastWriter
    self.itemDetailReader = itemDetailReader
    self.attemptStore = attemptStore
    self.nativeSubscriptions = nativeSubscriptions
    self.foregroundConvergenceDelays = foregroundConvergenceDelays
    let fencer = NativeEpisodeServerSaveFencer(
      attemptStore: attemptStore,
      accountReader: accountReader,
      commandReader: commandReader,
      nativeSubscriptions: nativeSubscriptions)
    self.fencer = fencer
    self.removalPipeline = NativeEpisodeServerSaveRemovalPipeline(
      fencer: fencer,
      attemptStore: attemptStore,
      capabilityReader: capabilityReader,
      podcastWriter: podcastWriter)
  }

  public func save(
    feedId: Int64,
    episodeId: Int64,
    choice: ServerPodcastSaveChoice? = nil
  ) async -> NativeEpisodeServerSaveOutcome {
    await save(
      feedId: feedId, episodeId: episodeId, choice: choice, convergence: .foreground)
  }

  func save(
    feedId: Int64,
    episodeId: Int64,
    choice: ServerPodcastSaveChoice?,
    convergence: NativeEpisodeServerSaveConvergencePolicy,
    knownShow: NativeEpisodeServerSaveKnownShow? = nil
  ) async -> NativeEpisodeServerSaveOutcome {
    let key = NativeEpisodeServerSaveFlightKey(feedID: feedId, episodeID: episodeId)
    return await startSerializedFlight(key: key) { [self] in
      await runSave(
        feedId: feedId, episodeId: episodeId, choice: choice, convergence: convergence,
        knownShow: knownShow)
    }
  }
}
