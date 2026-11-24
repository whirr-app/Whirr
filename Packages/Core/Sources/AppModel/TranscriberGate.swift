import AdSkip
import Foundation

/// The one on-device recogniser, shared by ad skip, the listener's transcript and Look Back: only
/// one of them runs an analyser at a time. The unit it serialises is an ad-skip transcription call,
/// a whole transcript session (paused or not) or a whole Look Back window. A waiter goes ahead of
/// lower claimants: Look Back first (the listener is waiting on it), then a session, then ad skip.
///
/// A waiter whose task is cancelled leaves the queue at once, so a cancelled ad-skip call parked
/// here never holds the gate. A holder releases only when its work returns, never on cancellation,
/// so two analysers never overlap. The gate never cancels anyone's work.
public actor TranscriberGate {
  public enum Claimant: Sendable, Equatable {
    case adSkip
    case session
    case lookBack
  }

  private struct Waiter {
    let id: UInt64
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var isHeld = false
  private var lookBackWaiters: [Waiter] = []
  private var sessionWaiters: [Waiter] = []
  private var adSkipWaiters: [Waiter] = []
  private var nextID: UInt64 = 0

  public init() {}

  /// Returns once `claimant` holds the gate; the caller must `release()` when its work returns.
  /// Throws `CancellationError`, without holding the gate, if the task is cancelled while waiting.
  public func acquire(for claimant: Claimant) async throws {
    try Task.checkCancellation()
    guard isHeld else {
      isHeld = true
      return
    }
    nextID += 1
    let id = nextID
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        enqueue(Waiter(id: id, continuation: continuation), for: claimant)
        // A cancellation can land between the check above and this registration; its `onCancel`
        // then runs `leave` before the waiter exists. Check again now that it does, so a cancelled
        // waiter is never resumed by a later `release`.
        if Task.isCancelled { leave(id) }
      }
      // A `release` that wins the race with that cancellation's `leave` hands the gate to a waiter
      // whose task is already cancelled. Hand it on rather than let it run holding the gate.
      if Task.isCancelled {
        release()
        throw CancellationError()
      }
    } onCancel: {
      Task { await self.leave(id) }
    }
  }

  /// Hands the gate to the first waiting Look Back, else the first waiting session, else the first
  /// waiting ad-skip call.
  public func release() {
    if lookBackWaiters.isEmpty == false {
      lookBackWaiters.removeFirst().continuation.resume()
    } else if sessionWaiters.isEmpty == false {
      sessionWaiters.removeFirst().continuation.resume()
    } else if adSkipWaiters.isEmpty == false {
      adSkipWaiters.removeFirst().continuation.resume()
    } else {
      isHeld = false
    }
  }

  /// Ad skip's transcriber, reached only through the gate.
  public nonisolated func gating(_ base: any EpisodeTranscribing) -> any EpisodeTranscribing {
    GatedTranscriber(gate: self, base: base)
  }

  var waitingCount: Int { lookBackWaiters.count + sessionWaiters.count + adSkipWaiters.count }
  var isHeldForTesting: Bool { isHeld }

  private func enqueue(_ waiter: Waiter, for claimant: Claimant) {
    switch claimant {
    case .adSkip: adSkipWaiters.append(waiter)
    case .session: sessionWaiters.append(waiter)
    case .lookBack: lookBackWaiters.append(waiter)
    }
  }

  /// A waiter cancelled before it was granted the gate leaves; one already granted holds it and
  /// releases when its work returns.
  private func leave(_ id: UInt64) {
    if let index = lookBackWaiters.firstIndex(where: { $0.id == id }) {
      lookBackWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    } else if let index = sessionWaiters.firstIndex(where: { $0.id == id }) {
      sessionWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    } else if let index = adSkipWaiters.firstIndex(where: { $0.id == id }) {
      adSkipWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
  }
}

private struct GatedTranscriber: EpisodeTranscribing {
  let gate: TranscriberGate
  let base: any EpisodeTranscribing

  func transcript(ofFileAt url: URL, windows: [TimeSpan]) async throws -> Transcript {
    try await gate.acquire(for: .adSkip)
    do {
      let transcript = try await base.transcript(ofFileAt: url, windows: windows)
      await gate.release()
      return transcript
    } catch {
      await gate.release()
      throw error
    }
  }
}
