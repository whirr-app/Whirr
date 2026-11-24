import PlayerCore
import SyncEngine

/// Serializes PlayerCore events for durable forwarding while leaving display application to the
/// synchronous ingress callback. The model remains the authority for every identity and lifecycle
/// decision; this type only owns the two stream tasks, their ordered buffer, and derived forwarding
/// bookkeeping.
@MainActor
internal final class PlaybackEventBridge {
  internal struct Envelope: Sendable {
    let event: PlaybackProgressEvent
    let modelGeneration: Int
  }

  internal struct BufferingProbeToken: Sendable, Equatable {
    let modelGeneration: Int
    let itemID: String?
    let episodeID: String?
  }

  @MainActor
  private final class ForwardingState {
    var lastReportedCadencePhase: PlaybackCadencePhase?
    var lastForwardedPlayerPhase: PlayerPhase?
  }

  @MainActor
  private final class IngressState {
    var lastObservedSequence: Int?
  }

  private let events: AsyncStream<PlaybackProgressEvent>
  private let sync: any PlaybackSyncing
  private let bufferingClock: any PlaybackBufferingClock
  private let ingest: @MainActor (PlaybackProgressEvent) -> Envelope?
  private let isCurrent: @MainActor (Envelope) -> Bool
  private let onLocalTimerExpiry: @MainActor (Envelope) -> Void
  private let onCompletion: @MainActor (Envelope, Bool) async -> Void
  private let onSegmentEnd: @MainActor (Envelope) async -> Void
  private let onBufferingProbeElapsed: @MainActor (BufferingProbeToken) -> Void
  private let ingressState = IngressState()
  private let forwardingState = ForwardingState()

  private var ingressTask: Task<Void, Never>?
  private var durableConsumerTask: Task<Void, Never>?
  private var syncEventContinuation: AsyncStream<Envelope>.Continuation?
  private var bufferingProbeTask: Task<Void, Never>?
  private var terminallyStopped = false

  init(
    events: AsyncStream<PlaybackProgressEvent>,
    sync: any PlaybackSyncing,
    bufferingClock: any PlaybackBufferingClock,
    ingest: @escaping @MainActor (PlaybackProgressEvent) -> Envelope?,
    isCurrent: @escaping @MainActor (Envelope) -> Bool,
    onLocalTimerExpiry: @escaping @MainActor (Envelope) -> Void,
    onCompletion: @escaping @MainActor (Envelope, Bool) async -> Void,
    onSegmentEnd: @escaping @MainActor (Envelope) async -> Void,
    onBufferingProbeElapsed: @escaping @MainActor (BufferingProbeToken) -> Void
  ) {
    self.events = events
    self.sync = sync
    self.bufferingClock = bufferingClock
    self.ingest = ingest
    self.isCurrent = isCurrent
    self.onLocalTimerExpiry = onLocalTimerExpiry
    self.onCompletion = onCompletion
    self.onSegmentEnd = onSegmentEnd
    self.onBufferingProbeElapsed = onBufferingProbeElapsed
  }

  deinit {
    ingressTask?.cancel()
    syncEventContinuation?.finish()
    durableConsumerTask?.cancel()
    bufferingProbeTask?.cancel()
  }

  func start() {
    guard terminallyStopped == false, ingressTask == nil, durableConsumerTask == nil else { return }

    let (syncEvents, continuation) = AsyncStream.makeStream(of: Envelope.self)
    syncEventContinuation = continuation

    let events = self.events
    let ingest = self.ingest
    let ingressState = self.ingressState
    ingressTask = Task {
      defer { continuation.finish() }
      for await event in events {
        guard Task.isCancelled == false else { break }
        ingressState.lastObservedSequence = event.sequence
        guard let envelope = ingest(event) else { continue }
        continuation.yield(envelope)
      }
    }

    let sync = self.sync
    let isCurrent = self.isCurrent
    let onLocalTimerExpiry = self.onLocalTimerExpiry
    let onCompletion = self.onCompletion
    let onSegmentEnd = self.onSegmentEnd
    let forwardingState = self.forwardingState
    durableConsumerTask = Task {
      for await envelope in syncEvents {
        guard Task.isCancelled == false else { break }
        await Self.forward(
          envelope: envelope,
          sync: sync,
          forwardingState: forwardingState,
          isCurrent: isCurrent,
          onLocalTimerExpiry: onLocalTimerExpiry,
          onCompletion: onCompletion,
          onSegmentEnd: onSegmentEnd)
      }
    }
  }

