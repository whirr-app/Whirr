import Foundation
import Persistence

/// One Authors/Series browse row: the server's entity joined to the local library items that
/// actually belong to it.
///
/// The entity carries identity (the server author or series id the destination is fetched by),
/// which only the server's listing route supplies. The items carry what a row shows: book count,
/// media kinds, series, and the stand-in cover. They come from the `item` projection Titles
/// browses, so the Library filter narrows these modes: hiding all an author's books hides them.
public struct LibraryEntityGroup: Sendable, Equatable, Identifiable {
  public var id: String { entity.id }
  public let entity: AuthorSeriesEntity
  /// The entity's items that survive the active filter, ordered the way the entity reads: series
  /// sequence for a series, title for an author.
  public let items: [ItemSummary]
  /// Whether a filter was active when this row was derived. Carried on the row so every consumer
  /// answers it the same way (a subtitle counting the whole shelf beside badges counting only
  /// the match would disagree).
  public let isFiltered: Bool

  public init(entity: AuthorSeriesEntity, items: [ItemSummary], isFiltered: Bool) {
    self.entity = entity
    self.items = items
    self.isFiltered = isFiltered
  }

  public var kind: SearchResultKind { entity.kind }
  public var name: String { entity.name }
  public var entityID: String { entity.entityID }
  public var libraryID: String { entity.libraryID }

  /// The media kinds present among the matched items, in `ItemMediaCategory` declaration order so
  /// a row's badges never reorder between renders.
  public var categories: [ItemMediaCategory] {
    let present = Set(items.map(\.category))
    return ItemMediaCategory.allCases.filter(present.contains)
  }

  /// The distinct series among the matched items, which an author row surfaces. Ordered by first
  /// appearance, which after `items` ordering is series order.
  public var seriesNames: [String] {
    var seen = Set<String>()
    var names: [String] = []
    for item in items {
      guard let descriptor = LibraryEntityGrouping.seriesDescriptor(from: item.seriesName) else {
        continue
      }
      guard seen.insert(descriptor.key).inserted else { continue }
      names.append(descriptor.name)
    }
    return names
  }

  /// The item whose artwork stands in for this entity. A series has no cover, so its earliest
  /// sequenced entry (the first of `items`) lends one. Nil when there are no matched items.
  public var coverItemID: String? { items.first?.serverItemId }

  /// The most common author among the matched items, which for a series is the series' author.
  /// Nil rather than "Unknown author", so a series row's subtitle drops the segment.
  public var primaryAuthorName: String? {
    LibraryEntityGrouping.primaryAuthorName(among: items.map(\.author))
  }

  /// The book count the row states.
  ///
  /// Matched items win when present, as that count agrees with the opened row. The server's
  /// `numBooks` is the fallback for an entity not stored locally yet, and only while unfiltered:
  /// it counts the whole shelf and would contradict the filter.
  public var bookCount: Int? {
    if items.isEmpty == false { return items.count }
    if isFiltered { return 0 }
    return entity.bookCount
  }
}

/// Pure derivation of `LibraryEntityGroup`s. Separate from the model so the join, the filter rule,
/// and the series ordering are testable without a database, an observation, or a server.
public enum LibraryEntityGrouping {
  /// A series as the minified library route states it: `"Name #3"`, one flattened string. The
  /// sequence is a `Double` because Audiobookshelf sequences are routinely fractional (`#2.5` for
  /// a novella between two novels).
  public struct SeriesDescriptor: Sendable, Equatable {
    public let name: String
    public let sequence: Double?
    /// The normalized form two spellings of the same series share.
    public var key: String { LibraryEntityGrouping.normalized(name) }
  }

  /// The most common author among a set of author strings, earliest-seen winning a tie. Shared so
  /// a Library series row and the series' destination summary name the same author. Nil rather
  /// than "Unknown author", so a subtitle drops the segment.
  public static func primaryAuthorName(among authors: [String?]) -> String? {
    var counts: [String: Int] = [:]
    var firstSeen: [String: Int] = [:]
    for (index, author) in authors.enumerated() {
      guard let name = author?.trimmingCharacters(in: .whitespacesAndNewlines),
        name.isEmpty == false
      else { continue }
      counts[name, default: 0] += 1
      if firstSeen[name] == nil { firstSeen[name] = index }
    }
    return counts.max {
      if $0.value != $1.value { return $0.value < $1.value }
      return (firstSeen[$0.key] ?? 0) > (firstSeen[$1.key] ?? 0)
    }?.key
  }

