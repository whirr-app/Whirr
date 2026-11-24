import Foundation
import Testing

@testable import SyncEngine

@Suite struct ArtworkCacheServiceTests {
  @Test func artworkCacheBytesComesFromTheMaintenanceSeam() async {
    let maintenance = FakeArtworkCacheMaintenance(bytes: 214 * 1024 * 1024)
    let service = ArtworkCacheService(
      artwork: FakeArtworkCachePassCancelling(), maintenance: maintenance)

    #expect(await service.artworkCacheBytes() == 214 * 1024 * 1024)
  }

  @Test func clearingArtworkForwardsToTheMaintenanceSeam() async {
    let maintenance = FakeArtworkCacheMaintenance(bytes: 1024)
    let service = ArtworkCacheService(
      artwork: FakeArtworkCachePassCancelling(), maintenance: maintenance)

    await service.clearArtworkCache()

    #expect(await maintenance.clearCallCount == 1)
    #expect(await service.artworkCacheBytes() == 0)
  }

  /// An automatic top-up may be filling the same store on this foreground; the clear cancels it
  /// first so it cannot refill behind the clear.
  @Test func clearingCancelsTheArtworkPassBeforeEmptyingTheStore() async {
    let order = OrderRecorder()
    let artwork = FakeArtworkCachePassCancelling(order: order)
    let maintenance = FakeArtworkCacheMaintenance(bytes: 1024, order: order)
    let service = ArtworkCacheService(artwork: artwork, maintenance: maintenance)

    await service.clearArtworkCache()

    #expect(order.values == ["cancel", "clear"])
  }

  @Test func anUnwiredServiceReportsNoArtworkBytes() async {
    let service = ArtworkCacheService(artwork: FakeArtworkCachePassCancelling())

    await service.clearArtworkCache()

    #expect(await service.artworkCacheBytes() == 0)
  }
}

private final class OrderRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []

  func record(_ event: String) {
    lock.withLock { events.append(event) }
  }

  var values: [String] { lock.withLock { events } }
}

private actor FakeArtworkCachePassCancelling: ArtworkCachePassCancelling {
  private let order: OrderRecorder?
  private(set) var cancelCallCount = 0

  init(order: OrderRecorder? = nil) {
    self.order = order
  }

  func cancel() {
    cancelCallCount += 1
    order?.record("cancel")
  }
}

private actor FakeArtworkCacheMaintenance: ArtworkCacheMaintaining {
  private var bytes: Int64
  private let order: OrderRecorder?
  private(set) var clearCallCount = 0

  init(bytes: Int64, order: OrderRecorder? = nil) {
    self.bytes = bytes
    self.order = order
  }

  func cachedByteSize() async -> Int64 { bytes }

  func clear() async {
    clearCallCount += 1
    bytes = 0
    order?.record("clear")
  }
}
