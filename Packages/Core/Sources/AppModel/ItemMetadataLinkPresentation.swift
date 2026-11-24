import Foundation

/// The collection an item-detail metadata control opens. The associated name is the canonical
/// lookup value; a series display label may additionally carry its sequence.
public enum ItemMetadataDestination: Sendable, Equatable, Hashable {
  case author(name: String)
  case series(name: String)
  case narrator(name: String)
}

/// Which kind of person a flattened credit string contains.
public enum ItemMetadataPersonRole: Sendable, Equatable {
  case author
  case narrator
}

/// One tappable name in the item detail hero's metadata block: what the screen shows and the
/// semantic collection it opens. The two names differ for a series: "Dungeon Crawler Carl #8"
/// is the label while "Dungeon Crawler Carl" is the destination lookup value.
public struct ItemMetadataLink: Sendable, Equatable, Hashable {
  public let displayName: String
  public let destination: ItemMetadataDestination

  public init(displayName: String, destination: ItemMetadataDestination) {
    self.displayName = displayName
    self.destination = destination
  }
}

/// The item detail hero's author/series/narrator links. Each name is its own control in a wrapping
/// centred row, so a long credit breaks like a paragraph and every name stays easy to hit.
///
/// A credit naming several people splits per person: the server has no row for the joined
/// "Travis Baldree, Jeff Hays", so linking the whole span would deep-link to an empty result.
public enum ItemMetadataLinkPresentation {

  public static let separator = ","

  /// A trailing Audiobookshelf sequence marker ("#8", "#3.5"), which belongs on the label but
  /// never in the query. Computed, not stored: `Regex` isn't `Sendable`.
  private static var sequenceSuffix: Regex<(Substring, Substring?)> { /\s*#\d+(\.\d+)?\s*$/ }

  // MARK: - Links

  /// One link per person in an author/narrator credit. `role` is required: a credit string
  /// does not say which kind of person it names, and the two open different collections.
  public static func personLinks(
    _ credit: String?, role: ItemMetadataPersonRole
  ) -> [ItemMetadataLink] {
    guard let credit else { return [] }
    var seen: Set<String> = []
    return
      credit
      .split(separator: ",")
      .compactMap { trimmed(String($0)) }
      .filter { seen.insert($0).inserted }
      .map { name in
        ItemMetadataLink(
          displayName: name,
          destination: role == .author ? .author(name: name) : .narrator(name: name))
      }
  }

  /// The series link, labelled with the sequence and queried without it. A series name is one
  /// destination however many commas it contains; only people split.
  public static func seriesLink(_ seriesName: String?) -> ItemMetadataLink? {
    guard let name = trimmed(seriesName ?? "") else { return nil }
    let withoutSequence = trimmed(name.replacing(sequenceSuffix, with: ""))
    return ItemMetadataLink(
      displayName: name, destination: .series(name: withoutSequence ?? name))
  }

  // MARK: - Overflow

  /// How many names a credit line prints before it starts counting the rest.
  ///
  /// Three, for full-cast audiobooks: eight narrators take eight lines and push the blurb and play
  /// button off the first screen. Three wrap to at most two lines at every Dynamic Type size the
  /// horizontal hero uses.
  public static let creditNameLimit = 3

  /// The names actually drawn, given whether the reader has opened the line.
  ///
  /// A line one name over the limit is not truncated: "+1 more" takes about the width of the name
  /// it replaces, so hiding that name saves no space and costs the reader a tap.
  public static func visibleLinks(
    _ links: [ItemMetadataLink], isExpanded: Bool, limit: Int = creditNameLimit
  ) -> [ItemMetadataLink] {
    guard isExpanded == false, links.count > limit + 1 else { return links }
    return Array(links.prefix(limit))
  }

  /// How many names `visibleLinks` left out. Zero when the whole credit is on screen, which also
  /// tells the view whether to draw an overflow control at all.
  public static func hiddenCount(
    _ links: [ItemMetadataLink], isExpanded: Bool, limit: Int = creditNameLimit
  ) -> Int {
    links.count - visibleLinks(links, isExpanded: isExpanded, limit: limit).count
  }

  /// The overflow control's label. It states the count rather than "More", since the reader wants
  /// to know how many people are hidden before opening it.
  public static func overflowLabel(hidden: Int) -> String { "+\(hidden) more" }

  /// Closing the same line again. "Less" rather than a count, as on the blurb's control: once the
  /// line is open the number is on screen.
  public static let collapseLabel = "Less"

  // MARK: - Labels

  /// What a name's control reads: the name, plus the separator that carries the eye to the next
  /// one. The separator sits inside the label so it travels with its name when the row wraps.
  ///
  /// `hasOverflow` is the truncated case: the last visible name is not the last name, so it keeps
  /// its comma and leads the eye to the count that follows.
  public static func label(
    for link: ItemMetadataLink, at index: Int, of links: [ItemMetadataLink],
    hasOverflow: Bool = false
  ) -> String {
    index < links.count - 1 || hasOverflow ? link.displayName + separator : link.displayName
  }

  private static func trimmed(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// The semantic metadata destination's direct route. Kept beside the link value so every surface
/// that renders one pushes the same destination instead of rebuilding a search query.
public enum ItemMetadataNavigationPresentation {
  public static func route(for destination: ItemMetadataDestination) -> NavigationModel.Route {
    switch destination {
    case .author(let name): .authorName(name: name)
    case .series(let name): .seriesName(name: name)
    case .narrator(let name): .narrator(name: name)
    }
  }
}
