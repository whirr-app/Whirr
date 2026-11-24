import Foundation
import SyncEngine

/// `DownloadPreferences`'s fake. Same shape as `FakeNetworkConditions`: a synchronous getter plus
/// a single-consumer `changes` stream.
public final class FakeDownloadPreferences: DownloadPreferences, @unchecked Sendable {
  private let allowCellularBox: Locked<Bool>
  public var allowCellular: Bool { allowCellularBox.value }
  private let deleteWhenFinishedBox: Locked<Bool>
  public var deleteWhenFinished: Bool { deleteWhenFinishedBox.value }
  private let queueAutoDownloadPolicyBox: Locked<QueueAutoDownloadPolicy>
  public var queueAutoDownloadPolicy: QueueAutoDownloadPolicy {
    queueAutoDownloadPolicyBox.value
  }
  private let savedShelfAutoDownloadPolicyBox: Locked<SavedShelfAutoDownloadPolicy>
  public var savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy {
    savedShelfAutoDownloadPolicyBox.value
  }
  private let storageCeilingBytesBox: Locked<Int64?>
  public var storageCeilingBytes: Int64? { storageCeilingBytesBox.value }
  private let storageCeilingSetCallCountBox = Locked(0)
  public var storageCeilingSetCallCount: Int { storageCeilingSetCallCountBox.value }
  private let changesSubscriptionCountBox = Locked(0)
  /// How many times `changes` has been read, whether or not the stream was consumed. A test of
  /// deferred construction asserts it stays 0.
  public var changesSubscriptionCount: Int { changesSubscriptionCountBox.value }

