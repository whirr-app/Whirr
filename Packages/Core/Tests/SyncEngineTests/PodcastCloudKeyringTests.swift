import Foundation
import TestSupport
import Testing

@testable import SyncEngine

@Suite(.timeLimit(.minutes(1))) struct PodcastCloudKeyringTests {
  private let firstKey = try! PodcastCloudRecordNameKey(bytes: Data(repeating: 0x11, count: 32))
  private let secondKey = try! PodcastCloudRecordNameKey(bytes: Data(repeating: 0x22, count: 32))

  @Test func presentKeyringIsAdoptedWithoutMinting() async throws {
    let store = InMemoryPodcastCloudKeyringStore(initial: firstKey.bytes)
    let bootstrap = PodcastCloudKeyringBootstrap(mint: { fatalError("present keyring must not mint") })

    let result = try await bootstrap.resolveKey(using: store)

    #expect(result == firstKey)
    let snapshot = await store.snapshot()
    #expect(snapshot.fetchCount == 1)
    #expect(snapshot.saveCount == 0)
  }

  @Test func absentKeyringMintsSavesAndReturnsTheMintedKey() async throws {
    let store = InMemoryPodcastCloudKeyringStore()
    let bootstrap = PodcastCloudKeyringBootstrap(mint: { firstKey })

    let result = try await bootstrap.resolveKey(using: store)

    #expect(result == firstKey)
    let snapshot = await store.snapshot()
    #expect(snapshot.storedKey == firstKey.bytes)
    #expect(snapshot.fetchCount == 1)
    #expect(snapshot.saveCount == 1)
  }

  @Test func concurrentMintsAdoptTheSingleWinningKeyAfterFetchingFirst() async throws {
    let store = InMemoryPodcastCloudKeyringStore(fetchBarrierTarget: 2)
    let first = PodcastCloudKeyringBootstrap(mint: { firstKey })
    let second = PodcastCloudKeyringBootstrap(mint: { secondKey })

    async let firstResult = first.resolveKey(using: store)
    async let secondResult = second.resolveKey(using: store)
    let results = try await (firstResult, secondResult)

    #expect(results.0 == results.1)
    let snapshot = await store.snapshot()
    #expect(snapshot.storedKey == results.0.bytes)
    #expect(snapshot.storedKey == firstKey.bytes || snapshot.storedKey == secondKey.bytes)
    #expect(snapshot.fetchCount == 2)
    #expect(snapshot.saveCount == 2)
    #expect(snapshot.completedFetchesBeforeFirstSave == 2)
  }

  @Test func malformedPresentAndWinningKeyringsAreRejectedWithoutRetrying() async {
    let malformed = Data(repeating: 0, count: 31)
    let presentStore = InMemoryPodcastCloudKeyringStore(initial: malformed)
    let presentBootstrap = PodcastCloudKeyringBootstrap(mint: { fatalError("malformed keyring must not mint") })
    await #expect(throws: PodcastCloudKeyringError.corruptKeyring) {
      try await presentBootstrap.resolveKey(using: presentStore)
    }
    let presentSnapshot = await presentStore.snapshot()
    #expect(presentSnapshot.saveCount == 0)

    let winningStore = InMemoryPodcastCloudKeyringStore(saveResult: .serverRecordChanged(recordNameKey: malformed))
    let winningBootstrap = PodcastCloudKeyringBootstrap(mint: { firstKey })
    await #expect(throws: PodcastCloudKeyringError.corruptKeyring) {
      try await winningBootstrap.resolveKey(using: winningStore)
    }
    let winningSnapshot = await winningStore.snapshot()
    #expect(winningSnapshot.saveCount == 1)
  }

  @Test func cacheOnlyReturnsAKeyForTheSameFence() {
    let fence = PodcastCloudAccountFence(
      container: "container", environment: "Development", zone: "zone", iCloudUserRecordID: "user", accountEpoch: 1)
    let cache = PodcastCloudKeyringCache(key: firstKey, fence: fence)
    #expect(cache.key(for: fence) == firstKey)
    for changed in [
      PodcastCloudAccountFence(
        container: "other", environment: "Development", zone: "zone", iCloudUserRecordID: "user", accountEpoch: 1),
      PodcastCloudAccountFence(
        container: "container", environment: "Production", zone: "zone", iCloudUserRecordID: "user", accountEpoch: 1),
      PodcastCloudAccountFence(
        container: "container", environment: "Development", zone: "other", iCloudUserRecordID: "user", accountEpoch: 1),
      PodcastCloudAccountFence(
        container: "container", environment: "Development", zone: "zone", iCloudUserRecordID: "other", accountEpoch: 1),
      PodcastCloudAccountFence(
        container: "container", environment: "Development", zone: "zone", iCloudUserRecordID: "user", accountEpoch: 2),
    ] {
      #expect(cache.key(for: changed) == nil)
    }
  }
}

private actor InMemoryPodcastCloudKeyringStore: PodcastCloudKeyringStore {
  private var storedKey: Data?
  private let configuredSaveResult: PodcastCloudKeyringSave?
  private let fetchBarrierTarget: Int?
  // Fetches before the barrier target park here; the target fetch opens it for good, so a fetch
  // that parks late still passes. A parked fetch stays parked through task cancellation.
  private nonisolated let fetchBarrier = TestGate<Void>(
    label: "InMemoryPodcastCloudKeyringStore fetch barrier", ignoresCancellation: true)
  private var fetchCount = 0
  private var completedFetches = 0
  private var saveCount = 0
  private var completedFetchesBeforeFirstSave: Int?

  init(
    initial: Data? = nil, fetchBarrierTarget: Int? = nil, saveResult: PodcastCloudKeyringSave? = nil
  ) {
    self.storedKey = initial
    self.fetchBarrierTarget = fetchBarrierTarget
    self.configuredSaveResult = saveResult
    if fetchBarrierTarget != nil { fetchBarrier.hold() }
  }

  func fetchKeyring() async throws -> PodcastCloudKeyringFetch {
    fetchCount += 1
    let result: PodcastCloudKeyringFetch = storedKey.map { .present(recordNameKey: $0) } ?? .absent
    if let fetchBarrierTarget, fetchCount < fetchBarrierTarget {
      await fetchBarrier.pass()
    } else if let fetchBarrierTarget, fetchCount == fetchBarrierTarget {
      completedFetches = fetchCount
      fetchBarrier.release()
    }
    completedFetches = max(completedFetches, fetchCount)
    return result
  }

  func saveNewKeyring(_ key: PodcastCloudRecordNameKey) async throws -> PodcastCloudKeyringSave {
    saveCount += 1
    completedFetchesBeforeFirstSave = completedFetchesBeforeFirstSave ?? completedFetches
    if let configuredSaveResult { return configuredSaveResult }
    if let storedKey { return .serverRecordChanged(recordNameKey: storedKey) }
    storedKey = key.bytes
    return .saved
  }

  func snapshot() -> (
    storedKey: Data?, fetchCount: Int, saveCount: Int, completedFetchesBeforeFirstSave: Int
  ) {
    (
      storedKey, fetchCount, saveCount, completedFetchesBeforeFirstSave ?? completedFetches
    )
  }
}
