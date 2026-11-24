import Foundation
import Observation
import Persistence

/// A single navigable author or series. Resolves the entity's display name and a bounded page of
/// its items through `any AuthorSeriesReading`. Loaded once in a `Task` spawned from `init`, never
/// awaited inline. `AuthorSeriesReading` is a live, paginated server fetch, not a local
/// projection, so the boundary is one-shot `async throws`, not a `ValueObservation` stream. A
/// Library-origin route can seed the entity synchronously for a stable first-frame title.
@MainActor
@Observable
public final class AuthorSeriesModel {
  /// Which entity this screen shows, with the entity and source-library identities
  /// `AuthorSeriesReading` needs. The resolved display name lives on `entity`, immediately when a
  /// destination seed is available.
  public enum Target: Sendable, Equatable {
    case author(id: String, libraryID: String? = nil)
    case series(id: String, libraryID: String? = nil)
    case authorName(name: String)
    case seriesName(name: String)
    case narrator(name: String)

    var entityKind: SearchResultKind? {
      switch self {
      case .author, .authorName: .author
      case .series, .seriesName: .series
      case .narrator: nil
      }
    }

    var entityID: String? {
      switch self {
      case .author(let id, _), .series(let id, _): id
      case .authorName, .seriesName, .narrator: nil
      }
    }

    var libraryID: String? {
      switch self {
      case .author(_, let libraryID), .series(_, let libraryID): libraryID
      case .authorName, .seriesName, .narrator: nil
      }
    }

    var requestedName: String? {
      switch self {
      case .authorName(let name), .seriesName(let name), .narrator(let name): name
      case .author, .series: nil
      }
    }

    public var fallbackTitle: String {
      requestedName ?? (isSeriesDestination ? "Series" : isNarratorDestination ? "Narrator" : "Author")
    }

    public var isSeriesDestination: Bool {
      switch self {
      case .series, .seriesName: true
      case .author, .authorName, .narrator: false
      }
    }

    public var isNarratorDestination: Bool {
      if case .narrator = self { return true }
      return false
    }
  }

  public enum State: Sendable, Equatable {
    case loading
    case empty
    /// An entity that has items, none of which survive the filter this screen was reached under.
    /// Distinct from `empty`: telling a reader who narrowed to Downloaded that an author has
    /// nothing at all would be false.
    case filteredEmpty
    case loaded
  }

  public private(set) var state: State = .loading
  public private(set) var entity: AuthorSeriesEntity?
  /// The fetched page(s), narrowed, grouped, and ordered for the author card projection. A
  /// series destination contains one section so both destinations consume the same source.
  public private(set) var sections: [AuthorSeriesSection] = []
  /// The series destination's ordered rows, derived from `sections` so it cannot drift from the
  /// author projection's visible rows.
  public var rows: [SearchResultRow] { sections.flatMap(\.rows) }
  public private(set) var hasMore = false
  private var playbackProgresses: [String: ItemPlaybackProgress] = [:]

  public let target: Target
  /// The browse filter this screen was reached under. An Authors/Series row states a filtered
  /// count ("17 books" while narrowed to eBooks), so its destination must list those 17.
  ///
  /// The server cannot: `/api/libraries/{id}/items` takes one `filter` parameter, already spent on
  /// `authors.<id>`. So narrowing is done here, against the same filtered local projection the
  /// row's count came from.
  public let filters: BrowseFilters

  private static let pageSize = 50
  private let reading: any AuthorSeriesReading
  private let library: (any LibraryReading)?
  private struct IdentityPageState: Sendable {
    var nextOffset: Int
    var hasMore: Bool
  }

  private struct IdentityPageRequest: Sendable {
    let identity: AuthorSeriesEntity.Identity
    let offset: Int
  }

  private struct IdentityPageResult: Sendable {
    let identity: AuthorSeriesEntity.Identity
    let page: SearchPage?
  }

  private typealias PageResults = [AuthorSeriesEntity.Identity: IdentityPageResult]

  /// The resolved identities remain in the order their entity supplied. Before resolution, the
  /// route's own identity is the only safe listing target; an empty library id means the account
  /// default at the reading boundary.
  private var resolvedIdentities: [AuthorSeriesEntity.Identity] = []
  private var pageStates: [AuthorSeriesEntity.Identity: IdentityPageState] = [:]
  /// What each server identity returned, before the filter. Keeping pages separate preserves both
  /// cursor ownership and deterministic identity ordering when requests complete concurrently.
  private var rowsByIdentity: [AuthorSeriesEntity.Identity: [SearchResultRow]] = [:]
  /// The server item ids the active filter matches. Nil until the first snapshot lands, so the
  /// screen stays in `.loading` rather than showing the unfiltered page and then dropping rows.
  private var matchedItemIDs: Set<String>?
  /// Rows from the durable Library projection. They remain separate from server pages so a
  /// bounded first page can never shrink a larger cached shelf and never claims a remote cursor.
  private var localRows: [SearchResultRow] = []
  private var localItems: [ItemSummary] = []
  private var hasFetched = false

