import AppModel

/// What one car list shows, as a value. Templates are rebuilt only when this changes, which is
/// what keeps a playback tick from touching them.
struct CarPlayListContent: Equatable {
  enum Entry: Equatable {
    case tab(CarPlayTab)
    case resume
    case allBooks
    case authors
    case series
    case row(CarPlayBrowseRow)
    case chapter(CarPlayChapterRow)
    case previous(CarPlayBrowseRoute)
    case next(CarPlayBrowseRoute)
  }

  struct Section: Equatable {
    var header: String?
    var entries: [Entry]
  }

  var sections: [Section] = []
  /// Shown in place of the rows when there are none.
  var emptyTitle: String?

  var rows: [CarPlayBrowseRow] {
    sections.flatMap(\.entries).compactMap { if case .row(let row) = $0 { row } else { nil } }
  }

  static let truncatedHeader = "More in Whirr on iPhone"
  static let loading = CarPlayListContent(emptyTitle: "Loading")
  static let latestEpisodesHeader = "New Episodes"
  static let showsHeader = "Your Shows"

  /// The item slots the Podcasts tab keeps for new episodes. The shows beneath are paged to fit
  /// what is left, so the page controls survive the car's limit.
  static func latestEpisodeSlots(maximumItemCount: Int) -> Int {
    min(CarPlayBrowseModel.latestEpisodeLimit, max(0, maximumItemCount) / 3)
  }

  static func rootList(_ tabs: [CarPlayTab]) -> CarPlayListContent {
    CarPlayListContent(sections: [Section(entries: tabs.map(Entry.tab))])
  }

  /// An observed list: Continue, Recently Added or Up Next. `leading` rows (Resume, All Books)
  /// take item slots ahead of the content.
  static func observed(
    _ snapshot: CarPlayBrowseSnapshot?, leading: [Entry] = [], header: String? = nil, maximumItemCount: Int
  ) -> CarPlayListContent {
    guard let snapshot, case .rows(let rows) = snapshot.content else {
      return leading.isEmpty ? .loading : CarPlayListContent(sections: [Section(entries: leading)])
    }
    let layout = CarPlayListLayout(
      rows: rows, hasPrevious: false, hasNext: false, maximumItemCount: maximumItemCount - leading.count)
    var content = CarPlayListContent()
    if leading.isEmpty == false { content.sections.append(Section(entries: leading)) }
    if layout.rows.isEmpty == false {
      content.sections.append(
        Section(header: layout.isTruncated ? truncatedHeader : header, entries: layout.rows.map(Entry.row)))
    }
    if content.sections.isEmpty { content.emptyTitle = snapshot.route.emptyMessage }
    return content
  }

  static func paged(_ list: CarPlayPagedList, maximumItemCount: Int) -> CarPlayListContent {
    switch list.content {
    case .loading, .stale:
      return .loading
    case .unavailable:
      return CarPlayListContent(emptyTitle: "Couldn't load this list")
    case .page(let rows, let hasPrevious, let hasNext):
      let layout = CarPlayListLayout(
        rows: rows, hasPrevious: hasPrevious, hasNext: hasNext, maximumItemCount: maximumItemCount)
      guard layout.itemCount > 0 else { return CarPlayListContent(emptyTitle: list.route.emptyMessage) }
      var entries = layout.rows.map(Entry.row)
      if layout.showsPrevious { entries.insert(.previous(list.route), at: 0) }
      if layout.showsNext { entries.append(.next(list.route)) }
      return CarPlayListContent(
        sections: [Section(header: layout.isTruncated ? truncatedHeader : nil, entries: entries)])
    }
  }

  /// The Podcasts tab: the newest unplayed episodes, then the shows. The episodes lead only the
  /// first page of shows, and the tab reads as empty only when both halves are.
  static func podcasts(
    latest: CarPlayBrowseSnapshot?, shows: CarPlayPagedList, maximumItemCount: Int
  ) -> CarPlayListContent {
    var episodes: [CarPlayBrowseRow] = []
    if case .rows(let rows) = latest?.content {
      episodes = Array(rows.prefix(latestEpisodeSlots(maximumItemCount: maximumItemCount)))
    }
    if case .page(_, true, _) = shows.content { episodes = [] }
    var content = paged(shows, maximumItemCount: maximumItemCount - episodes.count)
    guard episodes.isEmpty == false else { return content }
    for index in content.sections.indices where content.sections[index].header == nil {
      content.sections[index].header = showsHeader
    }
    content.sections.insert(Section(header: latestEpisodesHeader, entries: episodes.map(Entry.row)), at: 0)
    content.emptyTitle = nil
    return content
  }

  static func chapters(_ list: CarPlayChapterList?, maximumItemCount: Int) -> CarPlayListContent {
    guard let list, list.rows.isEmpty == false else { return CarPlayListContent(emptyTitle: "No chapters") }
    guard list.rows.count > maximumItemCount, maximumItemCount > 0 else {
      return CarPlayListContent(sections: [Section(entries: list.rows.map(Entry.chapter))])
    }
    // More chapters than the car lists: keep the window around the current one, so the chapter
    // being heard and its neighbours are always reachable.
    let current = list.rows.firstIndex(where: \.isCurrent) ?? 0
    let start = min(max(0, current - maximumItemCount / 2), list.rows.count - maximumItemCount)
    let window = list.rows[start..<(start + maximumItemCount)]
    return CarPlayListContent(sections: [Section(header: truncatedHeader, entries: window.map(Entry.chapter))])
  }
}
