import Foundation
import Observation
import Persistence
import SyncEngine

/// The Library's Collections mode: stored collections and playlists in two sections, read from the
/// local snapshot so it opens offline. Fetching is injected as `fill`, bound by the App to
/// `LibraryCollectionService.refreshAll(force:)`: opening fills a cold cache without refetching a
/// warm one, and pull to refresh forces a pass.
///
/// A list with no member the local catalogue holds is not shown. The Library filter applies its
/// categories only (a list shows when a held member is in a selected category); `downloadedOnly`
/// and `playback` are inert here.
@MainActor
@Observable
public final class LibraryCollectionsBrowseModel {
  public enum State: Sendable, Equatable {
    case loading
    case empty
    /// Lists exist, but none holds a member in the selected categories.
    case filteredEmpty
    case loaded
  }

  public struct Row: Sendable, Equatable, Identifiable {
    public let listing: LibraryCollectionListing
    /// True when the shown lists come from more than one library, so the name says which.
    public let showsLibraryName: Bool
    /// Kept downloaded on this device.
    public let isPinned: Bool

    public var id: LibraryCollectionKey { listing.key }

    public init(listing: LibraryCollectionListing, showsLibraryName: Bool, isPinned: Bool = false) {
      self.listing = listing
      self.showsLibraryName = showsLibraryName
      self.isPinned = isPinned
    }
  }

  public private(set) var state: State = .loading
  public private(set) var collections: [Row] = []
  public private(set) var playlists: [Row] = []
  public private(set) var filters: BrowseFilters

  private let reading: any LibraryCollectionReading
  private let fill: @Sendable (_ force: Bool) async -> Void
  private var listings: [LibraryCollectionListing] = []
  private var pinnedKeys: Set<LibraryCollectionKey> = []
  private var hasReceivedListings = false
  private var hasFinishedInitialFill = false
  @ObservationIgnored private var listingsTask: Task<Void, Never>?
  @ObservationIgnored private var fillTask: Task<Void, Never>?
  @ObservationIgnored private var pinsTask: Task<Void, Never>?

  public init(
    reading: any LibraryCollectionReading,
    fill: @escaping @Sendable (_ force: Bool) async -> Void,
    pins: any PinnedListDownloadControlling = NoOpPinnedListDownloads(),
    filters: BrowseFilters = .unfiltered
  ) {
    self.reading = reading
    self.fill = fill
    self.filters = filters
    listingsTask = Task { [weak self, reading] in
      for await listings in reading.observeListings() {
        guard let self, Task.isCancelled == false else { return }
        self.listings = listings
        self.hasReceivedListings = true
        self.rederive()
      }
    }
    pinsTask = Task { [weak self, pins] in
      for await keys in pins.observePinnedKeys() {
        guard let self, Task.isCancelled == false else { return }
        self.pinnedKeys = keys
        self.rederive()
      }
    }
    fillTask = Task { [weak self, fill] in
      await fill(false)
      guard let self, Task.isCancelled == false else { return }
      self.hasFinishedInitialFill = true
      self.rederive()
    }
  }

  deinit {
    listingsTask?.cancel()
    fillTask?.cancel()
    pinsTask?.cancel()
  }

  /// Pull to refresh: a forced pass. Rows stay on screen; the stored snapshot replaces them only
  /// after a complete pass, and a failed pass keeps them.
  public func refresh() async {
    await fill(true)
  }

  public func updateFilters(_ filters: BrowseFilters) {
    guard filters != self.filters else { return }
    self.filters = filters
    rederive()
  }

  private func rederive() {
    let held = listings.filter { $0.heldMemberCount > 0 }
    let visible = held.filter { listing in
      guard let categories = filters.categories else { return true }
      return listing.heldCategories.isDisjoint(with: categories) == false
    }
    let showsLibraryName = Set(visible.map(\.key.serverLibraryID)).count > 1
    let rows = visible.map {
      Row(listing: $0, showsLibraryName: showsLibraryName, isPinned: pinnedKeys.contains($0.key))
    }
    collections = rows.filter { $0.listing.key.kind == .collection }
    playlists = rows.filter { $0.listing.key.kind == .playlist }

    if rows.isEmpty == false {
      state = .loaded
    } else if hasReceivedListings == false || (listings.isEmpty && hasFinishedInitialFill == false) {
      // A cold cache reads empty until the first fill lands; do not call that an empty library.
      state = .loading
    } else if held.isEmpty == false {
      state = .filteredEmpty
    } else {
      state = .empty
    }
  }
}