  private var isFiltering: Bool { filters.isActive && library != nil }

  private var identityOrder: [AuthorSeriesEntity.Identity] {
    guard resolvedIdentities.isEmpty == false else {
      guard let entityID = target.entityID else { return [] }
      return [AuthorSeriesEntity.Identity(entityID: entityID, libraryID: target.libraryID ?? "")]
    }
    return resolvedIdentities
  }

  private static func pages(
    reading: any AuthorSeriesReading,
    target: Target,
    requests: [IdentityPageRequest]
  ) async -> PageResults {
    await withTaskGroup(of: IdentityPageResult.self) { group in
      for request in requests {
        group.addTask {
          let page: SearchPage?
          if case .narrator(let name) = target {
            page = try? await reading.items(
              narratorName: name,
              libraryID: request.identity.libraryID,
              limit: pageSize,
              offset: request.offset)
          } else if let kind = target.entityKind {
            page = try? await reading.items(
              kind: kind,
              entityID: request.identity.entityID,
              libraryID: request.identity.libraryID.isEmpty ? nil : request.identity.libraryID,
              limit: pageSize,
              offset: request.offset)
          } else {
            page = nil
          }
          return IdentityPageResult(identity: request.identity, page: page)
        }
      }

      var results: PageResults = [:]
      for await result in group {
        results[result.identity] = result
      }
      return results
    }
  }

  @ObservationIgnored private var initialLoadTask: Task<Void, Never>?
  /// Non-nil while a `loadMore` fetch is in flight. The re-entrancy guard `loadMore` checks before
  /// issuing a second request for the same next page.
  @ObservationIgnored private var loadMoreTask: Task<PageResults, Never>?
  @ObservationIgnored private var matchesTask: Task<Void, Never>?
  @ObservationIgnored private var playbackProgressTask: Task<Void, Never>?
  @ObservationIgnored private var observedPlaybackProgressItemIDs: Set<String> = []

  public init(
    target: Target,
    reading: any AuthorSeriesReading,
    library: (any LibraryReading)? = nil,
    filters: BrowseFilters = .unfiltered,
    seed: AuthorSeriesDestinationSeed? = nil
  ) {
    self.target = target
    self.reading = reading
    self.library = library
    self.filters = filters
    entity = seed?.entity
    resolvedIdentities = seed?.entity.identities ?? []
    if let seed {
      localItems = seed.items
      localRows = Self.rows(from: seed.items, libraryID: seed.entity.libraryID)
      sections = projection(for: localRows)
      state = localRows.isEmpty ? .loading : .loaded
    }
    initialLoadTask = Task { [weak self] in await self?.loadInitial() }
    subscribeToMatches()
    refreshPlaybackProgressSubscription()
  }

  /// Source-compatible convenience for callers that only know the entity name. New navigation
  /// paths should pass `AuthorSeriesDestinationSeed` so cached items can paint too.
  public convenience init(
    target: Target,
    reading: any AuthorSeriesReading,
    library: (any LibraryReading)? = nil,
    filters: BrowseFilters = .unfiltered,
    seed: AuthorSeriesEntity
  ) {
    self.init(
      target: target, reading: reading, library: library, filters: filters,
      seed: AuthorSeriesDestinationSeed(entity: seed))
  }

  deinit {
    initialLoadTask?.cancel()
    loadMoreTask?.cancel()
    matchesTask?.cancel()
    playbackProgressTask?.cancel()
  }

  public func playbackProgress(for itemID: String) -> ItemPlaybackProgress? {
    playbackProgresses[itemID]
  }

  /// Fetches the next page after the rows already shown. A no-op once exhausted
  /// (`hasMore == false`) or while a previous call's fetch is in flight. The guard is set
  /// synchronously before the first suspension point, so two concurrent callers can never both
  /// issue a request for the same window.
  public func loadMore() async {
    guard hasMore, loadMoreTask == nil else { return }

    let requests = identityOrder.compactMap { identity -> IdentityPageRequest? in
      guard let state = pageStates[identity], state.hasMore else { return nil }
      return IdentityPageRequest(identity: identity, offset: state.nextOffset)
    }
    guard requests.isEmpty == false else {
      hasMore = false
      return
    }

    let task = Task { [reading, target, requests] in
      await Self.pages(reading: reading, target: target, requests: requests)
    }
    loadMoreTask = task

    let results = await task.value
    loadMoreTask = nil
    apply(results, replacing: false)
    narrow()
  }

