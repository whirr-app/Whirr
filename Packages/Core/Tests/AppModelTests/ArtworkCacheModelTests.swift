import Foundation
import TestSupport
import Testing

@testable import AppModel
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ArtworkCacheModelTests {
  @Test func theArtworkCacheSizeIsMeasuredOnDemand() async {
    let access = FakeArtworkCacheAccess(artworkCacheBytes: 214 * 1024 * 1024)
    let model = ArtworkCacheModel(access: access)

    #expect(model.artworkCacheBytes == nil)
    await model.refreshArtworkCacheSize()

    #expect(model.artworkCacheBytes == Int64(214 * 1024 * 1024))
  }

  @Test func cancelledArtworkCacheSizeRefreshDoesNotPublish() async {
    let access = FakeArtworkCacheAccess(artworkCacheBytes: 4096)
    let model = ArtworkCacheModel(access: access)
    await model.refreshArtworkCacheSize()

    access.setArtworkCacheBytes(8192)
    access.holdArtworkCacheSize()
    let refresh = Task { await model.refreshArtworkCacheSize() }
    await access.artworkCacheSizeGate.waitUntilParked()

    refresh.cancel()
    access.releaseArtworkCacheSize()
    await refresh.value

    #expect(model.artworkCacheBytes == 4096)
  }

  @Test func clearingArtworkIsConfirmedBeforeItRuns() async {
    let access = FakeArtworkCacheAccess(artworkCacheBytes: 4096)
    let model = ArtworkCacheModel(access: access)
    await model.refreshArtworkCacheSize()

    model.requestClearArtwork()
    #expect(model.isConfirmingClearArtwork)
    model.cancelClearArtwork()

    #expect(model.isConfirmingClearArtwork == false)
    #expect(access.clearCallCount == 0)
    #expect(model.artworkCacheBytes == Int64(4096))
  }

  @Test func aConfirmedClearEmptiesTheCacheAndRemeasures() async {
    let access = FakeArtworkCacheAccess(artworkCacheBytes: 4096)
    let model = ArtworkCacheModel(access: access)
    await model.refreshArtworkCacheSize()
    model.requestClearArtwork()

    model.confirmClearArtwork()

    #expect(
      await waitUntil { model.isClearingArtwork == false && model.artworkCacheBytes == Int64(0) })
    #expect(model.isConfirmingClearArtwork == false)
    #expect(access.clearCallCount == 1)
  }

  @Test func noOpBoundaryConstructsCleanlyAndIsInert() async {
    let model = ArtworkCacheModel(access: NoOpArtworkCacheAccess())

    await model.refreshArtworkCacheSize()
    model.requestClearArtwork()
    model.confirmClearArtwork()

    #expect(await waitUntil { model.isClearingArtwork == false })
    #expect(model.artworkCacheBytes == 0)
  }
}

private final class FakeArtworkCacheAccess: ArtworkCacheAccess, @unchecked Sendable {
  private let lock = NSLock()
  private var artworkCacheByteValue: Int64
  private var clearCalls = 0
  /// A held measurement runs to completion regardless of cancellation, as the real one does.
  let artworkCacheSizeGate = TestGate<Void>(
    label: "FakeArtworkCacheAccess artworkCacheBytes", ignoresCancellation: true)

  var clearCallCount: Int { lock.withLock { clearCalls } }

  init(artworkCacheBytes: Int64) {
    artworkCacheByteValue = artworkCacheBytes
  }

  func holdArtworkCacheSize() {
    artworkCacheSizeGate.hold()
  }

  func releaseArtworkCacheSize() {
    artworkCacheSizeGate.release()
  }

  func setArtworkCacheBytes(_ bytes: Int64) {
    lock.withLock { artworkCacheByteValue = bytes }
  }

  func artworkCacheBytes() async -> Int64 {
    await artworkCacheSizeGate.pass()
    return lock.withLock { artworkCacheByteValue }
  }

  func clearArtworkCache() async {
    lock.withLock {
      clearCalls += 1
      artworkCacheByteValue = 0
    }
  }
}
