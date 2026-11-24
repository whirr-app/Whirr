import AppModel
import Foundation
import SyncEngine

public final class FakeItemDetailExtrasAccess: ItemDetailExtrasAccess, @unchecked Sendable {
  private let resultBox: Locked<ItemDetailExtras?>
  private let itemIDsBox = Locked<[String]>([])

  public var itemIDs: [String] { itemIDsBox.value }
  public var callCount: Int { itemIDsBox.value.count }

  public init(result: ItemDetailExtras? = nil) {
    resultBox = Locked(result)
  }

  public func stubResult(_ result: ItemDetailExtras?) {
    resultBox.value = result
  }

  private let resultProviderBox = Locked<(@Sendable (String) -> ItemDetailExtras?)?>(nil)

  /// Answers each request from `provide`, called with the requested item id, instead of the one
  /// stubbed result: for a test whose items need different extras. Replaces `stubResult` while set.
  public func stubResults(_ provide: @escaping @Sendable (String) -> ItemDetailExtras?) {
    resultProviderBox.value = provide
  }

  /// Hold it (`hold()`) to park every request in flight until the test releases it with the
  /// extras to return. Open by default, so a request returns the stubbed result at once. Each
  /// request is recorded before it parks.
  public let gate = TestGate<ItemDetailExtras?>(
    label: "FakeItemDetailExtrasAccess.itemDetailExtras")

  public func itemDetailExtras(itemId: String) async -> ItemDetailExtras? {
    itemIDsBox.withValue { $0.append(itemId) }
    let resultBox = resultBox
    let resultProviderBox = resultProviderBox
    return await gate.pass {
      if let provide = resultProviderBox.value { return provide(itemId) }
      return resultBox.value
    }
  }
}