  private func loadInitial() async {
    switch target {
    case .author(let id, let libraryID):
      await loadIdentityInitial(kind: .author, entityID: id, libraryID: libraryID)
    case .series(let id, let libraryID):
      await loadIdentityInitial(kind: .series, entityID: id, libraryID: libraryID)
    case .authorName(let name):
      await loadNamedEntity(kind: .author, name: name)
    case .seriesName(let name):
      await loadNamedEntity(kind: .series, name: name)
    case .narrator(let name):
      await loadNarrator(name: name)
    }
  }

  private func loadNamedEntity(kind: SearchResultKind, name: String) async {
    let fetchedEntity = try? await reading.entity(kind: kind, named: name)
    guard Task.isCancelled == false else { return }
    guard let fetchedEntity else {
      hasFetched = true
      narrow()
      return
    }
    entity = fetchedEntity
    resolvedIdentities = fetchedEntity.identities
    rebuildLocalRows(from: localItems)
    await loadEveryResolvedIdentity()
  }

  private func loadNarrator(name: String) async {
    let libraryIDs = (try? await reading.narratorLibraryIDs()) ?? []
    guard Task.isCancelled == false else { return }
    resolvedIdentities = libraryIDs.map {
      AuthorSeriesEntity.Identity(entityID: name, libraryID: $0)
    }
    rebuildLocalRows(from: localItems)
    await loadEveryResolvedIdentity()
  }

  private func loadEveryResolvedIdentity() async {
    let identities = identityOrder
    preparePageState(for: identities)
    let requests = identities.map { IdentityPageRequest(identity: $0, offset: 0) }
    let results = await Self.pages(reading: reading, target: target, requests: requests)
    guard Task.isCancelled == false else { return }
    apply(results, replacing: true)
    hasFetched = true
    narrow()
  }

  private func loadIdentityInitial(
    kind: SearchResultKind, entityID: String, libraryID: String?
  ) async {
    let routeIdentity = AuthorSeriesEntity.Identity(
      entityID: entityID, libraryID: libraryID ?? "")
    async let fetchedEntityTask = try? reading.entity(
      kind: kind, entityID: entityID, libraryID: libraryID)
    async let routePageTask = Self.pages(
      reading: reading, target: target,
      requests: [IdentityPageRequest(identity: routeIdentity, offset: 0)])

    let fetchedEntity = await fetchedEntityTask
    guard Task.isCancelled == false else { return }
    // The resolved entity carries an id per library that knows it; the route carries only the one
    // that was tapped. Listing by the route's id alone shows a reader half their shelf whenever
    // their ebooks and audiobooks live in different libraries.
    if let fetchedEntity {
      resolvedIdentities = fetchedEntity.identities
      // The navigation title depends only on the entity. Publish it as soon as filter-data
      // resolution completes rather than holding it behind the independent item-page requests.
      entity = fetchedEntity
      rebuildLocalRows(from: localItems)
    }
    let identities = identityOrder
    preparePageState(for: identities)
    var routeResults = await routePageTask
    if routeIdentity.libraryID.isEmpty,
      let resolvedRouteIdentity = identities.first(where: { $0.entityID == routeIdentity.entityID }),
      let result = routeResults.removeValue(forKey: routeIdentity)
    {
      routeResults[resolvedRouteIdentity] = IdentityPageResult(
        identity: resolvedRouteIdentity, page: result.page)
    }
    apply(routeResults, replacing: true)
    let fetchedRouteIdentity = identities.first(where: { $0.entityID == routeIdentity.entityID })
    let remaining = identities.filter { $0 != fetchedRouteIdentity }
      .map { IdentityPageRequest(identity: $0, offset: 0) }
    let results = await Self.pages(reading: reading, target: target, requests: remaining)
    guard Task.isCancelled == false else { return }

    apply(results, replacing: true)
    hasFetched = true
    narrow()
  }

  private func preparePageState(for identities: [AuthorSeriesEntity.Identity]) {
    pageStates = Dictionary(
      uniqueKeysWithValues: identities.map {
        ($0, IdentityPageState(nextOffset: 0, hasMore: true))
      })
    rowsByIdentity = Dictionary(uniqueKeysWithValues: identities.map { ($0, []) })
  }

