import Observation
import Persistence

/// What a screen must offer for the shared funnel to drive it. `LibraryBrowseModel` and
/// `SearchModel` both conform, so one `BrowseFilterMenu` declares the filter's rows.
///
/// Read-only in `filters`, mutating only through named intents: the menu never assembles a
/// `BrowseFilters`, so a screen's persist-and-re-derive work (the Library re-subscribes an
/// observation; Search re-runs the query) cannot be bypassed.
@MainActor
public protocol BrowseFiltering: AnyObject, Observable {
  var filters: BrowseFilters { get }
  func isMediaCategorySelected(_ category: ItemMediaCategory) -> Bool
  func setMediaCategory(_ category: ItemMediaCategory, isOn: Bool)
  func updateDownloadedOnly(_ downloadedOnly: Bool)
  func updatePlayback(_ playback: PlaybackFilter)
  func clearFilters()
}

extension LibraryBrowseModel: BrowseFiltering {}
extension SearchModel: BrowseFiltering {}
