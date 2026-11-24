import Foundation
import Observation
import Persistence

/// Lazily-loaded Library root browse state for authors and series. Uses the same
/// `AuthorSeriesReading` boundary as an entity detail screen, so a row and its destination are
/// always drawn from the same server representation and source-library identity.
///
/// The server listing is half a row. The other half is the filtered library projection pushed in
/// from `LibraryBrowseModel` and joined here (`LibraryEntityGrouping`): book count, media kinds,
/// series and a series' borrowed cover, and the Library filter narrowing these modes as well as
/// Titles. Titles browses the same projection, so the lists cannot disagree on what matches.
@MainActor
@Observable
public final class AuthorSeriesBrowseModel {
  public enum State: Sendable, Equatable {
    case loading
    case empty
    case loaded
    case error
    /// Entities exist, but the active filter matches none of their items. Distinct from `.empty`
    /// (as with `LibraryBrowseModel.State.filteredEmpty`) so a reader who filtered to Downloaded
    /// is not told they have no authors.
    case filteredEmpty
  }

  public private(set) var state: State = .loading
  public private(set) var entities: [AuthorSeriesEntity] = []
  /// The rows the screen renders: `entities` joined to the filtered library.
  public private(set) var groups: [LibraryEntityGroup] = []
  public private(set) var hasMore = false

  public let kind: SearchResultKind
  /// The active Library filter, held so a row's count can say whether it is filtered and so the
  /// empty-entity rule knows whether a filter caused the emptiness. Owned by `LibraryBrowseModel`
  /// and adopted through `updateFilters`.
  public private(set) var filters: BrowseFilters

  private static let pageSize = 50
  private let reading: any AuthorSeriesReading
  private var items: [ItemSummary] = []
  @ObservationIgnored private var initialLoadTask: Task<Void, Never>?
  @ObservationIgnored private var loadMoreTask: Task<AuthorSeriesBrowsePage?, Never>?
  @ObservationIgnored private var entitiesTask: Task<Void, Never>?
  private var hasCompletedInitialLoad = false

  public init(
    kind: SearchResultKind,
    reading: any AuthorSeriesReading,
    filters: BrowseFilters = .unfiltered
  ) {
    self.kind = kind
    self.reading = reading
    self.filters = filters
    initialLoadTask = Task { [weak self] in await self?.loadInitial() }
    subscribeToEntities()
  }

  deinit {
    initialLoadTask?.cancel()
    loadMoreTask?.cancel()
    entitiesTask?.cancel()
  }

  /// Pull-to-refresh. Whatever is on screen stays until the new first page lands. The refresh
  /// control is already the indicator, so dropping to `.loading` would add a second full-screen
  /// spinner and wipe the rows. `LibraryBrowseModel` holds its rows through a sync run likewise.
  public func refresh() async {
    initialLoadTask?.cancel()
    loadMoreTask?.cancel()
    loadMoreTask = nil
    await loadInitial(forceRefresh: true)
  }

  /// Adopts a new Library filter and re-derives the rows from the shared item projection. A no-op
  /// for an unchanged value.
  public func updateFilters(_ filters: BrowseFilters) {
    guard filters != self.filters else { return }
    self.filters = filters
    regroup()
  }

  /// The filtered item projection is owned by `LibraryBrowseModel` and pushed in, so the three
  /// Library modes agree on the filter and don't each run the whole-library query.
  public func updateItems(_ items: [ItemSummary]) {
    guard items != self.items else { return }
    self.items = items
    regroup()
  }

  public func loadMore() async {
    guard hasMore, loadMoreTask == nil else { return }

    let offset = entities.count
    let task = Task { [reading, kind] () -> AuthorSeriesBrowsePage? in
      try? await reading.entities(kind: kind, libraryID: nil, limit: Self.pageSize, offset: offset)
    }
    loadMoreTask = task

    let page = await task.value
    loadMoreTask = nil
    guard let page else { return }
    entities.append(contentsOf: page.entities)
    entities.sort(by: Self.entityComesBefore)
    hasMore = page.hasMore
    regroup()
  }

  private func loadInitial(forceRefresh: Bool = false) async {
    let page: AuthorSeriesBrowsePage
    do {
      if forceRefresh {
        page = try await reading.refreshEntities(
          kind: kind, libraryID: nil, limit: Self.pageSize, offset: 0)
      } else {
        page = try await reading.entities(
          kind: kind, libraryID: nil, limit: Self.pageSize, offset: 0)
      }
    } catch {
      guard Task.isCancelled == false else { return }
      // A first load that fails has nothing to show and must say so. A failed refresh already has
      // rows on screen, and replacing them with an error loses more than it reports, so the error
      // state is only entered from an empty list.
      guard entities.isEmpty else { return }
      hasMore = false
      groups = []
      state = .error
      return
    }
    guard Task.isCancelled == false else { return }
    entities = page.entities.sorted(by: Self.entityComesBefore)
    hasCompletedInitialLoad = true
    hasMore = page.hasMore
    // A successful fetch retires the error, even an empty one. `regroup` refuses to overwrite
    // `.error`, so clear it here or a recovered-but-empty library keeps reporting a failure.
    if state == .error { state = .empty }
    regroup()
  }

  private func subscribeToEntities() {
    let reading = self.reading
    let kind = self.kind
    entitiesTask = Task { [weak self] in
      let stream = await reading.observeEntities(kind: kind, libraryID: nil)
      for await entities in stream {
        guard let self, Task.isCancelled == false else { return }
        // The observation's initial empty value means "no durable snapshot yet" until the first
        // read finishes. Do not flash an empty screen while that cold fetch is in flight.
        guard self.hasCompletedInitialLoad || entities.isEmpty == false else { continue }
        self.entities = entities.sorted(by: Self.entityComesBefore)
        self.hasMore = false
        self.regroup()
      }
    }
  }

  /// Re-derives the rows from whichever input just changed. State follows the rows, not the
  /// entity fetch alone: a full entity list filtered down to nothing is a filtered-empty screen.
  private func regroup() {
    groups = LibraryEntityGrouping.groups(
      kind: kind, entities: entities, items: items, filters: filters)
    guard groups.isEmpty else {
      state = .loaded
      return
    }
    if entities.isEmpty {
      // Stays `.error` if the entity fetch failed, so a later item emission can't relabel it as
      // an empty library.
      if state != .error { state = .empty }
    } else {
      state = filters.isActive ? .filteredEmpty : .empty
    }
  }

  private static func entityComesBefore(
    _ lhs: AuthorSeriesEntity, _ rhs: AuthorSeriesEntity
  ) -> Bool {
    let comparison = lhs.name.localizedStandardCompare(rhs.name)
    if comparison == .orderedSame { return lhs.entityID < rhs.entityID }
    return comparison == .orderedAscending
  }
}
