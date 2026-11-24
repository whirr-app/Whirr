import AppModel
import Foundation

/// `NativeEpisodeServerSaveStatusReading`'s fake. Every read answers one stubbed snapshot (default
/// `.none`), and both observations are live: `observeStatuses` opens with the current aggregate
/// for its rows, then a test pushes a new snapshot to every subscriber (`push`) or an exact
/// aggregate (`pushStatuses`); `observeServerItemStatuses` opens with the stubbed server-item
/// index and follows `pushServerItemStatuses`. Neither stream finishes on its own.
///
/// `enqueueSnapshots` scripts the first snapshots the fake hands out, one per row read, so a test
/// can tell a later read from the first.
public final class FakeNativeEpisodeServerSaveStatusReading:
  NativeEpisodeServerSaveStatusReading, @unchecked Sendable
{
  public typealias Snapshot = NativeEpisodeServerSaveStatusSnapshot
  private typealias StatusContinuation = AsyncStream<[Int64: Snapshot]>.Continuation
  private typealias ServerItemContinuation = AsyncStream<[String: Snapshot]>.Continuation

  public enum Call: Sendable, Equatable {
    case status(feedID: Int64, episodeID: Int64)
    case statuses(feedID: Int64, episodeIDs: [Int64])
    case observeStatuses(feedID: Int64, episodeIDs: [Int64])
    case observeServerItemStatuses(serverItemID: String)
  }

  private struct State {
    var snapshot: Snapshot
    var queuedSnapshots: [Snapshot] = []
    var serverItemStatuses: [String: Snapshot]
    var subscribers: [UUID: (episodeIDs: [Int64], continuation: StatusContinuation)] = [:]
    var serverItemSubscribers: [UUID: ServerItemContinuation] = [:]
  }

  private let state: Locked<State>

  /// Every read and observation, in order.
  public let recorder = CallRecorder<Call>(label: "FakeNativeEpisodeServerSaveStatusReading")
  public var calls: [Call] { recorder.calls }

  public init(
    snapshot: Snapshot = Snapshot(status: .none),
    serverItemStatuses: [String: Snapshot] = [:]
  ) {
    state = Locked(State(snapshot: snapshot, serverItemStatuses: serverItemStatuses))
  }

  /// What every read returns, and what `observeStatuses` opens with, from now on.
  public func stubSnapshot(_ snapshot: Snapshot) {
    state.withValue { $0.snapshot = snapshot }
  }

  /// Queues snapshots that the next rows read answer before the stubbed one: each row of a
  /// `status`, a `statuses` or an `observeStatuses` opening takes the next queued snapshot, and
  /// once the queue is empty every row answers the stubbed one. An empty row list takes none.
  public func enqueueSnapshots(_ snapshots: [Snapshot]) {
    state.withValue { $0.queuedSnapshots.append(contentsOf: snapshots) }
  }

  /// What `observeServerItemStatuses` opens with, whatever the server item.
  public func stubServerItemStatuses(_ statuses: [String: Snapshot]) {
    state.withValue { $0.serverItemStatuses = statuses }
  }

  /// How many `observeStatuses` streams are open (a terminated one no longer counts).
  public var statusSubscriberCount: Int { state.value.subscribers.count }

  /// How many `observeServerItemStatuses` streams are open.
  public var serverItemSubscriberCount: Int { state.value.serverItemSubscribers.count }

  /// The next queued snapshot, else the stubbed one, for each of `episodeIDs`.
  private func readRows(_ episodeIDs: [Int64]) -> [Int64: Snapshot] {
    state.withValue { state -> [Int64: Snapshot] in
      var rows: [Int64: Snapshot] = [:]
      for episodeID in episodeIDs {
        rows[episodeID] =
          state.queuedSnapshots.isEmpty ? state.snapshot : state.queuedSnapshots.removeFirst()
      }
      return rows
    }
  }

  public func status(feedId: Int64, episodeId: Int64) async -> Snapshot {
    recorder.record(.status(feedID: feedId, episodeID: episodeId))
    return readRows([episodeId])[episodeId] ?? state.value.snapshot
  }

  public func statuses(feedId: Int64, episodeIds: [Int64]) async -> [Int64: Snapshot] {
    recorder.record(.statuses(feedID: feedId, episodeIDs: episodeIds))
    return readRows(episodeIds)
  }

  public func observeStatuses(
    feedId: Int64, episodeIds: [Int64]
  ) -> AsyncStream<[Int64: Snapshot]> {
    recorder.record(.observeStatuses(feedID: feedId, episodeIDs: episodeIds))
    let id = UUID()
    return AsyncStream { continuation in
      state.withValue { $0.subscribers[id] = (episodeIds, continuation) }
      continuation.yield(readRows(episodeIds))
      continuation.onTermination = { [weak self] _ in
        self?.state.withValue { $0.subscribers[id] = nil }
      }
    }
  }

  public func observeServerItemStatuses(serverItemId: String) -> AsyncStream<[String: Snapshot]> {
    recorder.record(.observeServerItemStatuses(serverItemID: serverItemId))
    let id = UUID()
    return AsyncStream { continuation in
      let opening = state.withValue { state -> [String: Snapshot] in
        state.serverItemSubscribers[id] = continuation
        return state.serverItemStatuses
      }
      continuation.yield(opening)
      continuation.onTermination = { [weak self] _ in
        self?.state.withValue { $0.serverItemSubscribers[id] = nil }
      }
    }
  }

  /// Test-only: makes `snapshot` current and emits it, for every row each `observeStatuses`
  /// subscriber watches.
  public func push(_ snapshot: Snapshot) {
    let subscribers = state.withValue { state -> [(episodeIDs: [Int64], continuation: StatusContinuation)] in
      state.snapshot = snapshot
      return Array(state.subscribers.values)
    }
    for subscriber in subscribers {
      let rows = subscriber.episodeIDs.map { ($0, snapshot) }
      subscriber.continuation.yield(Dictionary(uniqueKeysWithValues: rows))
    }
  }

  /// Test-only: emits exactly `statuses` to every `observeStatuses` subscriber, the way the durable
  /// projection delivers a full aggregate (rows absent from it project as `.none`).
  public func pushStatuses(_ statuses: [Int64: Snapshot]) {
    let subscribers = state.value.subscribers.values.map(\.continuation)
    for continuation in subscribers { continuation.yield(statuses) }
  }

  /// Test-only: emits `statuses` to every `observeServerItemStatuses` subscriber.
  public func pushServerItemStatuses(_ statuses: [String: Snapshot]) {
    let subscribers = state.withValue { state -> [ServerItemContinuation] in
      state.serverItemStatuses = statuses
      return Array(state.serverItemSubscribers.values)
    }
    for continuation in subscribers { continuation.yield(statuses) }
  }
}
