import Foundation
import Persistence
import SyncEngine

/// What the Library's Collections mode and a collection's screen need from the composition: the
/// local read, the queue Play inserts into, and the fetch the list model injects as `fill`. The
/// App binds `fill` to `LibraryCollectionService.refreshAll(force:)`. Whirr never edits these
/// lists: they are read-only here and edited in Audiobookshelf itself.
public struct LibraryCollectionsAccess: Sendable {
  public let reading: any LibraryCollectionReading
  public let queue: any ListeningQueueStoring
  public let fill: @Sendable (_ force: Bool) async -> Void
  public let pins: any PinnedListDownloadControlling

  public init(
    reading: any LibraryCollectionReading,
    queue: any ListeningQueueStoring,
    fill: @escaping @Sendable (_ force: Bool) async -> Void,
    pins: any PinnedListDownloadControlling = NoOpPinnedListDownloads()
  ) {
    self.reading = reading
    self.queue = queue
    self.fill = fill
    self.pins = pins
  }

  /// For the setup and removal graphs and lightweight test graphs: nothing stored, nothing fetched.
  public static let unavailable = LibraryCollectionsAccess(
    reading: NoOpLibraryCollectionReading(), queue: NoOpListeningQueueStore(), fill: { _ in })
}