  private func apply(
    _ results: PageResults, replacing: Bool
  ) {
    for identity in identityOrder {
      guard let result = results[identity] else { continue }
      guard var state = pageStates[identity] else { continue }
      guard let page = result.page else {
        // A failed continuation leaves the cursor where it was so the next trigger retries the
        // same page. On an initial failure cached rows remain visible and the identity is marked
        // exhausted only for this model instance.
        if replacing {
          state.hasMore = false
          pageStates[identity] = state
        }
        continue
      }

      if replacing {
        rowsByIdentity[identity] = page.rows
      } else {
        rowsByIdentity[identity, default: []].append(contentsOf: page.rows)
      }
      if page.hasMore { state.nextOffset += Self.pageSize }
      state.hasMore = page.hasMore
      pageStates[identity] = state
    }
    hasMore = pageStates.values.contains { $0.hasMore }
  }

  /// One live observation of the same filtered projection the Library browse rows are joined to.
  /// Subscribed synchronously rather than inside the task so the observation starts now, not
  /// whenever the scheduler runs the task. Unfiltered screens (every entity reached from Search,
  /// and any Library row tapped with the filter clear) never subscribe.
  private func subscribeToMatches() {
    guard let library else { return }
    let stream = library.observeBrowseList(filters: filters)
    matchesTask = Task { [weak self] in
      for await snapshot in stream {
        guard let self, Task.isCancelled == false else { return }
        self.matchedItemIDs = Set(snapshot.items.map(\.serverItemId))
        self.localItems = snapshot.items
        self.rebuildLocalRows(from: snapshot.items)
        self.narrow()
      }
    }
  }

  /// Re-derives the visible rows from whichever of the two inputs just changed, and moves the state
  /// only once both have arrived.
  private func narrow() {
    // Identity order determines which copy survives, so completion order cannot change the
    // retained row when two libraries report the same server item.
    var seenItemIDs = Set<String>()
    var fetchedRows: [SearchResultRow] = []
    for row in identityOrder.flatMap({ rowsByIdentity[$0] ?? [] })
    where seenItemIDs.insert(row.entityID).inserted {
      fetchedRows.append(row)
    }
    let filteredRemoteRows: [SearchResultRow]
    if isFiltering {
      guard let matchedItemIDs else { return }
      filteredRemoteRows = fetchedRows.filter { matchedItemIDs.contains($0.entityID) }
    } else {
      filteredRemoteRows = fetchedRows
    }
    // Live rows win for duplicates because they carry the freshest minified server metadata.
    // Narrator is expanded-only, though, so enrich those rows from the durable projection rather
    // than blanking a fact already fetched for this exact server item. Cached-only rows follow,
    // so a 50-row first page cannot collapse an 80-book local author.
    let cachedByItemID = Dictionary(
      localRows.map { ($0.entityID, $0) }, uniquingKeysWith: { first, _ in first })
    var visibleRows = filteredRemoteRows.map { row in
      Self.enrich(row, with: cachedByItemID[row.entityID])
    }
    var visibleIDs = Set(filteredRemoteRows.map(\.entityID))
    visibleRows.append(contentsOf: localRows.filter { visibleIDs.insert($0.entityID).inserted })
    sections = projection(for: visibleRows)
    refreshPlaybackProgressSubscription()
    guard hasFetched || localRows.isEmpty == false else { return }
    // A page that filtered down to nothing while more pages remain is not an empty entity: the
    // list's own load-more row is about to ask for the next page, and calling that empty would
    // replace it with a dead end.
    guard rows.isEmpty && hasMore == false else {
      state = .loaded
      return
    }
    // `isFiltering`, not `filters.isActive`: without a `library` to narrow against nothing was
    // filtered, so an empty result really is an empty entity.
    state = isFiltering ? .filteredEmpty : .empty
  }

  private func rebuildLocalRows(from items: [ItemSummary]) {
    if case .narrator(let name) = target {
      let normalizedName = AuthorSeriesEntity.normalizedName(name)
      let matches = items.filter { item in
        LibraryEntityGrouping.authorNames(from: item.narratorName).contains {
          AuthorSeriesEntity.normalizedName($0) == normalizedName
        }
      }
      localRows = Self.rows(from: matches, libraryID: "")
      return
    }
    guard let entity else { return }
    guard let kind = target.entityKind else { return }
    let group = LibraryEntityGrouping.groups(
      kind: kind, entities: [entity], items: items, filters: filters
    ).first
    localRows = Self.rows(from: group?.items ?? [], libraryID: entity.libraryID)
  }

