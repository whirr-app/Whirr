import Foundation
import Persistence

/// The ordered, view-ready projection of an author or series item window. The projection owns
/// grouping and all presentation tie-breakers so a view never has to interpret the server's
/// flattened series string or depend on request completion order.
public struct AuthorSeriesSection: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    case series(key: String, name: String)
    /// One book that belongs to no series. A card says "these belong together", which unrelated
    /// books do not: one invented "Standalone" collection also made four of them wear one book's
    /// extracted colour. Each is its own section, a full-width row with its own wash.
    case standaloneBook
    /// Every row on one destination, sharing no series at all. Only a series destination whose
    /// items carry no usable series descriptor produces this; an author destination emits
    /// `.standaloneBook` per loose book instead.
    case standalone
    /// Separate server items for one normalized standalone title, grouped only when both an
    /// audiobook and an ebook are present. The rows remain independent editions and actions.
    case standaloneEditions(key: String, title: String)
  }

  /// A prefix that cannot be produced by the normalized name of an ordinary series. Keeping the
  /// fallback distinct from a real series named "Standalone" makes section identity a safe key,
  /// not a display label.
  public static let standaloneID = "__standalone__"

  /// A loose book's section identity. The server item ID is already unique and stable across
  /// pagination and filtering, so it is the whole key; the prefix only keeps it out of the space a
  /// normalized series key could occupy.
  public static func standaloneBookID(forItemID itemID: String) -> String {
    "\(standaloneID)/book/\(itemID)"
  }

  /// A grouped standalone title must keep one identity as filters and pagination add or remove
  /// editions. The normalized key is presentation identity only; it never replaces a server item
  /// ID for progress, downloads, navigation, or actions.
  public static func standaloneEditionsID(forTitle title: String) -> String {
    "\(standaloneID)/editions/\(AuthorSeriesEntity.normalizedName(title))"
  }

  public let id: String
  public let kind: Kind
  public let rows: [SearchResultRow]

  public init(id: String, kind: Kind, rows: [SearchResultRow]) {
    self.id = id
    self.kind = kind
    self.rows = rows
  }

  public var displayName: String {
    switch kind {
    case .series(_, let name): name
    case .standaloneBook: rows.first?.title ?? ""
    case .standalone: "Standalone"
    case .standaloneEditions(_, let title): title
    }
  }

  /// Visible, deduplicated server items in this section. Not a count of distinct works, since one
  /// title can be present as both an audiobook and an ebook.
  public var itemCount: Int { rows.count }

  /// The first visible server item is the candidate source for the card's stable wash. The view
  /// owns the lifetime selection; this value is only the deterministic candidate for a new card.
  public var candidateWashSourceItemID: String? { rows.first?.entityID }

  /// Groups, deduplicates, and orders an item window without observation, I/O, or UI state.
  /// `identityOrder` is the resolved library order supplied by the model. When omitted, the first
  /// appearance of each library in `rows` supplies that order, which keeps the function directly
  /// useful in focused pure tests.
  public static func sections(
    from rows: [SearchResultRow], identityOrder: [String] = []
  ) -> [AuthorSeriesSection] {
    let orderedRows = deduplicated(rows, identityOrder: identityOrder)
    let identityRanks = ranks(for: orderedRows, identityOrder: identityOrder)

    var namedRows: [String: NamedRows] = [:]
    var standaloneRows: [SearchResultRow] = []
    for row in orderedRows {
      guard let descriptor = LibraryEntityGrouping.seriesDescriptor(from: row.seriesName) else {
        standaloneRows.append(row)
        continue
      }
      if namedRows[descriptor.key] == nil {
        namedRows[descriptor.key] = NamedRows(key: descriptor.key, name: descriptor.name, rows: [])
      }
      namedRows[descriptor.key]?.rows.append(row)
    }

    let namedSections = namedRows.values
      .map { group in
        AuthorSeriesSection(
          id: group.key,
          kind: .series(key: group.key, name: group.name),
          rows: ordered(group.rows, identityRanks: identityRanks))
      }
      .sorted(by: sectionPrecedes)

    return namedSections
      + standaloneSections(from: standaloneRows, identityRanks: identityRanks)
  }

  /// Matching titles alone are not enough to infer one intellectual work. The narrow visual rule
  /// groups only the cross-format shape the UI can explain: at least one explicit audiobook and
  /// one explicit ebook. Same-format copies retain their independent rows in the aggregate.
  private static func standaloneSections(
    from rows: [SearchResultRow], identityRanks: [String: Int]
  ) -> [AuthorSeriesSection] {
    var groups: [String: NamedRows] = [:]
    for row in rows {
      let key = AuthorSeriesEntity.normalizedName(row.title)
      if groups[key] == nil {
        groups[key] = NamedRows(key: key, name: row.title, rows: [])
      }
      groups[key]?.rows.append(row)
    }

    var looseRows: [SearchResultRow] = []
    let editionSections = groups.values.compactMap { group -> AuthorSeriesSection? in
      let categories = Set(group.rows.compactMap(\.mediaCategory))
      guard categories.contains(.audiobook), categories.contains(.ebook) else {
        looseRows.append(contentsOf: group.rows)
        return nil
      }

      return AuthorSeriesSection(
        id: standaloneEditionsID(forTitle: group.name),
        kind: .standaloneEditions(key: group.key, title: group.name),
        rows: orderedStandaloneEditions(group.rows, identityRanks: identityRanks))
    }

    // One section per loose book, in their own title alphabet.
    let bookSections = ordered(looseRows, identityRanks: identityRanks).map { row in
      AuthorSeriesSection(
        id: standaloneBookID(forItemID: row.entityID), kind: .standaloneBook, rows: [row])
    }

    // Every card first, then every single book. A card landing mid-run would break the loose
    // books' grid into single-column fragments either side of it. Sorted explicitly because these
    // are built from a dictionary and would otherwise arrive in its iteration order.
    let sortedEditionSections = editionSections.sorted { lhs, rhs in
      let titleOrder = standaloneTitle(for: lhs).localizedStandardCompare(
        standaloneTitle(for: rhs))
      if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
      return lhs.id < rhs.id
    }
    return sortedEditionSections + bookSections
  }

  private static func standaloneTitle(for section: AuthorSeriesSection) -> String {
    switch section.kind {
    case .standaloneBook, .standalone:
      return section.rows.first?.title ?? ""
    case .standaloneEditions(_, let title):
      return title
    case .series(_, let name):
      return name
    }
  }

  /// Once normalized titles match, format is the useful first distinction. This mirrors the
  /// existing series tie-breakers without letting punctuation or capitalization split the pair.
  private static func orderedStandaloneEditions(
    _ rows: [SearchResultRow], identityRanks: [String: Int]
  ) -> [SearchResultRow] {
    rows.sorted { lhs, rhs in
      let leftCategory = categoryRank(lhs.mediaCategory)
      let rightCategory = categoryRank(rhs.mediaCategory)
      if leftCategory != rightCategory { return leftCategory < rightCategory }

      let leftIdentity = identityRanks[lhs.libraryID] ?? Int.max
      let rightIdentity = identityRanks[rhs.libraryID] ?? Int.max
      if leftIdentity != rightIdentity { return leftIdentity < rightIdentity }

      return lhs.entityID < rhs.entityID
    }
  }

  /// Orders one card's rows using the same rules as named sections. A series destination has one
  /// card by definition, so its model projection uses this shared orderer rather than maintaining
  /// a second ordering implementation.
  static func orderedRows(
    _ rows: [SearchResultRow], identityOrder: [String] = []
  ) -> [SearchResultRow] {
    let deduplicatedRows = deduplicated(rows, identityOrder: identityOrder)
    return ordered(deduplicatedRows, identityRanks: ranks(for: deduplicatedRows, identityOrder: identityOrder))
  }

  private struct NamedRows {
    let key: String
    let name: String
    var rows: [SearchResultRow]
  }

  private static func deduplicated(
    _ rows: [SearchResultRow], identityOrder: [String]
  ) -> [SearchResultRow] {
    let identityRanks = ranks(for: rows, identityOrder: identityOrder)
    var retained: [String: (row: SearchResultRow, index: Int)] = [:]
    for (index, row) in rows.enumerated() {
      guard let current = retained[row.entityID] else {
        retained[row.entityID] = (row, index)
        continue
      }
      let candidateRank = identityRanks[row.libraryID] ?? Int.max
      let currentRank = identityRanks[current.row.libraryID] ?? Int.max
      if candidateRank < currentRank {
        retained[row.entityID] = (row, index)
      }
    }
    return retained.values.sorted { $0.index < $1.index }.map(\.row)
  }

  private static func ranks(
    for rows: [SearchResultRow], identityOrder: [String]
  ) -> [String: Int] {
    var result: [String: Int] = [:]
    for libraryID in identityOrder where result[libraryID] == nil {
      result[libraryID] = result.count
    }
    for row in rows where result[row.libraryID] == nil {
      result[row.libraryID] = result.count
    }
    return result
  }

  private static func ordered(
    _ rows: [SearchResultRow], identityRanks: [String: Int]
  ) -> [SearchResultRow] {
    rows.sorted { lhs, rhs in
      let leftSequence = LibraryEntityGrouping.seriesDescriptor(from: lhs.seriesName)?.sequence
      let rightSequence = LibraryEntityGrouping.seriesDescriptor(from: rhs.seriesName)?.sequence
      switch (leftSequence, rightSequence) {
      case (let left?, let right?) where left != right:
        return left < right
      case (.some, nil):
        return true
      case (nil, .some):
        return false
      default:
        break
      }

      let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
      if titleOrder != .orderedSame { return titleOrder == .orderedAscending }

      let leftCategory = categoryRank(lhs.mediaCategory)
      let rightCategory = categoryRank(rhs.mediaCategory)
      if leftCategory != rightCategory { return leftCategory < rightCategory }

      let leftIdentity = identityRanks[lhs.libraryID] ?? Int.max
      let rightIdentity = identityRanks[rhs.libraryID] ?? Int.max
      if leftIdentity != rightIdentity { return leftIdentity < rightIdentity }

      return lhs.entityID < rhs.entityID
    }
  }

  private static func categoryRank(_ category: ItemMediaCategory?) -> Int {
    guard let category, let index = ItemMediaCategory.allCases.firstIndex(of: category) else {
      return ItemMediaCategory.allCases.count
    }
    return index
  }

  /// Named series come first: they are the structured thing on the page, and the loose books that
  /// follow read naturally as "and also these".
  private static func kindRank(_ kind: Kind) -> Int {
    switch kind {
    case .series: 0
    case .standaloneEditions: 1
    case .standaloneBook: 2
    case .standalone: 3
    }
  }

  private static func sectionPrecedes(
    _ lhs: AuthorSeriesSection, _ rhs: AuthorSeriesSection
  ) -> Bool {
    let leftRank = kindRank(lhs.kind)
    let rightRank = kindRank(rhs.kind)
    if leftRank != rightRank { return leftRank < rightRank }

    guard case .series(_, let leftName) = lhs.kind, case .series(_, let rightName) = rhs.kind
    else { return false }
    let nameOrder = leftName.localizedCaseInsensitiveCompare(rightName)
    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
    return lhs.id < rhs.id
  }
}
