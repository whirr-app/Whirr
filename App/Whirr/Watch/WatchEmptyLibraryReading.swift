import AppModel
import Foundation
import Persistence
import WatchProtocol

/// Lets the publisher's lightweight unit-test initializer work without inventing browse rows when
/// no runtime dependencies were supplied.
struct WatchEmptyLibraryReading: LibraryReading, Sendable {
  var itemCount: Int { 0 }
  func observeBrowseList(libraryId: String) -> AsyncStream<[ItemSummary]> { AsyncStream { $0.finish() } }
  func observeBrowseList(category: ItemMediaCategory?) -> AsyncStream<[ItemSummary]> { AsyncStream { $0.finish() } }
  func observeBrowseList(filters: BrowseFilters) -> AsyncStream<LibraryBrowseSnapshot> { AsyncStream { $0.finish() } }
  func observeSyncStatus(libraryId: String) -> AsyncStream<LibrarySyncStatus> { AsyncStream { $0.finish() } }
  func observeAggregateSyncStatus() -> AsyncStream<LibrarySyncStatus> { AsyncStream { $0.finish() } }
  func observeItemDetail(itemId: String) -> AsyncStream<ItemSummary?> { AsyncStream { $0.finish() } }
  func observeItems(ids: [String]) -> AsyncStream<[ItemSummary]> { AsyncStream { $0.finish() } }
  func observeItemPlaybackStatuses() -> AsyncStream<[String: ItemPlaybackStatus]> { AsyncStream { $0.finish() } }
}