  /// Positions are observed separately from the coarse, account-wide finished projection: ticks
  /// may update this map several times a minute, but only while this screen is alive and only for
  /// the rows it draws. Pagination restarts the single observation with the expanded id set; there
  /// is never one task per row.
  private func refreshPlaybackProgressSubscription() {
    guard let library else { return }
    let itemIDs = Set(rows.map(\.entityID))
    guard itemIDs != observedPlaybackProgressItemIDs else { return }

    playbackProgressTask?.cancel()
    playbackProgressTask = nil
    observedPlaybackProgressItemIDs = itemIDs
    playbackProgresses = playbackProgresses.filter { itemIDs.contains($0.key) }
    guard itemIDs.isEmpty == false else { return }

    let stream = library.observeItemPlaybackProgress(itemIDs: itemIDs)
    playbackProgressTask = Task { [weak self] in
      for await progress in stream {
        guard let self, Task.isCancelled == false else { return }
        guard self.observedPlaybackProgressItemIDs == itemIDs else { return }
        self.playbackProgresses = progress.filter { itemIDs.contains($0.key) }
      }
    }
  }

  private static func rows(from items: [ItemSummary], libraryID: String) -> [SearchResultRow] {
    items.map { item in
      SearchResultRow(
        kind: item.category == .podcast ? .podcast : .book,
        entityID: item.serverItemId,
        title: item.title,
        subtitle: item.author,
        mediaCategory: item.category,
        hasReadableEbook: item.hasReadableEbook,
        seriesName: item.seriesName,
        durationSeconds: item.durationSeconds,
        narratorName: item.narratorName,
        libraryID: libraryID,
        serverUpdatedAt: item.serverUpdatedAt)
    }
  }

  /// Combines two projections of one server item without letting older cache content replace the
  /// fresh title/author/category/series fields. Only facts absent from the minified route are
  /// filled: expanded narrator, plus duration as a defensive fallback for an older server that
  /// omits it. Empty strings and non-positive/non-finite durations are absence, not display data.
  private static func enrich(
    _ row: SearchResultRow, with cached: SearchResultRow?
  ) -> SearchResultRow {
    guard let cached else { return row }
    return SearchResultRow(
      kind: row.kind,
      entityID: row.entityID,
      parentItemID: row.parentItemID,
      title: row.title,
      subtitle: row.subtitle,
      matchReason: row.matchReason,
      mediaCategory: row.mediaCategory,
      hasReadableEbook: row.hasReadableEbook,
      seriesName: row.seriesName,
      durationSeconds: usableDuration(row.durationSeconds) ?? usableDuration(cached.durationSeconds),
      narratorName: nonempty(row.narratorName) ?? nonempty(cached.narratorName),
      libraryID: row.libraryID,
      serverUpdatedAt: row.serverUpdatedAt ?? cached.serverUpdatedAt)
  }

  private static func usableDuration(_ seconds: Double?) -> Double? {
    guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
    return seconds
  }

  private static func nonempty(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false
    else { return nil }
    return text
  }

  /// The section projection is the final step after the model has merged identities, removed
  /// duplicate server items, and applied the inherited filter. A series route wraps its ordered
  /// rows in one card because its navigation title already supplies the series name.
  private func projection(for rows: [SearchResultRow]) -> [AuthorSeriesSection] {
    let identityOrder = identityOrder.map(\.libraryID)
    guard target.isSeriesDestination else {
      return AuthorSeriesSection.sections(from: rows, identityOrder: identityOrder)
    }

    let orderedRows = AuthorSeriesSection.orderedRows(rows, identityOrder: identityOrder)
    guard orderedRows.isEmpty == false else { return [] }
    guard let descriptor = seriesDescriptor(for: orderedRows) else {
      return [
        AuthorSeriesSection(
          id: AuthorSeriesSection.standaloneID, kind: .standalone, rows: orderedRows)
      ]
    }
    return [
      AuthorSeriesSection(
        id: descriptor.key,
        kind: .series(key: descriptor.key, name: descriptor.name),
        rows: orderedRows)
    ]
  }

  private func seriesDescriptor(
    for rows: [SearchResultRow]
  ) -> LibraryEntityGrouping.SeriesDescriptor? {
    if let entityName = entity?.name,
      let descriptor = LibraryEntityGrouping.seriesDescriptor(from: entityName)
    {
      return descriptor
    }
    return rows.lazy.compactMap { row in
      LibraryEntityGrouping.seriesDescriptor(from: row.seriesName)
    }.first
  }
}
