import ABSApi
import AppModel
import Persistence
import SwiftUI

/// A section of the regular-width Library collection view. Letter sections carry their mode, for
/// the reason `LibraryBrowseLayoutPresentation.sectionTargetID` gives: a letter in Titles must not
/// be the same identity as that letter in Authors, or a mode switch is not a replacement.
nonisolated enum LibraryBrowseCollectionSection: Hashable, Sendable {
  case controls
  case banner
  case state
  case letter(LibraryBrowsePresentation.Mode, String)
  case loadMore
}

/// An item of the regular-width Library collection view. Entities are keyed by
/// `LibraryEntityGroup.id` (`kind#entityID`), never by `group.entityID`, which is only the first
/// library's identity of a merged entity.
nonisolated enum LibraryBrowseCollectionItem: Hashable, Sendable {
  case controls
  case banner
  case state
  case title(String)
  case author(String)
  case series(String)
  case loadMore
}

/// Everything the collection view shows for one mode, as a value. The builders below are the only
/// place a snapshot is made, so the identity rules they enforce hold for every apply.
struct LibraryBrowseCollectionSnapshot: Equatable {
  struct Section: Equatable {
    let id: LibraryBrowseCollectionSection
    let items: [LibraryBrowseCollectionItem]
  }

  let mode: LibraryBrowsePresentation.Mode
  let sections: [Section]
  let banner: String?
  let titles: [String: ItemSummary]
  let groups: [String: LibraryEntityGroup]
  /// The prefetcher's ordering, which is not the snapshot's identity: Titles order by
  /// `serverItemId`, Series by `coverItemID`, and Authors do not prefetch.
  let prefetchOrder: [String]
  /// The cover revision for each ID in `prefetchOrder`.
  let prefetchRevisions: [String: ArtworkRevision]
  /// Each prefetching item's first position in `prefetchOrder`, before row alignment.
  let prefetchIndices: [LibraryBrowseCollectionItem: Int]

  var itemIdentifiers: [LibraryBrowseCollectionItem] { sections.flatMap(\.items) }

  /// The jump target a letter section's header answers to. Equal by construction to the ID the
  /// jump menu resolves, because both come from `sectionTargetID`.
  static func targetID(for section: LibraryBrowseCollectionSection) -> String? {
    guard case .letter(let mode, let sectionID) = section else { return nil }
    return LibraryBrowseLayoutPresentation.sectionTargetID(for: sectionID, in: mode, hasItems: true)
  }

  func section(forTargetID targetID: String) -> LibraryBrowseCollectionSection? {
    sections.first { Self.targetID(for: $0.id) == targetID }?.id
  }

  static func titles(
    rows: LibraryBrowsePresentation.RowsPresentation,
    banner: String?,
    values: [ItemSummary],
    sections: [LibraryBrowsePresentation.Section<ItemSummary>]
  ) -> Self {
    var builder = Builder(mode: .titles)
    guard case .rows = rows else {
      builder.appendState(for: rows)
      return builder.snapshot(banner: nil)
    }
    if let banner, banner.isEmpty == false {
      builder.append(.banner, items: [.banner])
    }
    for section in sections {
      builder.appendLetter(section.id, items: section.items.map { .title($0.serverItemId) })
      for item in section.items where builder.titles[item.serverItemId] == nil {
        builder.titles[item.serverItemId] = item
      }
    }
    builder.prefetchOrder = values.map(\.serverItemId)
    builder.prefetchRevisions = values.artworkRevisionsByID
    builder.indexPrefetch { item in
      if case .title(let id) = item { id } else { nil }
    }
    return builder.snapshot(banner: banner?.isEmpty == false ? banner : nil)
  }

  /// The item for one entity in an entity mode. Exhaustive so a new mode cannot be drawn as series
  /// unnoticed.
  static func entityItem(
    _ id: String, in mode: LibraryBrowsePresentation.Mode
  ) -> LibraryBrowseCollectionItem {
    switch mode {
    case .authors: .author(id)
    case .series: .series(id)
    case .titles: preconditionFailure("Titles build through titles(rows:banner:values:sections:)")
    case .collections: preconditionFailure("Collections never reaches the collection-view host")
    }
  }