  /// Terminally stops this model's bridge. Manual `PlaybackModel.stop()` does not call
  /// this: generation/identity validation rejects its late events while the same bridge stays
  /// reusable for a later start. Logout is permanent for the bridge instance.
  func stop() {
    guard terminallyStopped == false else { return }
    terminallyStopped = true
    ingressTask?.cancel()
    syncEventContinuation?.finish()
    durableConsumerTask?.cancel()
    cancelBufferingProbe()
    syncEventContinuation = nil
  }

  /// A deterministic lifecycle barrier for owners that need to prove terminal teardown after an
  /// already-entered, cancellation-insensitive dependency call returns. Normal logout does not
  /// await this because its bounded SyncEngine quiescence is the production completion boundary.
  func waitForTermination() async {
    await ingressTask?.value
    await durableConsumerTask?.value
    await bufferingProbeTask?.value
  }

  func resetForwardingState() {
    forwardingState.lastReportedCadencePhase = nil
    forwardingState.lastForwardedPlayerPhase = nil
  }

  var lastObservedSequence: Int? { ingressState.lastObservedSequence }

  func armBufferingProbe(_ token: BufferingProbeToken) {
    guard terminallyStopped == false else { return }
    bufferingProbeTask?.cancel()
    let clock = bufferingClock
    let onElapsed = onBufferingProbeElapsed
    bufferingProbeTask = Task {
      await clock.sleep()
      guard Task.isCancelled == false else { return }
      onElapsed(token)
    }
  }

  func cancelBufferingProbe() {
    bufferingProbeTask?.cancel()
    bufferingProbeTask = nil
  }

  private static func forward(
    envelope: Envelope,
    sync: any PlaybackSyncing,
    forwardingState: ForwardingState,
    isCurrent: @MainActor (Envelope) -> Bool,
    onLocalTimerExpiry: @MainActor (Envelope) -> Void,
    onCompletion: @MainActor (Envelope, Bool) async -> Void,
    onSegmentEnd: @MainActor (Envelope) async -> Void
  ) async {
    guard Task.isCancelled == false, isCurrent(envelope) else { return }

    let event = envelope.event
    if event.sleepTimerExpiry == .expired, event.phase != .ended {
      onLocalTimerExpiry(envelope)
    }
    guard Task.isCancelled == false, isCurrent(envelope) else { return }

    let wasSeeking = forwardingState.lastForwardedPlayerPhase == .seeking
    forwardingState.lastForwardedPlayerPhase = event.phase
    let cadencePhase = mapCadencePhase(event.phase)
    let cadencePhaseChanged = cadencePhase != forwardingState.lastReportedCadencePhase

    if cadencePhaseChanged {
      forwardingState.lastReportedCadencePhase = cadencePhase
      guard Task.isCancelled == false, isCurrent(envelope) else { return }
      await sync.notifyPlaybackPhase(cadencePhase)
      guard Task.isCancelled == false, isCurrent(envelope) else { return }
    }

    guard Task.isCancelled == false, isCurrent(envelope) else { return }
    await sync.recordProgressTick(
      itemID: event.itemId,
      episodeID: event.episodeID,
      currentTime: event.currentTime,
      listenedDelta: event.listenedDelta,
      isFinished: event.phase == .ended,
      isSeek: event.phase == .seeking,
      sleepTimerExpired: event.sleepTimerExpiry == .expired)
    guard Task.isCancelled == false, isCurrent(envelope) else { return }

    if cadencePhaseChanged, cadencePhase == .paused {
      guard Task.isCancelled == false, isCurrent(envelope) else { return }
      await sync.notifyImmediateSyncTrigger(.paused)
      guard Task.isCancelled == false, isCurrent(envelope) else { return }
    }

    if wasSeeking, event.phase != .seeking {
      guard Task.isCancelled == false, isCurrent(envelope) else { return }
      await sync.notifyImmediateSyncTrigger(.seekCompleted)
      guard Task.isCancelled == false, isCurrent(envelope) else { return }
    }

    if event.phase == .ended {
      guard Task.isCancelled == false, isCurrent(envelope) else { return }
      await onCompletion(envelope, event.endBehavior == .advanceQueue)
    } else if event.segmentEnd == .reached {
      // After the tick and the paused trigger above, so the chapter's last position is recorded
      // before the next row's start moves the playhead.
      guard Task.isCancelled == false, isCurrent(envelope) else { return }
      await onSegmentEnd(envelope)
    }
  }

  /// PlayerCore's richer phase mapped to the Foundation-only cadence vocabulary SyncEngine owns.
  private static func mapCadencePhase(_ playerPhase: PlayerPhase) -> PlaybackCadencePhase {
    switch playerPhase {
    case .playing: return .playing
    case .paused, .ready: return .paused
    case .preparing, .buffering, .seeking: return .buffering
    case .stalled: return .buffering
    case .idle: return .idle
    case .ended, .failed: return .stopped
    }
  }
}
