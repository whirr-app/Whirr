import Foundation
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `ItemDetailExtrasModel` loads once, asynchronously, from `ItemDetailExtrasAccess`, never on
/// the UI event loop. Same `Task`-in-`init` shape as `ItemDetailModel`, for a one-shot fetch
/// instead of a `ValueObservation` stream.
@Suite struct ItemDetailExtrasModelTests {

  @MainActor
  @Test("starts loading, then reflects a successful fetch as loaded")
  func startsLoadingThenReflectsLoadedValue() async {
    let extras = ItemDetailExtras(seriesName: "The Series", narrator: "Nina Narrator", chapters: [])
    let access = FakeItemDetailExtrasAccess(result: extras)
    let model = ItemDetailExtrasModel(itemId: "item1", access: access)

    #expect(model.state == .loading)

    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded(extras))
  }

  @MainActor
  @Test("a nil fetch result (network failure or podcast-mapped-away item) is the unavailable state")
  func nilFetchResultIsUnavailableState() async {
    let access = FakeItemDetailExtrasAccess(result: nil)
    let model = ItemDetailExtrasModel(itemId: "item2", access: access)

    await waitUntil { model.state != .loading }

    #expect(model.state == .unavailable)
  }

  @MainActor
  @Test("requests extras for exactly the item id it was constructed with")
  func requestsExtrasForConstructedItemId() async {
    let access = FakeItemDetailExtrasAccess(result: nil)
    _ = ItemDetailExtrasModel(itemId: "item-under-test", access: access)

    await waitUntil { access.itemIDs.isEmpty == false }

    #expect(access.itemIDs == ["item-under-test"])
  }
}
