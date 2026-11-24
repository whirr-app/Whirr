import ABSApi
import Foundation
import SyncEngine

/// `BackgroundTransferring`'s fake: every adapter call is recorded (in order), and
/// `pushEvent`/`setCurrentTasks` let a test drive the coordinator's single-consumer event and
/// launch-reconciliation paths without a real background `URLSession`. The real conformance is
/// `BackgroundDownloadSessionAdapter`.
public final class FakeBackgroundTransferring: BackgroundTransferring, @unchecked Sendable {
  public enum RecordedCall: Sendable, Equatable {
    case enqueue(identity: TransferIdentity, itemID: String, fileID: String, destinationURL: URL)
    case pause(identity: TransferIdentity)
    case resume(identity: TransferIdentity)
    case cancel(identity: TransferIdentity)
  }

  /// One `enqueue`'s full arguments, for a test that asserts on the request itself rather than
  /// the identifiers `RecordedCall.enqueue` keeps.
  public struct EnqueuedRequest: Sendable, Equatable {
    public let request: AuthorizedTransferRequest
    public let destination: DownloadDestinationToken
  }

  private let callsBox = Locked<[RecordedCall]>([])
  public var calls: [RecordedCall] { callsBox.value }

  private let requestsBox = Locked<[EnqueuedRequest]>([])

  /// Every `enqueue`, in order, with the whole request and destination.
  public var enqueuedRequests: [EnqueuedRequest] { requestsBox.value }

  public let events: AsyncStream<BackgroundTransferEvent>
  private let continuation: AsyncStream<BackgroundTransferEvent>.Continuation

  private let snapshotsBox = Locked<[BackgroundTransferSnapshot]>([])
  private let undeliveredBox = Locked<Set<TransferIdentity>>([])
  private let acknowledgedBox = Locked<[TransferIdentity]>([])

  /// Every `acknowledgeFinish(identity:)`, in order. Kept apart from `calls` so tests that compare
  /// the adapter's transfer calls exactly are unaffected by acknowledgements.
  public var acknowledgedFinishes: [TransferIdentity] { acknowledgedBox.value }

  private let terminatedBox: Locked<Bool>

  /// Whether the `events` consumer has gone (its task finished or was cancelled), so a test can
  /// prove a coordinator unsubscribed.
  public var eventsTerminated: Bool { terminatedBox.value }

  public init() {
    var continuation: AsyncStream<BackgroundTransferEvent>.Continuation!
    let terminated = Locked(false)
    terminatedBox = terminated
    events = AsyncStream { streamContinuation in
      continuation = streamContinuation
      streamContinuation.onTermination = { _ in terminated.value = true }
    }
    self.continuation = continuation
  }

  public func enqueue(_ request: AuthorizedTransferRequest, destination: DownloadDestinationToken) async {
    let entry = EnqueuedRequest(request: request, destination: destination)
    requestsBox.withValue { $0.append(entry) }
    callsBox.withValue {
      $0.append(
        .enqueue(
          identity: destination.identity, itemID: request.itemID ?? "", fileID: request.fileID ?? "",
          destinationURL: destination.destinationURL))
    }
  }

  public func pause(identity: TransferIdentity) async {
    callsBox.withValue { $0.append(.pause(identity: identity)) }
  }

  public func resume(identity: TransferIdentity) async {
    callsBox.withValue { $0.append(.resume(identity: identity)) }
  }

  public func cancel(identity: TransferIdentity) async {
    callsBox.withValue { $0.append(.cancel(identity: identity)) }
  }

  public func currentTasks() async -> [BackgroundTransferSnapshot] {
    snapshotsBox.value
  }

  public func undeliveredFinishes() async -> Set<TransferIdentity> {
    undeliveredBox.value
  }

  public func acknowledgeFinish(identity: TransferIdentity) async {
    acknowledgedBox.withValue { $0.append(identity) }
    undeliveredBox.withValue { _ = $0.remove(identity) }
  }

  /// Test-only: seeds what `undeliveredFinishes()` reports, as an adapter would after yielding a
  /// `.finished` that no coordinator has handled yet.
  public func setUndeliveredFinishes(_ identities: Set<TransferIdentity>) {
    undeliveredBox.value = identities
  }

  /// Test-only: seeds what `currentTasks()` reports (launch reconciliation).
  public func setCurrentTasks(_ snapshots: [BackgroundTransferSnapshot]) {
    snapshotsBox.value = snapshots
  }

  /// Test-only: pushes an event through the single `events` stream, as the real adapter would.
  /// Returns `false` once the consumer has gone and the event was dropped.
  @discardableResult
  public func pushEvent(_ event: BackgroundTransferEvent) -> Bool {
    if case .terminated = continuation.yield(event) { return false }
    return true
  }
}