  static func entities(
    mode: LibraryBrowsePresentation.Mode,
    rows: LibraryBrowsePresentation.RowsPresentation,
    hasMore: Bool,
    values: [LibraryEntityGroup],
    sections: [LibraryBrowsePresentation.Section<LibraryEntityGroup>]
  ) -> Self {
    precondition(mode.entityKind != nil, "Only Authors and Series build through entities(…)")
    var builder = Builder(mode: mode)
    guard case .rows = rows else {
      builder.appendState(for: rows)
      return builder.snapshot(banner: nil)
    }
    for section in sections {
      builder.appendLetter(
        section.id,
        items: section.items.map { entityItem($0.id, in: mode) })
      for group in section.items where builder.groups[group.id] == nil {
        builder.groups[group.id] = group
      }
    }
    // `entityRowsPresentation` answers `.rows` whenever another page exists, even with nothing
    // matching yet, so controls followed directly by the load-more row is a legal snapshot.
    if hasMore {
      builder.append(.loadMore, items: [.loadMore])
    }
    if mode == .series {
      builder.prefetchOrder = values.compactMap(\.coverItemID)
      builder.prefetchRevisions = values.coverRevisionsByID
      let groups = builder.groups
      builder.indexPrefetch { item in
        if case .series(let id) = item { groups[id]?.coverItemID } else { nil }
      }
    }
    return builder.snapshot(banner: nil)
  }

  private struct Builder {
    let mode: LibraryBrowsePresentation.Mode
    var sections: [Section] = [Section(id: .controls, items: [.controls])]
    var seen: Set<LibraryBrowseCollectionItem> = [.controls]
    var titles: [String: ItemSummary] = [:]
    var groups: [String: LibraryEntityGroup] = [:]
    var prefetchOrder: [String] = []
    var prefetchRevisions: [String: ArtworkRevision] = [:]
    var prefetchIndices: [LibraryBrowseCollectionItem: Int] = [:]

    init(mode: LibraryBrowsePresentation.Mode) {
      self.mode = mode
    }

    mutating func append(
      _ section: LibraryBrowseCollectionSection, items: [LibraryBrowseCollectionItem]
    ) {
      seen.formUnion(items)
      sections.append(Section(id: section, items: items))
    }

    mutating func appendState(for rows: LibraryBrowsePresentation.RowsPresentation) {
      switch rows {
      case .filteredEmpty, .queryEmpty:
        append(.state, items: [.state])
      case .rows, .none:
        break
      }
    }

    /// Appends one letter, dropping any identifier already in the snapshot, and omitting the letter
    /// if nothing is left. `serverItemId` is unique per library rather than across them, and entity
    /// pages append without deduplicating, but a diffable snapshot throws on a repeat. First
    /// occurrence wins, and the callers record values the same way.
    mutating func appendLetter(_ sectionID: String, items candidates: [LibraryBrowseCollectionItem]) {
      let items = candidates.filter { seen.insert($0).inserted }
      guard items.isEmpty == false else { return }
      sections.append(Section(id: .letter(mode, sectionID), items: items))
    }

    mutating func indexPrefetch(_ key: (LibraryBrowseCollectionItem) -> String?) {
      var firstIndex: [String: Int] = [:]
      for (offset, id) in prefetchOrder.enumerated() where firstIndex[id] == nil {
        firstIndex[id] = offset
      }
      for section in sections {
        for item in section.items {
          if let id = key(item), let index = firstIndex[id] {
            prefetchIndices[item] = index
          }
        }
      }
    }

    func snapshot(banner: String?) -> LibraryBrowseCollectionSnapshot {
      LibraryBrowseCollectionSnapshot(
        mode: mode,
        sections: sections,
        banner: banner,
        titles: titles,
        groups: groups,
        prefetchOrder: prefetchOrder,
        prefetchRevisions: prefetchRevisions,
        prefetchIndices: prefetchIndices)
    }
  }
}