  public static func seriesDescriptor(from seriesName: String?) -> SeriesDescriptor? {
    guard let raw = seriesName?.trimmingCharacters(in: .whitespacesAndNewlines),
      raw.isEmpty == false
    else { return nil }
    guard let hashIndex = raw.lastIndex(of: "#") else {
      return SeriesDescriptor(name: raw, sequence: nil)
    }
    let sequenceText = raw[raw.index(after: hashIndex)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let name = raw[..<hashIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    // A `#` that is part of the title rather than a sequence marker ("Book #1 of Nothing") leaves
    // the whole string as the name.
    guard let sequence = Double(sequenceText), name.isEmpty == false else {
      return SeriesDescriptor(name: raw, sequence: nil)
    }
    return SeriesDescriptor(name: name, sequence: sequence)
  }

  /// The names one item can be filed under for the author mode.
  ///
  /// The minified route joins multiple authors into one `", "`-separated string, so the components
  /// match the server's per-author listing. The whole string is offered too, as a single author
  /// with a comma ("Le Guin, Ursula K.") would split into names matching nothing. The server's
  /// author list decides which reading is real.
  public static func authorNames(from author: String?) -> [String] {
    guard let raw = author?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false
    else { return [] }
    let components = raw.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.isEmpty == false }
    guard components.count > 1 else { return [raw] }
    return [raw] + components
  }

  /// Joins the server's entity listing to the filtered local library.
  ///
  /// `entities` decides which rows exist and their names: it carries the destination ids and is
  /// complete where the local store may not be. `items` is the already-filtered browse list, so
  /// every `BrowseFilters` dimension reaches these modes without being interpreted here.
  ///
  /// `filters` only decides the empty-entity rule: while active, an entity with no matching item is
  /// hidden (a dead end); unfiltered it is kept so a library still syncing lists its authors.
  public static func groups(
    kind: SearchResultKind,
    entities: [AuthorSeriesEntity],
    items: [ItemSummary],
    filters: BrowseFilters
  ) -> [LibraryEntityGroup] {
    let membership = membership(kind: kind, items: items)
    let isFiltered = filters.isActive
    return entities.compactMap { entity in
      let members = membership[normalized(entity.name)] ?? []
      guard members.isEmpty == false || isFiltered == false else { return nil }
      return LibraryEntityGroup(
        entity: entity, items: sorted(members, kind: kind), isFiltered: isFiltered)
    }
  }

  /// Normalized entity name to the items filed under it. Built once per derivation, since
  /// scanning per entity would be an n×m sweep on every filter change.
  private static func membership(
    kind: SearchResultKind, items: [ItemSummary]
  ) -> [String: [ItemSummary]] {
    var membership: [String: [ItemSummary]] = [:]
    for item in items {
      switch kind {
      case .author:
        for name in authorNames(from: item.author) {
          membership[normalized(name), default: []].append(item)
        }
      case .series:
        guard let descriptor = seriesDescriptor(from: item.seriesName) else { continue }
        membership[descriptor.key, default: []].append(item)
      case .book, .podcast, .episode:
        continue
      }
    }
    return membership
  }

  /// Series order for a series, title order for an author. Unsequenced entries sort after the
  /// sequenced ones, so the series' first book is never an unnumbered bonus story.
  private static func sorted(
    _ items: [ItemSummary], kind: SearchResultKind
  ) -> [ItemSummary] {
    guard kind == .series else {
      return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    return items.sorted { lhs, rhs in
      let left = seriesDescriptor(from: lhs.seriesName)?.sequence
      let right = seriesDescriptor(from: rhs.seriesName)?.sequence
      switch (left, right) {
      case (let left?, let right?) where left != right:
        return left < right
      case (nil, .some):
        return false
      case (.some, nil):
        return true
      default:
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      }
    }
  }

  /// The form two spellings of one name share, so "Miéville" and "Mieville" are one author.
  /// Must match the folding `AuthorSeriesEntity` merges libraries' copies under, or a row's count
  /// and destination could come from different spellings.
  static func normalized(_ name: String) -> String {
    AuthorSeriesEntity.normalizedName(name)
  }
}