  private let changesLock = NSLock()
  private var subscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]
  private var deleteWhenFinishedSubscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]
  private var queueAutoDownloadPolicySubscribers: [UUID: AsyncStream<QueueAutoDownloadPolicy>.Continuation] = [:]
  private var savedShelfAutoDownloadPolicySubscribers: [UUID: AsyncStream<SavedShelfAutoDownloadPolicy>.Continuation] =
    [:]
  private var storageCeilingBytesSubscribers: [UUID: AsyncStream<Int64?>.Continuation] = [:]

  public init(
    allowCellular: Bool = false,
    deleteWhenFinished: Bool = false,
    queueAutoDownloadPolicy: QueueAutoDownloadPolicy = .never,
    savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy = .never,
    storageCeilingBytes: Int64? = nil
  ) {
    allowCellularBox = Locked(allowCellular)
    deleteWhenFinishedBox = Locked(deleteWhenFinished)
    queueAutoDownloadPolicyBox = Locked(queueAutoDownloadPolicy)
    savedShelfAutoDownloadPolicyBox = Locked(savedShelfAutoDownloadPolicy)
    storageCeilingBytesBox = Locked(storageCeilingBytes)
  }

  public func setAllowCellular(_ allowed: Bool) async {
    allowCellularBox.value = allowed
    for continuation in currentSubscribers() {
      continuation.yield(allowed)
    }
  }

  public var changes: AsyncStream<Bool> {
    changesSubscriptionCountBox.withValue { $0 += 1 }
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else { return }
      changesLock.lock()
      subscribers[id] = continuation
      changesLock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeSubscriber(id)
      }
    }
  }

  public func setDeleteWhenFinished(_ enabled: Bool) async {
    deleteWhenFinishedBox.value = enabled
    for continuation in currentDeleteWhenFinishedSubscribers() {
      continuation.yield(enabled)
    }
  }

  public var deleteWhenFinishedChanges: AsyncStream<Bool> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else { return }
      changesLock.lock()
      deleteWhenFinishedSubscribers[id] = continuation
      changesLock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeDeleteWhenFinishedSubscriber(id)
      }
    }
  }

  public func setQueueAutoDownloadPolicy(_ policy: QueueAutoDownloadPolicy) async {
    queueAutoDownloadPolicyBox.value = policy
    for continuation in currentQueueAutoDownloadPolicySubscribers() {
      continuation.yield(policy)
    }
  }

  public var queueAutoDownloadPolicyChanges: AsyncStream<QueueAutoDownloadPolicy> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else { return }
      changesLock.lock()
      queueAutoDownloadPolicySubscribers[id] = continuation
      changesLock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeQueueAutoDownloadPolicySubscriber(id)
      }
    }
  }

  public func setSavedShelfAutoDownloadPolicy(_ policy: SavedShelfAutoDownloadPolicy) async {
    savedShelfAutoDownloadPolicyBox.value = policy
    for continuation in currentSavedShelfAutoDownloadPolicySubscribers() {
      continuation.yield(policy)
    }
  }

  public var savedShelfAutoDownloadPolicyChanges: AsyncStream<SavedShelfAutoDownloadPolicy> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else { return }
      changesLock.lock()
      savedShelfAutoDownloadPolicySubscribers[id] = continuation
      changesLock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeSavedShelfAutoDownloadPolicySubscriber(id)
      }
    }
  }

  public func setStorageCeilingBytes(_ ceiling: Int64?) async {
    storageCeilingSetCallCountBox.withValue { $0 += 1 }
    storageCeilingBytesBox.value = ceiling
    for continuation in currentStorageCeilingBytesSubscribers() {
      continuation.yield(ceiling)
    }
  }

  public var storageCeilingBytesChanges: AsyncStream<Int64?> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else { return }
      changesLock.lock()
      storageCeilingBytesSubscribers[id] = continuation
      changesLock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeStorageCeilingBytesSubscriber(id)
      }
    }
  }

  private func removeSubscriber(_ id: UUID) {
    changesLock.lock()
    subscribers.removeValue(forKey: id)
    changesLock.unlock()
  }

  private func currentSubscribers() -> [AsyncStream<Bool>.Continuation] {
    changesLock.lock()
    defer { changesLock.unlock() }
    return Array(subscribers.values)
  }

  private func removeDeleteWhenFinishedSubscriber(_ id: UUID) {
    changesLock.lock()
    deleteWhenFinishedSubscribers.removeValue(forKey: id)
    changesLock.unlock()
  }

  private func currentDeleteWhenFinishedSubscribers() -> [AsyncStream<Bool>.Continuation] {
    changesLock.lock()
    defer { changesLock.unlock() }
    return Array(deleteWhenFinishedSubscribers.values)
  }

  private func removeQueueAutoDownloadPolicySubscriber(_ id: UUID) {
    changesLock.lock()
    queueAutoDownloadPolicySubscribers.removeValue(forKey: id)
    changesLock.unlock()
  }

  private func currentQueueAutoDownloadPolicySubscribers()
    -> [AsyncStream<QueueAutoDownloadPolicy>.Continuation]
  {
    changesLock.lock()
    defer { changesLock.unlock() }
    return Array(queueAutoDownloadPolicySubscribers.values)
  }

  private func removeSavedShelfAutoDownloadPolicySubscriber(_ id: UUID) {
    changesLock.lock()
    savedShelfAutoDownloadPolicySubscribers.removeValue(forKey: id)
    changesLock.unlock()
  }

  private func currentSavedShelfAutoDownloadPolicySubscribers()
    -> [AsyncStream<SavedShelfAutoDownloadPolicy>.Continuation]
  {
    changesLock.lock()
    defer { changesLock.unlock() }
    return Array(savedShelfAutoDownloadPolicySubscribers.values)
  }

  private func removeStorageCeilingBytesSubscriber(_ id: UUID) {
    changesLock.lock()
    storageCeilingBytesSubscribers.removeValue(forKey: id)
    changesLock.unlock()
  }

  private func currentStorageCeilingBytesSubscribers()
    -> [AsyncStream<Int64?>.Continuation]
  {
    changesLock.lock()
    defer { changesLock.unlock() }
    return Array(storageCeilingBytesSubscribers.values)
  }
}
