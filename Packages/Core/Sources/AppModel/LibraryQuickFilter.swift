import Persistence

/// The Library root's local, order-preserving query vocabulary.
public enum LibraryQuickFilter {
  /// The canonical fragments a query matches by; an empty result is not an effective query.
  public static func fragments(_ query: String) -> [String] {
    SearchQueryNormalizer.canonicalize(query)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  /// The view's empty-state and index-rail policy must use the same definition of effective.
  public static func isEffective(_ query: String) -> Bool {
    fragments(query).isEmpty == false
  }

  /// Every fragment may match a different canonical field; fields that are absent or empty do
  /// not participate.
  public static func matches(fragments: [String], fields: [String?]) -> Bool {
    guard fragments.isEmpty == false else { return true }

    let canonicalFields: [String] = fields.compactMap { field -> String? in
      guard let field, field.isEmpty == false else { return nil }
      return SearchQueryNormalizer.canonicalize(field)
    }
    return fragments.allSatisfy { fragment in
      canonicalFields.contains { $0.contains(fragment) }
    }
  }

  /// Titles match both pieces of text shown in a row. Returning the input directly for an
  /// ineffective query preserves its sequence and contents exactly.
  public static func filter(items: [ItemSummary], query: String) -> [ItemSummary] {
    let queryFragments = fragments(query)
    guard queryFragments.isEmpty == false else { return items }
    return items.filter { item in
      matches(fragments: queryFragments, fields: [item.title, item.author])
    }
  }

  /// Every present field, canonicalized and joined by a newline. A fragment holds no whitespace,
  /// so it can never match across the joint, and `matches(fragments:searchKey:)` on this key
  /// answers exactly as `matches(fragments:fields:)` on the fields does.
  public static func searchKey(fields: [String?]) -> String {
    fields.compactMap { field -> String? in
      guard let field, field.isEmpty == false else { return nil }
      return SearchQueryNormalizer.canonicalize(field)
    }
    .joined(separator: "\n")
  }

  public static func matches(fragments: [String], searchKey: String) -> Bool {
    fragments.allSatisfy { searchKey.contains($0) }
  }

  /// Episode rows expose a short synopsis, but the cached full description remains searchable so
  /// a term can find an episode even when the matching sentence is not the one currently shown.
  static func searchFields(of episode: PodcastEpisodeSummary) -> [String?] {
    [episode.title, episode.subtitle, episode.synopsisLine, episode.episodeDescription]
  }

  /// Titles match both pieces of text shown in a row.
  static func searchFields(of item: ItemSummary) -> [String?] {
    [item.title, item.author]
  }

  public static func searchKey(for episode: PodcastEpisodeSummary) -> String {
    searchKey(fields: searchFields(of: episode))
  }

  public static func filter(
    episodes: [PodcastEpisodeSummary], query: String
  ) -> [PodcastEpisodeSummary] {
    let queryFragments = fragments(query)
    guard queryFragments.isEmpty == false else { return episodes }
    return episodes.filter { episode in
      matches(fragments: queryFragments, searchKey: searchKey(for: episode))
    }
  }

  /// Canonicalizing a long show's descriptions, or a large library's titles, costs hundreds of
  /// milliseconds, far too much to repeat on every keystroke. Keys are kept per id and rebuilt
  /// only when that row's searchable text changes; ids absent from the latest list are dropped.
  public struct SearchKeyCache {
    fileprivate struct Entry: Sendable {
      let fields: [String?]
      let key: String
    }

    private var entries: [String: Entry] = [:]
    private(set) var computedKeyCount = 0
    var entryCount: Int { entries.count }

    public init() {}

    /// One key per value, in the same order.
    mutating func keys<Value>(
      for values: [Value], id: (Value) -> String, fields searchFields: (Value) -> [String?]
    ) -> [String] {
      var next: [String: Entry] = .init(minimumCapacity: values.count)
      let keys = values.map { value -> String in
        let id = id(value)
        let fields = searchFields(value)
        if let entry = next[id] ?? entries[id], entry.fields == fields {
          next[id] = entry
          return entry.key
        }
        let entry = Entry(fields: fields, key: LibraryQuickFilter.searchKey(fields: fields))
        computedKeyCount += 1
        next[id] = entry
        return entry.key
      }
      entries = next
      return keys
    }

    public mutating func keys(for episodes: [PodcastEpisodeSummary]) -> [String] {
      keys(for: episodes, id: \.id, fields: LibraryQuickFilter.searchFields(of:))
    }

    public mutating func keys(for items: [ItemSummary]) -> [String] {
      keys(for: items, id: \.id, fields: LibraryQuickFilter.searchFields(of:))
    }

    /// The episodes whose current text has no key yet, as a sendable snapshot for `Warmup`.
    public func pendingSearchFields(
      for episodes: [PodcastEpisodeSummary]
    ) -> [(id: String, fields: [String?])] {
      episodes.compactMap { episode in
        let fields = LibraryQuickFilter.searchFields(of: episode)
        return entries[episode.id]?.fields == fields ? nil : (episode.id, fields)
      }
    }

    /// Keys built away from the main actor, so the first effective query need not build them.
    public struct Warmup: Sendable {
      fileprivate let entries: [String: Entry]

      public init(_ pending: [(id: String, fields: [String?])]) {
        var entries: [String: Entry] = .init(minimumCapacity: pending.count)
        for (id, fields) in pending {
          entries[id] = Entry(fields: fields, key: LibraryQuickFilter.searchKey(fields: fields))
        }
        self.entries = entries
      }
    }

    /// An entry already held is at least as fresh as the warmup's, so it is kept. A warmed entry
    /// whose text has since changed is harmless: `keys(for:)` checks the text before reusing it.
    public mutating func adopt(_ warmup: Warmup) {
      entries.merge(warmup.entries) { held, _ in held }
    }
  }

  /// Author rows match their entity name; series rows also expose their primary author.
  public static func filter(groups: [LibraryEntityGroup], query: String) -> [LibraryEntityGroup] {
    let queryFragments = fragments(query)
    guard queryFragments.isEmpty == false else { return groups }

    return groups.filter { group in
      let fields: [String?]
      switch group.kind {
      case .series:
        fields = [group.name, group.primaryAuthorName]
      case .author, .book, .podcast, .episode:
        // The browse modes only ever produce authors and series, but matching any other kind on
        // its name keeps such a row visible rather than having it vanish on the first keystroke.
        fields = [group.name]
      }
      return matches(fragments: queryFragments, fields: fields)
    }
  }
}
