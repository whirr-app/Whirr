import ABSApi
import Foundation

/// Pure decision logic for one outbox drain attempt (API-CONVENTIONS.md rule 14). No I/O.
/// `SyncEngine`'s actor wraps it with the `ABSClient` call, the operation's persisted `attempts`
/// count (which drives backoff via `BackoffPolicy(failureCount:)`, so a relaunch between attempts
/// still computes the correct next delay), and the resulting `OutboxStore` transition.
public struct OutboxAcknowledgementPolicy: Sendable {
  public init() {}

  /// One row of a `local-all`-shaped batch acknowledgement. Mirrors
  /// `LocalSessionSyncResultDTO`/`ABSClient.syncLocalSessions` in ABSApi. Any batch-shaped kind
  /// goes through the same `decide(outcome:)` matching rule.
  public struct BatchResultRow: Sendable, Equatable {
    public let id: String
    public let success: Bool

    public init(id: String, success: Bool) {
      self.id = id
      self.success = success
    }
  }

  /// What actually happened when the drain attempted to send one operation.
  public enum AttemptOutcome: Sendable {
    /// An ordinary mutation's documented 2xx, such as the `progress` kind's PATCH.
    case ordinarySuccess
    /// A `local-all`-shaped response came back. `expectedID` is this operation's own stable client
    /// identity; `rows` is what the wire response reported, duplicates included. The matching
    /// rule below, not the caller, decides what counts as acknowledged.
    case batchResult(rows: [BatchResultRow], expectedID: String)
    /// The request failed with a classified API error (transport/429/5xx/4xx/401-after-refresh).
    case apiFailure(APIError)
    /// The attempt was cancelled. `APIError.cancelled` folds into `.apiFailure` too; this case
    /// covers a raw `CancellationError` catch. Distinct because cancellation is never
    /// dead-lettered and never counts as a further attempt.
    case cancelled
    /// The response could not be interpreted (ambiguous decode/protocol shape). Retains the row
    /// and stops the drain.
    case decodeAmbiguous
    /// A local row needed to address the right endpoint was read successfully and is absent. Not
    /// `decodeAmbiguous` ("could not tell"): a deleted row never changes on retry, so retaining it
    /// would halt the entity's queue every pass and strand everything behind it. `reason` must be
    /// a fixed category token, never an identifier (SECURITY.md).
    case localReferenceGone(reason: String)
  }

  /// What `OutboxStore` transition (if any) the caller must apply. For the two "halt" cases the
  /// caller must also stop draining this entity's queue for the rest of this pass.
  public enum Decision: Sendable, Equatable {
    case acknowledge
    case retryWaiting(nextAttemptDelay: TimeInterval)
    case deadLetter(reason: String)
    /// Decode/protocol ambiguity: requeue as `pending` (not a further attempt, no backoff), then
    /// the caller halts this entity's queue for this drain pass.
    case retainAndHaltQueue
    /// Cancellation: requeue as `pending` without incrementing attempts, then the caller halts
    /// this entity's queue for this pass (the whole drain is likely being torn down).
    case cancelledRequeue
    /// A 401 that survived the client's single refresh, or a send the latched client refused
    /// locally. Either way the account, not the row, is the problem (API-CONVENTIONS rules 3a/4a
    /// latch both), so requeue as `pending` and halt this entity's queue until re-authentication.
    /// Dead-lettering here would drop the row out of the progress pull's unacknowledged set and
    /// let an older server position win.
    case awaitReauthentication
  }

  /// - Parameters:
  ///   - attempts: the operation's persisted `OutboxOperationRecord.attempts` count after the
  ///     `sending` transition that preceded this attempt.
  public func decide(
    outcome: AttemptOutcome,
    attempts: Int,
    now: Date = Date(),
    randomUnit: Double = Double.random(in: 0...1)
  ) -> Decision {
    switch outcome {
    case .ordinarySuccess:
      return .acknowledge

    case .batchResult(let rows, let expectedID):
      let matches = rows.filter { $0.id == expectedID }
      if matches.count == 1, matches[0].success {
        return .acknowledge
      }
      // Missing, duplicate, or failed result entries remain queued. Not a hard failure, but it
      // must not spin, so it backs off like any other unacknowledged outcome.
      return .retryWaiting(nextAttemptDelay: backoffDelay(attempts: attempts, now: now, randomUnit: randomUnit))

    case .cancelled:
      return .cancelledRequeue

    case .decodeAmbiguous:
      return .retainAndHaltQueue

    case .localReferenceGone(let reason):
      return .deadLetter(reason: reason)

    case .apiFailure(let error):
      if case .cancelled = error {
        return .cancelledRequeue
      }
      if case .unauthorized = error {
        return .awaitReauthentication
      }
      if BackoffPolicy.isRetryable(error) {
        return .retryWaiting(nextAttemptDelay: backoffDelay(attempts: attempts, now: now, randomUnit: randomUnit))
      }
      return .deadLetter(reason: Self.privacySafeReason(for: error))
    }
  }

  private func backoffDelay(attempts: Int, now: Date, randomUnit: Double) -> TimeInterval {
    var backoff = BackoffPolicy(failureCount: max(0, attempts - 1))
    return backoff.nextDelay(now: now, randomUnit: randomUnit)
  }

  /// Category only, never an identifier, payload, or server-provided message text (SECURITY.md
  /// and ARCHITECTURE.md state the same rule for `DiagnosticsRecording`).
  /// `.transport`/`.rateLimited`/`.serverFailure`/`.cancelled` never reach here (classified as
  /// retryable/cancelled above); the fallback keeps the switch exhaustive without claiming a
  /// reason for a path that cannot occur.
  private static func privacySafeReason(for error: APIError) -> String {
    switch error {
    case .badRequest: return "badRequest"
    case .unauthorized: return "unauthorized"
    case .forbidden: return "forbidden"
    case .notFound: return "notFound"
    case .payloadTooLarge: return "payloadTooLarge"
    case .unexpectedStatus(let statusCode): return "unexpectedStatus(\(statusCode))"
    case .decoding: return "decoding"
    case .ambiguousLocalSessionResponse: return "ambiguousLocalSessionResponse"
    case .incompatibleServer: return "incompatibleServer"
    case .invalidServerConfiguration: return "invalidServerConfiguration"
    case .transport, .rateLimited, .serverFailure, .cancelled: return "unclassified"
    }
  }
}
